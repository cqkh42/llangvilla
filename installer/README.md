# installer

Zero-touch Arch Linux installer on a Ventoy USB stick. Boot the stick and the machine installs itself and powers off, about 15–25 minutes later. The result is a clean base system: user, Wi-Fi, key-only SSH, KDE Plasma, btrfs and systemd-boot. Its first boot hands over to the [config](../config/README.md).

> [!WARNING]
> The installer erases the target disk. A disk that already holds data is never erased without someone typing `YES` at the console. The stick holds your Wi-Fi password and a password hash, so keep it physically safe.

## Quick start

```bash
git clone https://github.com/cqkh42/llangvilla.git && cd llangvilla
lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN=="usb"'     # find the stick
eval "$(installer/build-usb.sh /dev/sdX)"                      # build ISO + stick, sets $V
nano "$V/arch-autoinstall/autoinstall.env"                     # fill in the placeholders
installer/install.sh --check "$V/arch-autoinstall/autoinstall.env"
sync && udisksctl unmount -b "$(findmnt -no SOURCE "$V")"
```

Then boot the target machine from the stick's UEFI entry with Secure Boot off ([Installing](#installing)).

## How it works

### Components

| File | Runs on | Purpose |
|---|---|---|
| `build-usb.sh` | Build computer | Builds the ISO in Docker, downloads Ventoy, writes and populates the stick |
| `build.sh` | Docker container | Builds the ISO with `archiso` and bakes in `install.sh` |
| `install.sh` | Live ISO | Validates the config, partitions, runs `pacstrap`, configures the system, powers off |
| `packages.txt` | — | Base package list. Copied onto the stick on every build, not baked into the ISO |
| `autoinstall.env.example` | — | Template for the stick's `autoinstall.env` |

### Stick layout

```
<Ventoy data partition>
├── arch-autoinstall.iso        custom Arch ISO (generic, no secrets)
├── ventoy/ventoy.json          auto-boots the ISO
└── arch-autoinstall/
    ├── autoinstall.env         machine settings and secrets
    ├── packages.txt            refreshed from the repo on every build-usb.sh run
    ├── install.sh              optional; replaces the ISO's copy (used by vm/test-vm.sh)
    └── logs/                   install-*.log, last-status
```

### Install sequence

1. Ventoy boots `arch-autoinstall.iso`; the live system runs `/root/install.sh`.
2. `install.sh` finds `arch-autoinstall/autoinstall.env` and validates it.
3. It connects to the network (cable, else Wi-Fi), syncs the clock and refreshes the keyring.
4. It resolves every package name against the repositories.
5. It selects the target disk and asks for confirmation.
6. It partitions the disk (GPT: 1 GiB ESP + root) and creates the btrfs subvolumes `@`, `@home`, `@log`, `@pkg` and `@.snapshots`.
7. `pacstrap` installs the packages.
8. It configures the system: fstab, locale, hostname, user, sudo, Wi-Fi, SSH, zram (with zswap off on the kernel command line), the first-boot hook and systemd-boot.
9. It copies the logs to the stick and powers off.

Nothing is written to the target disk before step 6. A bad setting, network problem or unknown package stops the install with the disk untouched.

## Requirements

| | Requirement |
|---|---|
| Build computer | Linux with Docker and internet access |
| USB stick | 4 GB or more (erased the first time) |
| Target machine | UEFI, Secure Boot off, internal disk of 40 GB or more |

Build computer packages (QEMU, OVMF and mtools are only for [`vm/`](../vm/README.md)):

```bash
# Arch
sudo pacman -S --needed docker qemu-desktop edk2-ovmf mtools dosfstools openssh openssl curl rsync udisks2 git
# Debian / Ubuntu
sudo apt install -y docker.io qemu-system-x86 qemu-utils ovmf mtools dosfstools openssh-client openssl curl rsync udisks2 git

sudo systemctl enable --now docker
sudo usermod -aG kvm "$USER"        # log out and in again
```

Docker is used even on Arch so that every build gets a clean, current Arch with `archiso`.

## Building the stick

### 1. Build the ISO

```bash
eval "$(installer/build-usb.sh)"
```

With no disk argument, `build-usb.sh` only builds the ISO and downloads Ventoy. The build runs in a privileged `archlinux:latest` container and takes 5–15 minutes. The ISO is cached in `~/.cache/llangvilla/iso-build/out/` and reused until `build.sh` or `install.sh` changes.

The ISO is only a live system plus `install.sh`. Packages come from the mirrors at install time, so an old ISO still installs a current system.

### 2. Write the stick

Run `lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN=="usb"'` with the stick unplugged and then plugged in; the new line is the stick. Check the size and model: the wrong disk will be erased.

```bash
eval "$(installer/build-usb.sh /dev/sdX)"
```

It refuses anything that isn't a whole USB disk, and asks you to type the disk path before installing Ventoy. A stick that already has Ventoy is kept (`--force` reinstalls it), so re-running it on a prepared stick is safe: it refreshes the ISO (if changed) and `packages.txt`, writes `ventoy/ventoy.json` and the `autoinstall.env` template only if they are missing, and finishes with `install.sh --check` on the stick's `autoinstall.env`. `$V` is the stick's mount point.

`build-usb.sh` usage:

| Argument | Effect |
|---|---|
| `DISK` (or `$DISK`) | Whole USB disk to build, e.g. `/dev/sdb`. Omit to only build the ISO |
| `--rebuild`, `-r` | Rebuild the ISO even if the cached one is current |
| `--force`, `-f` | Wipe the stick and reinstall Ventoy |

It prints shell assignments on stdout for `eval`: `ISO`, `VENTOY_DIR` and, with a disk, `V`. It can also run straight from GitHub, using the files from `main`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cqkh42/llangvilla/refs/heads/main/installer/build-usb.sh)" _ /dev/sdX
```

### 3. Configure

Edit the settings on the stick and validate them:

```bash
nano "$V/arch-autoinstall/autoinstall.env"
installer/install.sh --check "$V/arch-autoinstall/autoinstall.env"
```

You must set `WIFI_SSID`, `WIFI_PSK` (or `''` for both on a cabled machine) and `PASSWORD_HASH` (from `openssl passwd -6`). The [configuration reference](#configuration-reference) lists every setting. `--check` reports every problem at once; the installer runs the same check before touching anything.

The file is sourced by bash: use single quotes, and avoid `'` in the Wi-Fi password.

### 4. Ventoy configuration

`ventoy/ventoy.json` makes Ventoy boot the ISO after 10 seconds:

```json
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/arch-autoinstall.iso" }
  ]
}
```

If the stick already has a `ventoy.json` without this entry, `build-usb.sh` warns and leaves it alone: merge the two `control` entries by hand. Remove `VTOY_DEFAULT_IMAGE` to choose the image manually each time.

### 5. Eject

```bash
sync
udisksctl unmount -b "$(findmnt -no SOURCE "$V")"
```

## Installing

1. Plug in the stick, and an Ethernet cable if available.
2. In the firmware setup (`F2` on a Dell), set boot mode to **UEFI** and turn **Secure Boot off**.
3. Open the one-time boot menu (`F12`) and choose the stick's **UEFI** entry.
4. Ventoy boots the ISO after 10 seconds. The installer prints its plan and the target disk.
5. Confirm:
   - **Blank disk:** a `CONFIRM_SECONDS` countdown runs; any key aborts.
   - **Disk with data:** the installer waits for `YES`; anything else aborts without erasing.
6. On `INSTALL COMPLETE` the machine powers off. Remove the stick.
7. Power on. The first boot runs the [first-boot hook](#first-boot-hook) (a few minutes of console output) and reboots once. The second boot reaches the login screen (Plasma Login Manager).

What a good install looks like is what `vm/test-vm.sh check` checks ([vm: Base system](../vm/README.md#base-system-check)).

If Ventoy hangs after selecting the ISO, reboot and use Ventoy's GRUB2 mode (`F1` in the Ventoy menu shows the keys).

## Configuration reference

### `autoinstall.env`

Lives only on the stick, in `arch-autoinstall/`. The template is `autoinstall.env.example`. "Template" is the value shipped in the template, and an unset variable falls back to its default. `0`/`1` settings accept only those values.

**Network**

| Variable | Template | Description |
|---|---|---|
| `WIFI_SSID` | placeholder | Wi-Fi used by the installer when there is no cable, and configured on the system. `''` for cable only |
| `WIFI_PSK` | placeholder | WPA2 passphrase, 8–63 characters (or 64 hex digits). WPA3-only networks are not supported |
| `WIFI_HIDDEN` | `0` | `1` for a hidden SSID |

**Disk**

| Variable | Template | Description |
|---|---|---|
| `TARGET_DISK` | `auto` | `auto` = largest internal non-USB disk of at least 40 GB, or a path such as `/dev/disk/by-id/nvme-…`. Pinning is safer |
| `CONFIRM_SECONDS` | `30` | Countdown before erasing a blank disk. `0` = no wait |
| `NONBLANK_DISK` | `ask` | `ask` = a disk with data needs `YES`. `wipe` = treat it like a blank disk (dangerous) |

To find the OptiPlex's disk ID: boot the stick and press Enter at the `YES` prompt to abort, then run `ls -l /dev/disk/by-id/` at the root shell.

**System**

| Variable | Template | Description |
|---|---|---|
| `HOST_NAME` | `optiplex` | Hostname |
| `TIMEZONE` | `Europe/London` | Zone under `/usr/share/zoneinfo` |
| `LOCALE` | `en_GB.UTF-8` | Must be in `/etc/locale.gen` |
| `KEYMAP` | `uk` | Console keymap |
| `X11_KEYMAP` | `gb` | Keyboard layout for the login screen and Plasma |
| `KERNELS` | `linux linux-lts` | Space-separated; the first is the default boot entry |
| `EXTRA_PACKAGES` | `''` | Added to `packages.txt` for this machine |

**User**

| Variable | Template | Description |
|---|---|---|
| `USER_NAME` | `jack` | Login name; member of `wheel` (sudo) |
| `REAL_NAME` | `Jack Cooper-McEwan` | Full name (GECOS field) |
| `PASSWORD_HASH` | placeholder | Crypt hash from `openssl passwd -6`, never a plain password |
| `LOCK_ROOT` | `1` | Lock the root account |

**SSH**

| Variable | Template | Description |
|---|---|---|
| `ENABLE_SSH` | `1` | Install and enable `sshd` |
| `SSH_KEYS_URL` | `https://github.com/cqkh42.keys` | Public keys fetched at install time |
| `SSH_AUTHORIZED_KEYS` | `''` | Extra public keys, one per line |
| `SSH_PASSWORD_AUTH` | `0` | `0` = key-only login. Ignored, with a warning, if no key could be installed |

**First boot** (see [First-boot hook](#first-boot-hook))

| Variable | Template | Description |
|---|---|---|
| `CONFIG_REPO_URL` | this repo | Repository cloned on first boot. `''` = no hook, plain base system |
| `CONFIG_REPO_BRANCH` | `''` | Branch to clone; `''` = default branch |
| `CONFIG_ENTRYPOINT` | `config/apply.sh` | Script to run, relative to the repository root |
| `FIRSTBOOT_REBOOT_AFTER` | `1` | Reboot once after a successful run |

**Installer**

| Variable | Template | Description |
|---|---|---|
| `ON_FAILURE` | `shell` | `shell` = stop at a root shell. `poweroff` = save logs and power off |

### `packages.txt`

The base package list, one or more names per line, with `#` comments. It is copied onto the stick by every `build-usb.sh` run, so changing it needs no ISO rebuild. Names are checked against the repositories before the disk is touched.

The installer always adds: `base`, `linux-firmware`, `mkinitcpio`, `sudo`, `networkmanager`, `zram-generator`, the `KERNELS`, CPU microcode, `btrfs-progs` (btrfs root), `openssh` (`ENABLE_SSH=1`), `git` (`CONFIG_REPO_URL` set) and `EXTRA_PACKAGES`. It enables `plasmalogin` (the login screen) and `bluetooth` if they are installed.

Only add packages the machine needs to boot to a usable desktop on this hardware. Apps belong in the config, which applies without a reinstall ([what goes in the config](../config/README.md#what-goes-in-the-config)).

## First-boot hook

This is the only interface between the installer and the config. When `CONFIG_REPO_URL` is set, the installer:

- adds `git`;
- writes `/usr/local/lib/llangvilla/firstboot.sh`, which clones the repository to `/opt/llangvilla` (if not already cloned, retrying for about 5 minutes while the network comes up) and runs `CONFIG_ENTRYPOINT`. If either fails, it leaves a notice on the text console (`/etc/issue.d/`) and in the login message (`/etc/motd.d/`, shown over SSH) until a later run succeeds;
- writes and enables `llangvilla-firstboot.service`, plus `NetworkManager-wait-online.service` so that `network-online.target` waits for the network.

The unit runs before the login screen (`Before=display-manager.service plasmalogin.service`), with its output on the console and no time limit: stopping a run mid-upgrade could break the system. SSH and the text consoles (`Ctrl+Alt+F2`) work meanwhile. If it fails, the login screen starts anyway, with a notice on the console and in SSH logins, and the hook runs again on the next boot.

The unit only runs while `/var/lib/llangvilla/firstboot.done` is absent, and that marker is written only on success. With `FIRSTBOOT_REBOOT_AFTER=1` the machine reboots once after success. The marker is written first, so the reboot cannot loop.

## Maintenance

| Change | Steps |
|---|---|
| Base packages | Edit `packages.txt`, run `vm/test-vm.sh`, commit, re-run `build-usb.sh /dev/sdX` |
| Apps, theming, settings | Change `config/`, not the installer ([config](../config/README.md)) |
| Wi-Fi, user, hostname, disk | Edit `autoinstall.env` on the stick, then run `install.sh --check` on it |
| Installer | Edit `install.sh`, run `vm/test-vm.sh`, commit, re-run `build-usb.sh /dev/sdX` (rebuilds the ISO) |
| Live environment | `build-usb.sh --rebuild` every few months, for newer kernel and firmware on the ISO |

## Optional extras

### Snapshots

The `@.snapshots` subvolume is mounted at `/.snapshots`; the config fills it before every upgrade ([config: Snapshots](../config/README.md#snapshots), with the rollback steps). fstab has no `subvolid=`, so a rolled-back `@` still mounts.

### Nvidia graphics

The base uses the open-source drivers (nouveau). For the proprietary driver, add `nvidia-open` and `nvidia-utils` in the config and reboot.

## Troubleshooting

Every run, including failed ones, leaves `logs/install-*.log` and `logs/last-status` in `arch-autoinstall/` on the stick. On failure the installer stops at a root shell (`ON_FAILURE=shell`). Fix the problem there and run `/root/install.sh` again.

### Building

| Symptom | Cause and fix |
|---|---|
| ISO build fails | Usually a network or mirror hiccup; the last 30 lines of output say. Re-run |
| `ventoy.json exists but does not auto-boot` | Merge the entries from [Ventoy configuration](#4-ventoy-configuration) into the existing file |
| `Could not mount automatically` | Unplug and replug the stick, then copy the files by hand (see [Write the stick](#2-write-the-stick)) |

### Booting the stick

| Symptom | Cause and fix |
|---|---|
| "Verification failed", blue Ventoy screen | Secure Boot is on. Turn it off |
| Stick missing from the boot menu | Incomplete write or an unusual port. Try another port; re-run `build-usb.sh` |
| Black screen after choosing the ISO | Use Ventoy's GRUB2 mode (`F1` for keys) |
| Installed system boots back into the stick | Remove the stick, or put the internal disk first in the boot order |

### During the install

| Message | Cause and fix |
|---|---|
| `Could not find arch-autoinstall/autoinstall.env` | Run `lsblk -f` and mount the exFAT data partition (or Ventoy's `/dev/mapper/…` device) on `/mnt/usbdata`. Check the folder is named `arch-autoinstall` |
| `autoinstall.env has problems` | Fix the listed settings |
| `Some packages … do not exist` | Typo or renamed package in `packages.txt`, `EXTRA_PACKAGES` or `KERNELS`. The pacman error names it |
| `No wireless interface found` | Missing firmware or unsupported chip. Install over Ethernet |
| `No internet over Wi-Fi` | Wrong SSID or password, or quoting. WPA3-only networks are unsupported |
| `Could not refresh the Arch keyring` | Clock or mirror problem. Check `timedatectl`, then re-run |
| `No suitable target disk found` | Disk under 40 GB, behind a USB bridge, or `TARGET_DISK` does not exist. Check `ls -l /dev/disk/by-id/` |
| Prompt to type `YES` | The disk holds data. Type `YES` only to erase it; press Enter to abort |
| `pacstrap failed twice` | Mirror problem or package conflict (see the log). Re-run |
| `sgdisk`/`wipefs`: disk busy | Leftover LVM or RAID. Run `vgchange -an; mdadm --stop --scan`, then re-run |

### After the install

| Symptom | Cause and fix |
|---|---|
| No boot entry in the firmware menu | The fallback `\EFI\BOOT\BOOTX64.EFI` is used. Run `sudo bootctl install` |
| Wi-Fi not connected | `nmcli device wifi connect SSID password PASS`. Profile: `/etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection` |
| SSH refused | Key-only by default. Check `~/.ssh/authorized_keys`; the install log shows how many keys were installed |
| First-boot hook fails | `journalctl -u llangvilla-firstboot.service -b`. Clone errors are the hook's (network, URL, branch); later errors are the [config's](../config/README.md#troubleshooting) |
| First boot is slow | Expected: the config runs before the login screen, with no time limit. Don't power off. Watch it on the console, over SSH or on `Ctrl+Alt+F2` (`journalctl -fu llangvilla-firstboot.service`) |
| `First-boot configuration FAILED` on the console or at SSH login | See `/var/log/llangvilla/` and `journalctl -u llangvilla-firstboot.service -b`. Fix, then reboot to retry; the notice goes away after a successful run |

## Security

- The repository is public. Secrets exist only on the stick:

  | Secret | Location |
  |---|---|
  | Wi-Fi SSID and passphrase | `arch-autoinstall/autoinstall.env` |
  | Password hash | `arch-autoinstall/autoinstall.env` (`PASSWORD_HASH`) |

- `.gitignore` excludes `autoinstall.env`, `*.iso` and `*.qcow2`. A password hash can be cracked offline, so never commit one.
- SSH is key-only once a key is installed. Without one, password login stays on and the log warns.
- Arch has no firewall by default; the config adds one (ufw: incoming blocked, SSH rate-limited; [config](../config/README.md)).
- The VM tests use a throwaway password and key, kept in `~/.cache/llangvilla/vm/`.

## Limitations

- No disk encryption, Secure Boot signing or dual boot.
- The first-boot hook clones over HTTPS without credentials, so the repository must be public.
- One `autoinstall.env` means one hostname. Change `HOST_NAME` per machine.
- btrfs only: the config's snapshots before upgrades rely on it.
