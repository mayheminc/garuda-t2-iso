#!/bin/bash
#
# build-t2-profile.sh
#
# MayhemINC 2026 - provided with no warranty or liability
#
# Top-level workflow that turns an existing Garuda desktop profile into a
# fresh Apple T2 profile, applies the T2 edits, and builds the ISO.
#
#   1. ensure the iso-profiles/garuda structure exists (sudo buildiso -i)
#   2. pick a profile from /var/cache/garuda-tools/iso-profiles/garuda/
#   3. sudo cp -Rvi <profile> <profile>-t2
#   4. run setup-t2-profile.sh inside <profile>-t2
#   5. remove any stale build chroot for this profile, then confirm and run
#      sudo buildiso -p <profile>-t2 -k linux-t2
#   6. print the resulting iso directory
#
# This orchestrator itself does not need root; every privileged step is
# wrapped in sudo, so the user is prompted for their password at runtime.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable via environment (used for testing); defaults are the real paths.
PROFILE_REPO="${PROFILE_REPO:-/var/cache/garuda-tools/iso-profiles/garuda}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/var/cache/garuda-tools/garuda-builds/iso/garuda}"
CHROOT_BASE="${CHROOT_BASE:-/var/cache/garuda-tools/garuda-chroots/buildiso}"
KERNEL="linux-t2"

# Preflight requirements:
#   - 'script' is a command (provided by util-linux on Garuda/Arch)
#   - the garuda-tools-* packages are needed by buildiso itself
REQUIRED_BINARIES=(script)
REQUIRED_PACKAGES=(garuda-tools-base-git garuda-tools-iso-git garuda-tools-pkg-git)

# locate setup-t2-profile.sh: prefer it alongside this orchestrator, then
# search every profile dir under the repo.
find_setup_script() {
    local candidates=(
        "$SCRIPT_DIR/setup-t2-profile.sh"
        "$PROFILE_REPO"/setup-t2-profile.sh
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    # fall back to the first one found inside any profile dir
    local found
    found="$(find "$PROFILE_REPO" -maxdepth 2 -type f -name setup-t2-profile.sh 2>/dev/null | head -n1)"
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi
    return 1
}

msg()   { printf '%s\n' "$*"; }

# post_install_note
# Prints the reminder about post-install config notes and helpers.
# Shown whether or not the build actually ran.
post_install_note() {
    msg ""
    msg "After installing the ISO, review the post-install notes:"
    msg "    ${SCRIPT_DIR}/POST-INSTALL.md"
    msg "Then run the audio post-install helper (from a user account; uses sudo):"
    msg "    /usr/local/bin/t2-audio.sh"
}

# chroot_dir <profile-t2>
chroot_dir() { printf '%s/%s\n' "$CHROOT_BASE" "$1"; }

# delete_chroot <profile-t2>
# Removes the stale build chroot for this profile before a new build. buildiso
# refuses to start a fresh build until the chroot is gone (e.g. after a failed
# pacman fetch), so this is cleared here. sudo-wrapped; returns non-zero
# (without exiting) if there was nothing to remove.
delete_chroot() {
    local profile="$1"
    local cr
    cr="$(chroot_dir "$profile")"
    if [ -d "$cr" ]; then
        msg ">> sudo rm -rf $cr"
        sudo rm -rf "$cr"
        return 0
    fi
    msg ">> (no chroot to remove: $cr)"
    return 1
}

# ensure_dependencies
# Reports any missing tool/package and, unless the user declines,
# installs the missing packages via pacman.
ensure_dependencies() {
    local missing=()
    local b
    for b in "${REQUIRED_BINARIES[@]}"; do
        command -v "$b" >/dev/null 2>&1 || missing+=("$b")
    done
    local p
    for p in "${REQUIRED_PACKAGES[@]}"; do
        pacman -Q "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    msg "The following required dependencies are missing:"
    local m
    for m in "${missing[@]}"; do
        msg "  - $m"
    done

    local install_prompt
    read -r -p "Install them via pacman? [y/N]: " install_prompt
    case "$install_prompt" in
        [yY]|[yY][eE][sS]) : ;;
        *)
            msg "ERROR: required dependencies missing; aborting." >&2
            exit 1
            ;;
    esac

    msg ">> sudo pacman -S --needed ${missing[*]}"
    sudo pacman -S --needed "${missing[@]}"
}

############################################
# 0. Ensure dependencies are available
############################################
ensure_dependencies

############################################
# 1. Ensure the profile structure exists
############################################
if [ ! -d "$PROFILE_REPO" ]; then
    msg ">> ${PROFILE_REPO} does not exist -> initialising profile structure"
    sudo buildiso -i
fi

if [ ! -d "$PROFILE_REPO" ]; then
    msg "ERROR: ${PROFILE_REPO} still missing after init; aborting." >&2
    exit 1
fi

############################################
# 2. Let the user pick a profile
############################################
cd "$PROFILE_REPO"

# gather profiles (subdirs with a profile.conf), skipping any existing -t2 dir
profiles=()
for d in "$PROFILE_REPO"/*/; do
    [ -f "$d/profile.conf" ] || continue
    base="$(basename "$d")"
    if [[ "$base" == *-t2 ]]; then
        continue
    fi
    profiles+=("$base")
done

if [ "${#profiles[@]}" -eq 0 ]; then
    msg "ERROR: no selectable profiles (profile.conf) found in ${PROFILE_REPO}." >&2
    exit 1
fi

msg "Available profiles:"
for i in "${!profiles[@]}"; do
    printf '  [%d] %s\n' "$((i+1))" "${profiles[$i]}"
done

while :; do
    read -r -p "Select a profile [1-${#profiles[@]}] (q to quit): " choice
    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        msg "Aborted."
        exit 1
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || { printf '  -> please enter a number\n'; continue; }
    if [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
        sel="${profiles[$((choice-1))]}"
        break
    fi
    printf '  -> out of range\n'
done

############################################
# 3. Create <profile>-t2 from <profile>
############################################
SRC_DIR="$PROFILE_REPO/$sel"
T2_DIR="$PROFILE_REPO/$sel-t2"

# If <profile>-t2 already exists, cp -Rvi would copy into a nested
# <profile>-t2/<profile> subdir instead of replacing it. Prompt to remove the
# stale directory first, or abort.
if [ -e "$T2_DIR" ]; then
    msg ">> $sel-t2 already exists (from a previous run)."
    read -r -p "Delete it and continue, or abort? [D/d to delete, anything else to exit]: " overwrite
    case "$overwrite" in
        [Dd]|[Dd][oO][nN][eE])
            msg ">> removing existing $sel-t2"
            sudo rm -rf "$T2_DIR"
            ;;
        *)
            msg "Aborted."
            exit 1
            ;;
    esac
fi

msg ">> copying $sel -> $sel-t2"
sudo cp -Rvi "$SRC_DIR" "$T2_DIR"

############################################
# 4. Run the T2 setup inside the new dir
############################################
setup_script="$(find_setup_script || true)"
if [ -z "$setup_script" ]; then
    msg "ERROR: setup-t2-profile.sh not found; cannot apply T2 edits." >&2
    exit 1
fi
msg ">> copying $(basename "$setup_script") into $sel-t2 and running it"
sudo cp -a "$setup_script" "$T2_DIR/"
# The post-install notes file must exist alongside the setup script so setup.sh
# can deliver it into both overlays; copy it from here (the build wrapper dir).
if [ -f "$SCRIPT_DIR/POST-INSTALL.md" ]; then
    sudo cp -a "$SCRIPT_DIR/POST-INSTALL.md" "$T2_DIR/"
else
    msg "!! WARNING: POST-INSTALL.md not next to this script; setup.sh will skip overlay delivery." >&2
fi
cd "$T2_DIR"
./$(basename "$setup_script")

############################################
# 5. Confirm then build
############################################
msg ""
msg "T2 edits applied to: $sel-t2"
read -r -p "Proceed with build using '$sel-t2' as the -p target? [y/N]: " proceed
case "$proceed" in
    [yY]|[yY][eE][sS]) : ;;
    *)
        msg "Aborted."
        echo ""
        msg ">> Build/clean tool:"
        msg "    t2-build-tools.sh"
        echo ""
        msg ">> To build manually:"
        msg "    sudo buildiso -p $sel-t2 -k $KERNEL"
        post_install_note
        exit 1
        ;;
esac

build_log="${OUTPUT_ROOT:?}/${sel}-t2/build.log"
mkdir -p "$(dirname "$build_log")"

# The build chroot must not exist for buildiso to start cleanly; remove any
# stale artifacts first (see delete_chroot above).
delete_chroot "$sel-t2"

msg ">> sudo buildiso -p $sel-t2 -k $KERNEL"
msg ">> output streamed live and logged to ${build_log}"

# Run buildiso inside a pseudo-tty (script) so its progress output is not
# buffered and always reaches the terminal even when not attached to a real
# TTY, and record the full combined output to a log for later inspection.
set +e
script -qefc "sudo buildiso -p \"$sel-t2\" -k \"$KERNEL\"" "$build_log"
build_rc=$?
set -e
if [ "$build_rc" -ne 0 ]; then
    msg "ERROR: buildiso exited with code ${build_rc}." >&2
    msg "See full log: ${build_log}" >&2
    exit "$build_rc"
fi

############################################
# 6. Report output location
############################################
echo ""
msg "built iso files are in ${OUTPUT_ROOT}/${sel}-t2"
post_install_note
