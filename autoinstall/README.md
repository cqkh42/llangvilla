# Zero-touch Arch Linux USB (Ventoy + custom ISO + pacstrap)

**End goal:** plug a USB stick into the desktop, boot it, walk away. About 15-25 minutes later the machine powers itself off with Arch Linux installed: your user, your Wi-Fi, key-only SSH, KDE Plasma, btrfs (or ext4), systemd-boot, and a first-boot hook that hands over to the config. Unplug the stick, power on, log in.

This guide is **part 1** of the repo: getting a box to a clean slate. Personalising it is part 2 ([`config/README.md`](../config/README.md)), which also runs on its own later, without the stick. Trying both in a VM is part 3 ([`vm/README.md`](../vm/README.md)). Section 13 lists the gotchas specific to this setup.

---

## 0. How it works

Files in this folder:

| File | Purpose |
|---|---|
| `build-usb.sh` | Run on your PC. Builds the ISO (in Docker), downloads Ventoy, sets up the stick |
| `build.sh` | Runs inside an Arch Docker container. Builds the ISO with `archiso` and bakes in `install.sh` |
| `install.sh` | Runs on the live ISO. Partitions, runs `pacstrap`, configures the system, powers off. `install.sh --check FILE` validates a config anywhere |
| `packages.txt` | The package list for the installed system (in git; copied onto the stick) |
| `autoinstall.env.example` | Template for the stick's `autoinstall.env` (placeholders only, never commit real values) |

What ends up on the stick:

```
Ventoy USB stick
├── arch-autoinstall.iso        <- custom Arch ISO (generic, no secrets)
├── ventoy/ventoy.json          <- makes Ventoy auto-boot the ISO
└── arch-autoinstall/
    ├── autoinstall.env         <- Wi-Fi, password hash, hostname, disk, SSH... (your secrets)
    ├── packages.txt            <- copied from the repo on every build-usb.sh run
    └── logs/                   <- written by the installer after every run
```

Boot sequence on the target machine:

1. Ventoy menu -> auto-boots `arch-autoinstall.iso`.
2. The Arch live environment logs in as root and automatically runs `/root/install.sh`.
3. `install.sh` finds the stick's config folder and validates it, gets online (cable or Wi-Fi), refreshes the keyring and checks every package name exists, picks the target disk and confirms (section 8), then partitions (GPT, EFI + btrfs subvolumes).
4. `pacstrap` installs the packages; the script writes fstab, locale, hostname, user + password hash, sudo, Wi-Fi profile, SSH keys, zram swap, the first-boot hook and systemd-boot entries; logs go back to the stick and the machine powers off.

Nothing is erased until the config, network, keyring and package list have all checked out.

> **WARNING:** this stick erases a disk. Keep it physically safe (it holds your Wi-Fi password and a password hash). A disk that already holds data is never erased on a timer: someone must type `YES` (section 8).

### Assumptions (change them in `autoinstall.env` / `packages.txt`)

| Item | Assumed |
|---|---|
| Build computer | Linux with Docker and internet (Arch, or any distro) |
| Target machine | UEFI desktop, at least 40 GB disk, Secure Boot off |
| Filesystem / bootloader | btrfs with subvolumes (or `ROOT_FS=ext4`); systemd-boot |
| Desktop | KDE Plasma (Wayland) with SDDM; apps, theming and settings come from the config (part 2) |
| Region | `Europe/London`, `en_GB.UTF-8`, console keymap `uk`, desktop layout `gb` |
| Identity | User `jack`, hostname `optiplex` |
| SSH | `sshd` enabled, keys from `https://github.com/cqkh42.keys`, password login off |
| First boot | Clones this repo to `/opt/llangvilla` and runs `config/apply.sh` (section 10b) |
| Not covered | Disk encryption, Secure Boot signing, dual boot |

---

## 1. What you need

- A USB stick of 4 GB or more (it will be erased the first time).
- The build computer from section 2.
- About 30 minutes for the first build, most of it waiting.

---

## 2. Prepare the build computer

Docker builds the ISO; QEMU, UEFI firmware and mtools are for the VM tests.

On Arch:

```bash
sudo pacman -S --needed docker qemu-desktop edk2-ovmf mtools dosfstools openssh openssl curl rsync udisks2 git
sudo systemctl enable --now docker
sudo usermod -aG kvm "$USER"     # then log out and in, so VMs run at full speed
```

On Debian/Ubuntu:

```bash
sudo apt install -y docker.io qemu-system-x86 qemu-utils ovmf mtools dosfstools openssh-client openssl curl rsync udisks2 git
sudo systemctl enable --now docker
sudo usermod -aG kvm "$USER"
```

`vm/test-vm.sh` finds the UEFI firmware by itself (set `OVMF_CODE` and `OVMF_VARS` if it can't). Sanity-check Docker with `sudo docker run --rm hello-world`.

Why Docker even on Arch? It gives a clean, current Arch with `archiso` for every build, without installing build tooling on your machine.

---

## 3. Get the scripts

```bash
git clone https://github.com/cqkh42/llangvilla.git
cd llangvilla
```

`build-usb.sh` uses the files next to it, so local edits are used by the next build. (It can also run straight from GitHub, `bash -c "$(curl -fsSL https://raw.githubusercontent.com/cqkh42/llangvilla/refs/heads/main/autoinstall/build-usb.sh)"`, in which case it downloads them from `main`.) Everything it downloads or builds is cached in `~/.cache/llangvilla/`.

---

## 4. Build the ISO

```bash
eval "$(autoinstall/build-usb.sh)"
```

With no disk given, this only builds the ISO and downloads Ventoy:

- The ISO is built in an `archlinux:latest` container with `--privileged` (`mkarchiso` needs mounts and chroots). It takes roughly 5-15 minutes and prints a lot.
- The result lands in `~/.cache/llangvilla/iso-build/out/arch-autoinstall-YYYY.MM.DD-x86_64.iso` and the `eval` sets `$ISO` to it.
- Re-runs reuse the cached ISO unless `build.sh` or `install.sh` changed. `--rebuild` forces a fresh one.

The ISO is only a bootable shell plus `install.sh`: packages come from the live mirrors at install time, so an old ISO still installs a current system. Rebuild when you change `install.sh` or every few months (section 11).

**If the build fails:** read the last 30 lines of output. Most failures are network hiccups (just re-run).

---

## 5. Configure

There are two inputs. Neither needs a VM or an interactive installer.

### 5a. `packages.txt` (in git)

The clean-slate package list: Plasma and SDDM, PipeWire, open-source graphics, Bluetooth, snapshot tooling, a few base tools. Edit it in the repo and commit; it is copied onto the stick on every `build-usb.sh` run (and onto the test stick by `vm/test-vm.sh`), so no ISO rebuild is needed. The installer always adds what the system needs to boot and what your settings imply (base, kernels, microcode, NetworkManager, btrfs-progs, openssh, git). Every name is checked against the repositories **before** the disk is touched, so a typo stops the install safely.

Keep it to what the box needs to boot to a usable desktop on this hardware. Apps and anything you'll want to change on the live machine belong in the config (`config/ansible/roles/packages`), because changing `packages.txt` only takes effect on the next reinstall.

`sddm` and `bluetooth` are enabled automatically when their packages are in the list.

### 5b. `autoinstall.env` (on the stick only)

`build-usb.sh` copies `autoinstall.env.example` onto the stick the first time (section 6). Every setting is explained in the file. The ones you must fill in:

| Setting | How |
|---|---|
| `WIFI_SSID`, `WIFI_PSK` | Your Wi-Fi, or `''` for both if the machine is cabled |
| `PASSWORD_HASH` | Run `openssl passwd -6`, type the password twice, paste the whole `$6$...` line in single quotes |

Worth changing:

| Setting | Why |
|---|---|
| `TARGET_DISK` | Pin the OptiPlex's disk with its `/dev/disk/by-id/...` path (boot the stick on the OptiPlex: its disk already holds data, so the installer stops at the `YES` prompt. Press Enter to abort, then run `ls -l /dev/disk/by-id/` at the root shell and match the model and serial it printed). `auto` = largest internal disk of at least 40 GB |
| `SSH_KEYS_URL` / `SSH_AUTHORIZED_KEYS` | Where your public keys come from. With no key installed, password login stays on (with a warning) so you are never locked out |

Check the file from the build computer before booting anything:

```bash
autoinstall/install.sh --check "$V/arch-autoinstall/autoinstall.env"
```

It lists every problem at once (placeholders left, plain-text password instead of a hash, unknown timezone, short Wi-Fi password...). `build-usb.sh` runs this check at the end, and the installer runs it again before doing anything.

---

## 6. Build the stick

Find your stick's device name. Run this with the stick **unplugged**, then again **plugged in**; the new line is your stick:

```bash
lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN=="usb"'
```

**Triple-check the size and model. Picking the wrong disk destroys it.** Then:

```bash
eval "$(autoinstall/build-usb.sh /dev/sdX)"
```

The script:

1. refuses anything that is not a whole, USB-attached disk;
2. installs Ventoy if the stick doesn't have it yet (it shows the disk and makes you type its path before erasing; Ventoy asks its own `y/n` questions too). A stick that already has Ventoy is kept as is. `--force` wipes and reinstalls it;
3. mounts the stick (no unplugging needed) and sets `$V` to its mount point;
4. copies the ISO (only if changed), `packages.txt` (always), `ventoy.json` and the `autoinstall.env` template (only if missing);
5. runs `install.sh --check` on the stick's `autoinstall.env`.

### 6a. The ISO

Copied to `$V/arch-autoinstall.iso` (a fixed name, so `ventoy.json` never needs editing when you rebuild).

### 6b. Fill in `autoinstall.env`

```bash
nano "$V/arch-autoinstall/autoinstall.env"
autoinstall/install.sh --check "$V/arch-autoinstall/autoinstall.env"
```

The file is sourced by bash, so use single quotes. A Wi-Fi password containing a single quote `'` needs escaping (avoid it or change the password). WPA3-only (SAE) networks need `key-mgmt=sae` in the script; WPA2 and WPA2/WPA3 mixed work as written.

If the stick still has `user_configuration.json` / `user_credentials.json` from the old archinstall flow, `build-usb.sh` warns about them: delete them (the credentials file holds a password hash).

### 6c. `ventoy/ventoy.json`

Written only if the stick doesn't have one:

```json
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/arch-autoinstall.iso" }
  ]
}
```

Ventoy boots the Arch ISO automatically after 10 seconds. If the stick already has a `ventoy.json` that doesn't mention `/arch-autoinstall.iso`, the script warns you: **merge** the two `control` entries into it by hand. To choose manually every time, leave out `VTOY_DEFAULT_IMAGE`.

### 6d. Flush and eject

```bash
sync
udisksctl unmount -b "$(findmnt -no SOURCE "$V")"
```

---

## 7. Test in a VM

Moved to [`vm/README.md`](../vm/README.md): `vm/test-vm.sh` installs from the working tree into a QEMU VM, checks the base system, then applies `config/` and checks again. Do this after every change to `install.sh` or `packages.txt`, and before trusting a stick with real hardware.

---

## 8. Run it on the real machine

1. Plug the stick into the desktop. Plug in an Ethernet cable if you can (optional).
2. In the firmware setup (usually `F2` or `F12` on a Dell) make sure **Secure Boot is OFF** and boot mode is **UEFI**.
3. Open the one-time boot menu (`F12`) and choose the **USB stick, UEFI entry**.
4. Ventoy auto-boots the ISO after 10 seconds. The installer prints its plan and `TARGET DISK: ...`.
5. **Confirm:**
   - A **blank** disk gets the `CONFIRM_SECONDS` countdown (any key aborts).
   - A disk that **already has partitions or a filesystem** (a reinstall, or the stick left in by mistake) waits until you type `YES`. Anything else aborts without erasing. `NONBLANK_DISK=wipe` turns this off; don't leave it on.
6. Walk away. When it says `INSTALL COMPLETE`, the machine powers off.
7. **Remove the stick** and power on. If `CONFIG_REPO_URL` is set, the first boot hands over to the config (console text for a few minutes) and reboots by itself once. The second boot lands on the SDDM login.

If Ventoy hangs at boot: restart, select the Arch ISO manually and use Ventoy's **GRUB2 mode** (press `F1` in the Ventoy menu for the key combo).

---

## 9. Verify the installed system

`vm/test-vm.sh check` runs these automatically in the VM. On the real machine:

```bash
systemctl --failed                  # ideally empty
nmcli device status                 # Wi-Fi or ethernet "connected"
lsblk -f                            # EFI (vfat) + btrfs
sudo btrfs subvolume list /         # @, @home, @log, @pkg, @.snapshots
bootctl status                      # systemd-boot installed
hostnamectl                         # hostname 'optiplex'
getent passwd jack                  # full name in the 5th field
sudo sshd -T | grep -i passwordauth # 'no' if a key was installed
swapon --show                       # zram0
systemctl status llangvilla-firstboot.service
journalctl -u llangvilla-firstboot.service -b   # the config's first run
```

---

## 10. Optional extras

### 10a. Snapshots with snapper

`snapper` and `snap-pac` are in `packages.txt`. The standard Arch-wiki sequence for an `@.snapshots` layout:

```bash
sudo umount /.snapshots
sudo rm -r /.snapshots
sudo snapper -c root create-config /
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo mount -a
sudo chmod 750 /.snapshots
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
```

`snap-pac` then snapshots before and after every `pacman` transaction. The installer removes `subvolid=` from fstab so a rollback still mounts. Caveat: `/boot` (the EFI partition) is not in snapshots, so after rolling back root, kernels in `/boot` can be newer than the restored modules. Use `linux-lts` as your fallback and reinstall kernels after a rollback.

### 10b. The first-boot hook (hand-over to the config)

This is the only link between the installer and the config. Set `CONFIG_REPO_URL`, optionally `CONFIG_REPO_BRANCH`, and `CONFIG_ENTRYPOINT` (default `config/apply.sh`) in `autoinstall.env`. The installer adds `git`, writes `/usr/local/lib/llangvilla/firstboot.sh` and `llangvilla-firstboot.service`, and enables the unit together with `NetworkManager-wait-online.service`, so `network-online.target` genuinely waits for the network.

On first boot the unit clones the repo to `/opt/llangvilla` and runs the entrypoint from it. It knows nothing about Ansible or what the entrypoint does: that is the config's business (`config/README.md`). The checkout stays, so later runs are just `sudo /opt/llangvilla/config/apply.sh`.

**When it runs** is controlled by `FIRSTBOOT_BEFORE_LOGIN`:

- `1` (default): the unit is ordered `Before=display-manager.service`, so SDDM does not start until the config has been applied. If it fails, SDDM still starts, no "done" marker (`/var/lib/llangvilla/firstboot.done`) is written, and the next boot tries again.
- `0`: it runs in the background while the login screen is already showing, and retries every 60 seconds until it succeeds.

**Reboot after success:** with `FIRSTBOOT_REBOOT_AFTER=1` (default) the machine reboots once when the hook succeeds. The done marker is written *before* the reboot, so it can't loop, and a failed run never reboots. Using it with `FIRSTBOOT_BEFORE_LOGIN=0` isn't recommended (it could reboot while someone is logged in).

An `autoinstall.env` from before this hook was generic still has `ANSIBLE_*` settings; `install.sh --check` rejects it with a message naming the new settings.

### 10c. Nvidia graphics

The stick installs open-source drivers (nouveau), which gives a working desktop. After install: `sudo pacman -S nvidia-open nvidia-utils` and reboot. Put this in the config (`config/`) if you need it.

---

## 11. Maintenance

- **Changing packages:** first decide which list it belongs in (section 5a). For the base: edit `packages.txt`, run `vm/test-vm.sh`, commit, re-run `build-usb.sh /dev/sdX` to refresh the stick. No ISO rebuild. Everything else: `config/README.md`.
- **Changing Wi-Fi, user, hostname, disk:** edit `autoinstall.env` on the stick and re-run `install.sh --check` on it.
- **Changing the installer:** edit `install.sh`, run `vm/test-vm.sh` (it uses your working copy), commit, then `build-usb.sh /dev/sdX` rebuilds the ISO automatically because `install.sh` changed.
- **Rebuilding the ISO** every few months (`--rebuild`) keeps the live environment's kernel, firmware and tools fresh for newer hardware. The installed system is current either way, since `pacstrap` uses the live mirrors and the installer refreshes the keyring first.

---

## 12. Troubleshooting

Every run (including failures) leaves `arch-autoinstall/logs/install-*.log` and `last-status` on the stick. On failure the installer stops at a root shell; fix the problem and run `/root/install.sh` again.

| Symptom | Likely cause and fix |
|---|---|
| "Verification failed" / blue Ventoy screen | Secure Boot is on. Turn it off in firmware. |
| Stick doesn't appear in the boot menu | Write was incomplete or the port is odd. Try another port, run `sync` after copying, re-run Ventoy install. |
| Black screen / hang after choosing the ISO | Reboot, select the ISO, choose **GRUB2 mode** (`F1` for key hints). |
| `Could not find arch-autoinstall/autoinstall.env` | At the shell, run `lsblk -f`. The data partition should be exFAT. Mount it by hand (`mount /dev/sdX1 /mnt/usbdata`, or the `/dev/mapper/...` device Ventoy exposes) and confirm the folder is named exactly `arch-autoinstall`. |
| `autoinstall.env has problems` | The list says what. Run `install.sh --check` on the build computer next time. |
| `Some packages ... do not exist` | A typo or a renamed package in `packages.txt` / `EXTRA_PACKAGES`. The pacman error above it names it. Nothing was erased. |
| `No wireless interface found` | Missing Wi-Fi firmware or an unusual chip. Use an Ethernet cable for the install. |
| `No internet over Wi-Fi` | SSID or password typo in `autoinstall.env`; check quoting. WPA3-only networks aren't supported as written. |
| `Could not refresh the Arch keyring` / signature errors | Usually a wrong clock or a mirror problem. Check `timedatectl`, then re-run `/root/install.sh`. |
| `No suitable target disk found` | The internal disk is under 40 GB, on a USB bridge, or the pinned `TARGET_DISK` path doesn't exist on this machine. Check `ls -l /dev/disk/by-id/`. |
| It asks me to type YES | The target disk already holds data. Type `YES` only if you mean to erase it. If the stick was left in by mistake, press Enter and remove it. |
| `pacstrap failed twice` | A mirror problem or a package conflict; the log shows which. Re-run `/root/install.sh`. |
| `sgdisk`/`wipefs` says the disk is busy | Leftover RAID/LVM the installer couldn't stop. At the shell: `vgchange -an; mdadm --stop --scan`, then re-run. |
| Installed OS boots straight back to the stick | Remove the stick, or put the internal disk first in firmware boot order. The installer won't wipe a non-blank disk without `YES`. |
| No boot entry in the firmware menu | The installer falls back to `\EFI\BOOT\BOOTX64.EFI`, which firmware lists as the disk itself. Run `sudo bootctl install` once booted. |
| Wi-Fi not connected after install | `nmcli device wifi connect 'SSID' password 'PASS'`; the profile is `/etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection` (mode 600). |
| Can't SSH in | Key login only by default. Check `~jack/.ssh/authorized_keys`, and that `SSH_KEYS_URL` served your key at install time (the log says how many were installed). |
| First-boot hook keeps failing | `journalctl -u llangvilla-firstboot.service -b`. A clone failure is the hook's (network, URL, branch); anything after that is the config's, see `config/README.md`. |
| VM test problems | `vm/README.md`. |

---

## 13. Gotchas specific to this setup

**1. The config is a separate part.** What the first boot (and every later run) applies, and the rules it must follow because it runs before login, are in `config/README.md`.

**2. Failure behaviour depends on `FIRSTBOOT_BEFORE_LOGIN`.** With `1`, a failing hook is attempted once per boot (SDDM then starts anyway). With `0`, it retries every 60 seconds until it passes. The "done" marker is only written on success.

**3. With `FIRSTBOOT_BEFORE_LOGIN=1` the first boot is slow.** Console text for several minutes (the config installs its own tools, then applies; up to 30, then systemd gives up and SDDM starts regardless). Don't power off during it.

**4. The repo must be public.** The unit clones over HTTPS with no credentials.

**5. KDE Plasma is what `packages.txt` says.** `plasma-meta`, SDDM, a terminal and a file manager. Apps and desktop settings belong in the config.

**6. SSH is key-only when a key was installed, and Arch has no firewall.** If no key could be fetched, password login stays on and the install log warns about it.

**7. Same hostname on every machine.** One env file means one hostname. Change `HOST_NAME` per machine.

**8. ext4 vs btrfs.** If the config or backup tooling assumes ext4, set `ROOT_FS=ext4`. With ext4, section 10a doesn't apply.

**9. Secure Boot and Ventoy.** It must be off: the Arch ISO and systemd-boot are unsigned.

**10. The config runs before login on first boot.** So it must not restart SDDM or reboot; the full list is in `config/README.md`.

---

## 14. Keeping secrets out of the repo

The repo is public. Only templates, scripts and the package list live in git; the real values exist **only on the stick**:

| Secret | Lives in |
|---|---|
| Wi-Fi SSID and password | `arch-autoinstall/autoinstall.env` on the stick |
| Password hash | `arch-autoinstall/autoinstall.env` on the stick (`PASSWORD_HASH`) |

`.gitignore` blocks `autoinstall.env`, `*.iso` and `*.qcow2` in case one is ever copied into the checkout. A password hash in a public repo can be cracked offline, so keep it out of git even though it's "only" a hash. The VM tests use their own throwaway password and key, kept in `~/.cache/llangvilla/vm/`.
