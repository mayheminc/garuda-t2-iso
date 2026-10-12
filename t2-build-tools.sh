#!/bin/bash
#
# t2-build-tools.sh
#
# MayhemINC 2026 - provided with no warranty or liability
#
# Wrapper around `buildiso` for the Apple T2 profiles. It scans the
# iso-profiles/garuda directory for a valid `<profile>-t2` build, lets you pick
# one, then offers three options:
#
#   build iso  - remove the stale build chroot for that profile, then run
#                `sudo buildiso -p <profile>-t2 -k linux-t2` and report where
#                the resulting ISO files landed (same report as
#                build-t2-profile.sh after a build).
#   clean      - remove that profile's build chroot and its dated output dirs
#                from /var/cache/garuda-tools/garuda-builds/iso/garuda/, one by
#                one. Housekeeping: when pacman can't fetch a package (churn or
#                timeout) the build fails and buildiso refuses to start a new
#                build until the chroot is manually removed, so this makes a new
#                build possible again.
#   full wipe  - clean, and additionally remove the <profile>-t2 profile
#                directory itself (from /var/cache/garuda-tools/iso-profiles/
#                garuda/). For a complete teardown.
#   quit
#
# This script does not need root; every privileged step is wrapped in sudo, so
# the user is prompted for their password at runtime.
#
set -euo pipefail

# Overridable via environment (used for testing); defaults are the real paths.
PROFILE_REPO="${PROFILE_REPO:-/var/cache/garuda-tools/iso-profiles/garuda}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/var/cache/garuda-tools/garuda-builds/iso/garuda}"
CHROOT_BASE="${CHROOT_BASE:-/var/cache/garuda-tools/garuda-chroots/buildiso}"
KERNEL="linux-t2"

msg()   { printf '%s\n' "$*"; }

# chroot_dir <profile-t2>
chroot_dir() { printf '%s/%s\n' "$CHROOT_BASE" "$1"; }

# iso_dir <profile-t2>
iso_dir() { printf '%s/%s\n' "$OUTPUT_ROOT" "$1"; }

# post_build_note <profile-t2>
# Prints the post-build report identical to build-t2-profile.sh.
post_build_note() {
    local profile="$1"
    local dir
    dir="$(iso_dir "$profile")"
    echo ""
    msg "built iso files are in ${dir}"
    msg ""
    msg "After installing the ISO, review the post-install notes:"
    msg "    POST-INSTALL.md"
    msg "Then run the audio post-install helper (from a user account; uses sudo):"
    msg "    /usr/local/bin/t2-audio.sh"
}

# collect_t2_profiles
# Prints each `<profile>-t2` directory that has a profile.conf (a valid build).
collect_t2_profiles() {
    local d base
    for d in "$PROFILE_REPO"/*-t2/; do
        [ -f "$d/profile.conf" ] || continue
        base="$(basename "$d")"
        printf '%s\n' "$base"
    done
}

# pick_profile
# Lists valid -t2 profiles and prompts for a selection. Sets the global
# PROFILE. Exits on abort.
PROFILE=""

# profile_dir <profile-t2>
profile_dir() { printf '%s/%s\n' "$PROFILE_REPO" "$1"; }

pick_profile() {
    local profiles=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && profiles+=("$line")
    done < <(collect_t2_profiles)

    if [ "${#profiles[@]}" -eq 0 ]; then
        # Backticks escaped so bash treats them literally instead of running
        # \<profile>-t2 as a command substitution (which printed a bogus
        # "profile: No such file or directory" and ate the words).
        msg "ERROR: no valid <profile>-t2 profiles found in ${PROFILE_REPO}." >&2
        exit 1
    fi

    msg "Available -t2 profiles:"
    local i
    for i in "${!profiles[@]}"; do
        printf '  [%d] %s\n' "$((i+1))" "${profiles[$i]}"
    done

    local choice
    while :; do
        read -r -p "Select a profile [1-${#profiles[@]}] (q to quit): " choice
        if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
            msg "Aborted."
            exit 0
        fi
        [[ "$choice" =~ ^[0-9]+$ ]] || { printf '  -> please enter a number\n'; continue; }
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
            PROFILE="${profiles[$((choice-1))]}"
            return 0
        fi
        printf '  -> out of range\n'
    done
}

# delete_chroot <profile-t2>
# Removes the build chroot dir for this profile using sudo. Returns non-zero
# (without exiting) if the dir did not exist so the caller can note it.
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

# clean_iso_outputs <profile-t2>
# Walks the dated output dirs under iso_dir and, for each one that is
# non-empty, asks the user whether to delete it (or skip). Housekeeping only
# never runs sudo and never deletes a directory it cannot confirm.
# Non-empty (rather than "contains a .iso") is the test: the .iso/checksums can
# be moved elsewhere mid-run, leaving other artifacts behind; the dated dir is
# still a build output worth cleaning.
clean_iso_outputs() {
    local profile="$1"
    local dir base
    dir="$(iso_dir "$profile")"

    if [ ! -d "$dir" ]; then
        msg ">> (no output directory: $dir)"
        return 0
    fi

    # Only consider date-stamped subdirectories (e.g. 261010). The trailing
    # '/*/' globs the entries *directly inside* the profile dir; a bare '*/'
    # would instead match the profile dir itself (its name ends the path).
    local found_any=0
    local sub
    for sub in "$dir"/*/; do
        sub="${sub%/}"
        base="$(basename "$sub")"
        # match a pure date-stamp style dir
        [[ "$base" =~ ^[0-9]+$ ]] || continue
        # skip anything that isn't a directory (defensive)
        [ -d "$sub" ] || continue

        # is it non-empty (any entry at all)?
        if ! find "$sub" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
            continue
        fi
        found_any=1

        msg ""
        msg "  ${sub} (non-empty)"
        local ans
        read -r -p "    delete it? [y/N/quit]: " ans
        case "$ans" in
            [yY]|[yY][eE][sS])
                msg "    >> sudo rm -rf $sub"
                sudo rm -rf "$sub"
                ;;
            quit|[qQ])
                msg "    -> stopping clean."
                return 0
                ;;
            *)
                msg "    -> skipping."
                ;;
        esac
    done

    if [ "$found_any" -eq 0 ]; then
        msg ">> no dated ISO output dirs found for $profile"
    fi
    return 0
}

# do_clean <profile-t2>
do_clean() {
    local profile="$1"
    msg ""
    msg "=== clean: $profile ==="
    delete_chroot "$profile" || true
    clean_iso_outputs "$profile"
    msg "Clean finished."
}

# remove_profile <profile-t2>
# Removes the <profile>-t2 profile directory itself. Requires an explicit y so
# a stray keypress can't delete a profile. sudo-wrapped.
remove_profile() {
    local profile="$1"
    local pd ans
    pd="$(profile_dir "$profile")"
    if [ ! -d "$pd" ]; then
        msg ">> (no profile dir to remove: $pd)"
        return 1
    fi
    msg ""
    msg "  ${pd}"
    read -r -p "    delete profile dir? [y/N]: " ans
    case "$ans" in
        [yY]|[yY][eE][sS])
            msg "    >> sudo rm -rf $pd"
            sudo rm -rf "$pd"
            ;;
        *)
            msg "    -> skipping profile dir."
            ;;
    esac
    return 0
}

# do_full_wipe <profile-t2>
# Full teardown: build chroot + dated ISO output dirs + the profile dir itself.
do_full_wipe() {
    local profile="$1"
    msg ""
    msg "=== full wipe: $profile ==="
    delete_chroot "$profile" || true
    clean_iso_outputs "$profile"
    remove_profile "$profile"
    msg "Full wipe finished."
}

# do_build <profile-t2>
do_build() {
    local profile="$1"
    msg ""
    msg "=== build iso: $profile ==="

    # The build chroot must not exist for buildiso to start cleanly; remove it.
    delete_chroot "$profile"

    local build_log
    build_log="$(iso_dir "$profile")/build.log"
    mkdir -p "$(dirname "$build_log")"

    msg ">> sudo buildiso -p $profile -k $KERNEL"
    msg ">> output streamed live and logged to ${build_log}"

    set +e
    script -qefc "sudo buildiso -p \"$profile\" -k \"$KERNEL\"" "$build_log"
    local build_rc=$?
    set -e
    if [ "$build_rc" -ne 0 ]; then
        msg "ERROR: buildiso exited with code ${build_rc}." >&2
        msg "See full log: ${build_log}" >&2
        exit "$build_rc"
    fi

    post_build_note "$profile"
}

############################################
# main loop
############################################
while :; do
    pick_profile

    while :; do
        msg ""
        msg "Current profile: ${PROFILE}"
        printf '  [%d] build iso\n' 1
        printf '  [%d] clean\n'        2
        printf '  [%d] full wipe\n'    3
        choice=""
        read -r -p "What would you like to do? [1-3] (q to quit): " choice
        case "$choice" in
            1) do_build "$PROFILE"; break ;;
            2) do_clean "$PROFILE"; break ;;
            3) do_full_wipe "$PROFILE"; break ;;
            q|Q) msg "Aborted."; exit 0 ;;
            *) printf '  -> please enter 1, 2, 3, or q\n' ;;
        esac
    done

    # A full wipe removes the <profile>-t2 profile itself; if that left the
    # repo with no valid profiles, exit cleanly instead of looping back into
    # pick_profile's "no valid profiles" error. (A run starting with an empty
    # repo still reports through pick_profile, above.)
    if ! collect_t2_profiles | grep -q .; then
        msg "No profiles remaining. Finished."
        exit 0
    fi
done
