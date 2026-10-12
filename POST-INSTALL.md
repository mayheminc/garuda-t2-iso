# Post-install notes for the garuda Apple T2 ISO
# MayhemINC 2026 - provided with no warranty or liability

These are the manual steps to run **after** you have installed the built ISO
on a T2 machine. This file is the reference; `post-install.sh` (the companion
script delivered to `/usr/local/bin/post-install.sh`) automates the audio step.

All paths are on the freshly-installed system, not the ISO build machine.

These files are delivered into the system image at:

- Notes reference:  `/usr/local/share/garuda-t2/POST_INSTALL.md`
- Audio helper:      `/usr/local/bin/post-install.sh`

`/usr/local/...` is chosen (rather than `/home/<user>`) because the user home
directory does not exist yet in the live environment - it is only created once
Calamares runs. `/usr/local` exists in both the live system and the installed
system, so the notes and helper are reachable from the user account after
install.

---

## 1. Kernel command line (post install)

use garuda-toolbox/boot-tools OR edit /etc/defaults/grub and rebuild grub

append to kernel parameters: " intel_iommu=on iommu=pt pm_async=off"

---

## 2. Audio post install

Installs [t2-better-audio](https://github.com/kekrby/t2-better-audio):

```bash
sudo git clone https://github.com/kekrby/t2-better-audio.git /tmp/t2-better-audio
cd /tmp/t2-better-audio
./install.sh
sudo rm -r /tmp/t2-better-audio
cd -
```

> Run the same thing via the helper script (run as the normal user, not as
> root); it will prompt for your sudo password:
> `/usr/local/bin/post-install.sh`

---

## 3. Apple BCM Wi-Fi/BT firmware (macOS volume)

The `apple-bcm-firmware-fetch` service pulls the Broadcom firmware from a
macOS volume on first boot. It requires an existing macOS install to rip the
drivers from; otherwise follow the wiki to extract them from an install image:

<https://wiki.t2linux.org/guides/wifi-bluetooth/>

---

## 4. fan / wifi-bt modules

- `brcmfmac` is loaded via `modules-load.d/t2.conf`
- `brcmfmac_wcc` and `hci_bcm4377` are blacklisted via `modprobe.d/t2.conf`
- `t2fanrd` is managed via systemd; its post-sleep hook restarts the service

## 5. Apple Fn key mode

- edit `/etc/modprobe.d/hid_apple.conf`
- change `options hid_apple fnmode=2`
    0 - Completely disable Fn key
    1 - Hold Fn for Function Keys
    2 - Hold Fn for Media Keys
```bash
sudo dracut-rebuild   
```
- apply to current session, resets on reboot
```bash
echo 2 | sudo tee /sys/module/hid_apple/parameters/fnmode=2
```
