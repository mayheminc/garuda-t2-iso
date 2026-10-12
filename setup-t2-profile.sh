#!/bin/bash
#
# setup-t2-profile.sh
#
# MayhemINC 2026 - provided with no warranty or liability
#
# Prepares the Apple T2 Garuda ISO profile.
# Run from the profile directory itself.
#
# In a freshly extracted profile every file is owned by root, so all
# writes go through sudo. The script is idempotent: it can be re-run
# safely and will not duplicate the T2 package entries or edits.
#
set -euo pipefail

# Operate from the directory that contains this script.
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROFILE_DIR"

# Apple Fn/Function Key Handling
# Print the supplied prompt verbatim, then read the mode. Default to 2 on a bare
# enter; the sane default [2] ships out of the box so nobody has to dig through
# macOS System Settings or patch a file to make it behave.
FN_MODE=""
echo ""
echo "Apple Fn/Function Key Handling"
echo ""
echo "[0] Completely disable Fn key - That's a BOLD strategy, Cotton."
echo "[1] Hold Fn for Function Keys - Apples Nonsense Default"
echo "[2] Hold Fn for Media Keys - The ONLY Sane option"
echo ""
while :; do
    if ! read -r -p "options hid_apple fnmode= [0-2] (enter defaults 2): " FN_MODE; then
        FN_MODE=""   # EOF (e.g. piped input) -> take the default
    fi
    case "$FN_MODE" in
        ""|2) FN_MODE=2; break ;;
        1|0)  break ;;
        *) printf '  -> please enter 0, 1, or 2 (enter defaults 2)\n'; continue ;;
    esac
done
echo ">> Fn key handling set to mode ${FN_MODE}"

# emit <path>
# Writes the heredoc body on stdin to <path> via sudo tee.
emit() {
    mkdir -p "$(dirname "$1")"
    sudo tee "$1" >/dev/null
}

# append_packages <file>
# Delinks the file if it is a symlink (so we edit a LOCAL copy instead of
# writing through to the shared template that every other profile derives
# from), then idempotently appends the "## Apple T2" block.
append_packages() {
    local file="$1"
    if grep -q '^## Apple T2$' "$file"; then
        return 0
    fi
    # Only the files we actually edit are delinked; untouched Packages* files
    # stay as symlinks. Read the real target BEFORE removing the symlink, then
    # copy its content back to a fresh local file.
    if [ -L "$file" ]; then
        local target
        target="$(readlink -f "$file")"
        sudo rm -f "$file"
        sudo cp -a "$target" "$file"
    fi
    {
        echo
        echo '## Apple T2'
        echo 'linux-firmware-broadcom'
        echo 'apple-bcm-firmware-fetcher'
        echo 't2fanrd'
    } | sudo tee -a "$file" >/dev/null
}

echo ">> Removing overlay symlinks and creating directories"

# A fresh profile ships live-overlay as a symlink (to an empty file), which
# blocks mkdir. Remove the symlink itself (leaving the target intact) so the
# real directory tree can be created. Guarded with -L so an idempotent re-run
# (where live-overlay is already a real directory) does not try to remove it.
if [ -L ./live-overlay ]; then
    sudo rm -f ./live-overlay
fi

sudo mkdir -p \
    ./live-overlay/etc/modules-load.d \
    ./desktop-overlay/etc/modules-load.d \
    ./live-overlay/etc/modprobe.d \
    ./desktop-overlay/etc/modprobe.d \
    ./live-overlay/usr/lib/systemd/system-sleep \
    ./desktop-overlay/usr/lib/systemd/system-sleep \
    ./live-overlay/etc/systemd/system \
    ./desktop-overlay/etc/systemd/system \
    ./live-overlay/usr/local/share/garuda-t2 \
    ./desktop-overlay/usr/local/share/garuda-t2 \
    ./live-overlay/usr/local/bin \
    ./desktop-overlay/usr/local/bin \

echo ">> Appending T2 packages to Packages-Live and Packages-Root"

append_packages ./Packages-Live
append_packages ./Packages-Root

echo ">> Writing user-repos.conf"

emit ./user-repos.conf <<'EOF'
[arch-mact2]
Server = https://mirror.funami.tech/arch-mact2/os/$arch
SigLevel = Never
EOF

echo ">> Writing modules-load.d/t2.conf"

for d in ./live-overlay ./desktop-overlay; do
    emit "$d/etc/modules-load.d/t2.conf" <<'EOF'
brcmfmac
EOF
done

echo ">> Writing modprobe.d/t2.conf"

for d in ./live-overlay ./desktop-overlay; do
    emit "$d/etc/modprobe.d/t2.conf" <<'EOF'
blacklist brcmfmac_wcc
blacklist hci_bcm4377
EOF
done

echo ">> Writing modprobe.d/hid_apple.conf"

for d in ./live-overlay ./desktop-overlay; do
    emit "$d/etc/modprobe.d/hid_apple.conf" <<EOF
options hid_apple fnmode=$FN_MODE
EOF
done

echo ">> Writing system-sleep/t2fanrd and marking executable"

for d in ./live-overlay ./desktop-overlay; do
    emit "$d/usr/lib/systemd/system-sleep/t2fanrd" <<'EOF'
#!/bin/sh
if [ "$1" = "post" ]; then
    /usr/bin/systemctl try-restart t2fanrd.service
fi
EOF
    sudo chmod +x "$d/usr/lib/systemd/system-sleep/t2fanrd"
done

echo ">> Writing apple-bcm-firmware-fetch.service"

for d in ./live-overlay ./desktop-overlay; do
    emit "$d/etc/systemd/system/apple-bcm-firmware-fetch.service" <<'EOF'
[Unit]
Description=Fetch Apple BCM firmware from macOS volume
After=local-fs.target
ConditionPathExists=/lib/firmware/brcm
ConditionPathExists!=/etc/firmware-bcm-fetched  # skip if already done

[Service]
Type=oneshot
ExecStart=/usr/bin/apple-bcm-firmware-fetcher
ExecStartPost=/bin/touch /etc/firmware-brcm-fetched
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
done

echo ">> Delivering POST-INSTALL.md into both overlays"

# POST-INSTALL.md is the real source file (copied alongside this setup script by
# the build wrapper). Copy it into each overlay at its /usr/local delivery path so
# it is reachable from both the live environment and the installed system. Guarded
# so a standalone run (without the copy) degrades gracefully and stays idempotent.
if [ -f POST-INSTALL.md ]; then
    for d in ./live-overlay ./desktop-overlay; do
        sudo cp -a POST-INSTALL.md "$d/usr/local/share/garuda-t2/"
    done
else
    echo "!! WARNING: POST-INSTALL.md not found next to this setup script; skipping overlay delivery." >&2
fi

echo ">> Generating t2-audio.sh (audio post-install helper) into both overlays"

# Generate the audio helper via emit (same as the other overlay files). Because it
# is generated inside the image rather than living on the build system, it can
# never be accidentally run during the build.
for d in ./live-overlay ./desktop-overlay; do
    emit "$d/usr/local/bin/t2-audio.sh" <<'AUDIO_EOF'
#!/bin/bash
#
# t2-audio.sh
#
# Audio post-install helper for the Apple T2 Garuda ISO. Run this from a NORMAL
# USER account after installing the built ISO on a T2 machine (not on the build
# host, and not via sudo).
#
# It installs kekrby/t2-better-audio (audio fixes / kernel-pipewire tuning).
# Only steps that genuinely require root are wrapped in sudo, so you will be
# prompted for your password at those points.
#
set -euo pipefail

# Destination for the clone. Prefer the invoking user's home so the script can
# be run from the user account post install; fall back to /tmp when HOME is
# unset/unusable (e.g. a live context where no home dir exists yet).
DEST="${HOME:-/tmp}/t2-better-audio"
AUDIO_URL="https://github.com/kekrby/t2-better-audio.git"

echo ">> audio post-install (t2-better-audio)"

# Clean any previous attempt.
if [ -d "$DEST" ]; then
    sudo rm -rf "$DEST"
fi

echo ">> cloning $AUDIO_URL -> $DEST"
git clone "$AUDIO_URL" "$DEST"

cd "$DEST"
echo ">> running install.sh (needs root)"
sudo ./install.sh

echo ">> cleaning up clone"
sudo rm -rf "$DEST"

echo ">> audio post-install complete"
AUDIO_EOF
    sudo chmod +x "$d/usr/local/bin/t2-audio.sh"
done

echo ">> Editing profile.conf in place"

# Edit the in-directory profile.conf directly. Both edits are
# guarded so re-running the script is idempotent:
#   * add 't2fanrd' 'apple-bcm-firmware-fetch' to the enable_systemd array
#   * append "-t2" to the live hostname
if ! grep -q "'t2fanrd' 'apple-bcm-firmware-fetch')" profile.conf; then
    # Anchor to the closing paren of the enable_systemd=(...) array so it works
    # regardless of the profile's last service.
    sudo sed -i \
        -E "s/^enable_systemd=\((.*)\)\$/enable_systemd=(\1 't2fanrd' 'apple-bcm-firmware-fetch')/" \
        profile.conf
fi

if ! grep -qE '^hostname="[^"]*-t2"$' profile.conf; then
    sudo sed -i \
        -e 's/hostname="\([^"]*\)"/hostname="\1-t2"/' \
        profile.conf
fi

echo ">> Done. Apple T2 profile setup complete."
