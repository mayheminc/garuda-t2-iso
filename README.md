# Garuda Apple T2 ISO - Build Workflow
MayhemINC 2026 - provided with no warranty or liability

see https://wiki.t2linux.org/ for more information and setup tips

* Requires an Arch/Garuda build environment with pacman, script, and garuda-tools

This directory holds the scripts that turn an existing Garuda desktop profile
into a **fresh Apple T2 profile** (`<profile>-t2`) and build a `linux-t2` ISO
from it. It is organized as a small three-script pipeline:

| File | Role |
| --- | --- |
| `build-t2-profile.sh` | Top-level orchestrator (runs end to end, prompts the user) |
| `t2-build-tools.sh` | Interactive loop to build/clean an existing `<profile>-t2` ISO on demand |
| `setup-t2-profile.sh` | Applies the T2 edits and overlays into one fresh `<profile>-t2` directory |
| `POST-INSTALL.md` | Reference for steps to run *after* installing the ISO (at `/usr/local/share/garuda-t2/`) |

`build-t2-profile.sh` copies `setup-t2-profile.sh` (and `POST-INSTALL.md`) into
the fresh `<profile>-t2` directory and runs it there, so `setup-t2-profile.sh`
is self-contained and idempotent - it can also be run manually.

`build-t2-profile.sh` is the *one-shot* path (pick profile → create → setup →
build once). 

`t2-build-tools.sh` is the *repetitive* path: after a `<profile>-t2`
profile already exists you loop on it - build again, or clean up stale
artifacts - without recreating the profile each time.

---

## Quick start

Run the orchestrator from the build host (you will be prompted for your sudo
password at each privileged step):

```bash
./build-t2-profile.sh
```

It will:

1. **Check dependencies** - ensures `script` is available and the
   `garuda-tools-base-git`, `garuda-tools-iso-git`, `garuda-tools-pkg-git`
   packages are installed; offers to `sudo pacman -S --needed` any that are missing.
2. **Ensure the profile structure exists** - if the profile repo is absent, runs
   `sudo buildiso -i` to initialize it.
3. **Pick a profile** - lists the selectable profiles (those with a
   `profile.conf`) and prompts you to select one (`q`/`Q` quits).
4. **Create `<profile>-t2`** - `sudo cp -Rvi <profile> <profile>-t2`. If
   `<profile>-t2` already exists, it prompts to delete it first (or aborts).
5. **Run `setup-t2-profile.sh` inside `<profile>-t2`** - applies the T2 edits
   (see below).
6. **Confirm and build** - asks `Proceed ... [y/N]`, then runs
   `sudo buildiso -p <profile>-t2 -k linux-t2`. Output is streamed live and
   logged to `${OUTPUT_ROOT}/<profile>-t2/build.log`.
7. **Report** - prints where the built ISO files live and reminds you of the
   post-install steps.

### Where the ISO goes

```
/var/cache/garuda-tools/garuda-builds/iso/garuda/<profile>-t2
```

(e.g. `/var/cache/garuda-tools/garuda-builds/iso/garuda/xfce-t2`). A per-run
subdirectory with a date stamp (e.g. `261010`) is created inside it, and
`build.log` is written alongside it.

---

## Interactive build loop - `t2-build-tools.sh`

Once one or more `<profile>-t2` profiles already exist, use `t2-build-tools.sh`
to build or clean them without rebuilding the profile directory:

```bash
./t2-build-tools.sh
```

It:

1. **Scans the profiles directory** (`/var/cache/garuda-tools/iso-profiles/garuda`)
   for valid `<profile>-t2` build profiles (a directory ending in `-t2` that has
   a `profile.conf`) and prompts you to select one (`q` quits). On re-enter it
   re-lists so you can work on a different profile.
2. **Prompts for an action** on that profile:
   - **`build iso`** - removes the profile's stale build chroot with `sudo`
     (a failed `pacman` fetch during a b        printf '  [%d] quit\n'          4uild leaves the chroot in a state that
     makes `buildiso` refuse to start a new one, so this is required before a
     fresh build can run), then runs `sudo buildiso -p <profile>-t2 -k
     linux-t2` and prints the same post-build report `build-t2-profile.sh`
     prints (ISO location + post-install reminder).
   - **`clean`** - housekeeping. Removes the same chroot directory, then walks
     the dated output dirs under
     `/var/cache/garuda-tools/garuda-builds/iso/garuda/<profile>-t2/` and, for
     each one that still contains an `.iso`, asks you to delete it (or skip /
     quit).
   - **`full wipe`** - `clean`, and additionally removes the `<profile>-t2`
     profile directory itself (from
     `/var/cache/garuda-tools/iso-profiles/garuda/`). Use for a complete
     teardown of a profile; the profile-dir removal asks for an explicit `y`.
   - **`quit`**.

Like `build-t2-profile.sh`, it needs no root of its own: every privileged step
(`rm -rf`, `buildiso`) is wrapped in `sudo`, prompting for the password at
runtime.

The build/chroot/output locations match `build-t2-profile.sh` and can be
overridden via the `PROFILE_REPO`, `OUTPUT_ROOT`, and `CHROOT_BASE`
environment variables.

---
t
## What `setup-t2-profile.sh` does

Run from the profile directory itself. Every file is owned by root in a fresh
profile, so all writes go through `sudo`. It is **idempotent** - re-running it
does not duplicate package entries or edits.

Looking at it again the live-overlay is probably redundant and needs pruned but it works for now.

It produces a local editable profile by delinking the two files it actually
edits (`Packages-Live`, `Packages-Root` - it copies the symlink's shared content
to a local file rather than writing *through* the shared template), then:

- **Deletes the `live-overlay` symlink** (a fresh profile ships it as a symlink
  to an empty file, which blocks `mkdir`) and creates the overlay directory tree
  under both `live-overlay` and `desktop-overlay`, including `/usr/local/{share,garuda-t2,bin}`.
- **Appends the `## Apple T2` block** (`linux-firmware-broadcom`,
  `apple-bcm-firmware-fetcher`, `t2fanrd`) to `Packages-Live` and `Packages-Root`.
- **Writes `user-repos.conf`** - the `[arch-mact2]` mirror (`mirror.funami.tech`).
- **Writes `…/modules-load.d/t2.conf`** (both overlays) - `brcmfmac`.
- **Writes `…/modprobe.d/t2.conf`** (both overlays) - blacklists `brcmfmac_wcc` and `hci_bcm4377`.
- **Asks** about the Apple Fn key at the start
- **Writes** `…/modprobe.d/hid_apple.conf` in both overlays with
  `options hid_apple fnmode=<n>`: `1` hold Fn for function keys, `2` hold Fn for
  media keys (the sane default), `0` disable Fn entirely. Just pressing enter defaults
  to `2`; invalid input re-prompts.
- **Writes `…/systemd/system-sleep/t2fanrd`** (both overlays) - post-sleep restart hook, `chmod +x`.
- **Writes `…/systemd/system/apple-bcm-firmware-fetch.service`** (both overlays).
- **Delivers `POST-INSTALL.md`** into both overlays at `/usr/local/share/garuda-t2/`.
- **Writes `t2-audio.sh`** into both overlays at `/usr/local/bin/` (the
  audio post-install helper).
- **Edits `profile.conf` in place** - guarded edits that:
  - add `'t2fanrd' 'apple-bcm-firmware-fetch'` to the `enable_systemd` array,
  - append `-t2` to the live `hostname`.

---

## Post-install (on the installed T2 machine)

After installing the built ISO, review `POST-INSTALL.md` (delivered to
`/usr/local/share/garuda-t2/POST-INSTALL.md`) for the manual steps. In brief:

1. **Kernel cmdline** - append `intel_iommu=on iommu=pt pm_async=off` (via
   `garuda-toolbox/boot-tools` or by editing `/etc/default/grub` and rebuilding GRUB).
2. **Audio** - install `t2-better-audio`; run the helper from a **user account**
   (it prompts for sudo only where root is needed): `/usr/local/bin/t2-audio.sh`.
3. **BCM Wi-Fi/BT firmware** - `apple-bcm-firmware-fetch` pulls drivers from a
   macOS volume on first boot; otherwise extract them from an install image
   (see  https://wiki.t2linux.org/guides/wifi-bluetooth/).
4. **Fan / wifi-bt modules** - `brcmfmac` loaded via `modules-load.d/t2.conf`;
   `brcmfmac_wcc` / `hci_bcm4377` blacklisted via `modprobe.d/t2.conf`;
   `t2fanrd` managed by systemd with a post-sleep restart hook.
5. **Change Fn key behavior** - edit `/etc/modprobe.d/hid_apple.conf` change `options hid_apple fnmode=2`;
    0 - disable Fn key, 1 - Hold Fn for Function Keys, 2 - Hold Fn for Media Keys ;
    then `sudo dracut-rebuild` ; temporarily apply with `echo 2 | sudo tee /sys/module/hid_apple/parameters/fnmode`


All post-install paths are on the **installed** system, not the build host.

---

## Notes / assumptions

- `sudo` requires a password at runtime (this script does not and should not
  hardcode credentials).
- `OUTPUT_ROOT` and `PROFILE_REPO` can be overridden via the environment
  (defaults match the real paths) - this mainly makes the workflow testable.
