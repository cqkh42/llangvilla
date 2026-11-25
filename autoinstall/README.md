# Zero-touch Arch Linux USB (Ventoy + custom ISO + archinstall)

**End goal:** plug a USB stick into a new UEFI desktop, boot it, walk away. About 15-25 minutes later the machine powers itself off with Arch Linux installed: your user, your Wi-Fi, SSH, KDE Plasma, btrfs (or ext4), systemd-boot, and a first-boot `ansible-pull` of this repo. Unplug the stick, power on, log in.

Section 14 lists the gotchas specific to this setup.

---

## 0. How it works

Files in this folder:

| File | Purpose |
|---|---|
| `build-usb.sh` | Run on your PC. Builds the ISO (in Docker), downloads Ventoy, sets up the stick |
| `build.sh` | Runs inside an Arch Docker container. Builds the ISO with `archiso` and bakes in `install.sh` |
| `install.sh` | Runs on the live ISO. Partitions, runs `archinstall`, adds Wi-Fi/SSH/ansible-pull, powers off |
| `autoinstall.env.example` | Template for the stick's `autoinstall.env` (placeholders only, never commit real values) |

What ends up on the stick:

```
Ventoy USB stick
├── arch-autoinstall.iso        <- custom Arch ISO (generic, no secrets)
├── ventoy/ventoy.json          <- makes Ventoy auto-boot the ISO
└── arch-autoinstall/
    ├── user_configuration.json <- archinstall settings (KDE, locale, packages...)
    ├── user_credentials.json   <- your user + hashed password
    └── autoinstall.env         <- Wi-Fi details, target disk, safety countdown
```

Boot sequence on the target machine:

1. Ventoy menu -> auto-boots `arch-autoinstall.iso`.
2. The Arch live environment logs in as root and automatically runs `/root/install.sh`.
3. `install.sh` finds the stick's config folder, gets online (cable or Wi-Fi), picks the target disk, shows a countdown (any key aborts), partitions and formats it (GPT, EFI + btrfs subvolumes), then runs `archinstall --silent` using your JSON.
4. The Wi-Fi profile is written into the installed system, SSH is enabled, your full name is set, the first-boot `ansible-pull` service is installed, logs are copied back to the stick, and the machine powers off.

> **WARNING:** this stick erases a disk on the target machine with no prompt beyond the countdown. Treat it like a loaded tool. Never leave it in a machine you care about, and keep the stick physically safe (it holds your Wi-Fi password and a hashed login password).

### Assumptions (change them if wrong)

| Item | Assumed |
|---|---|
| Build computer | Linux (Arch, or any distro with Docker) with internet |
| Target machine | UEFI desktop, at least 40 GB disk, Secure Boot can be turned off |
| Target disk | The largest internal (non-USB) disk is erased and used |
| Filesystem / bootloader | btrfs with subvolumes by default, or ext4 (`ROOT_FS=ext4`); systemd-boot |
| Desktop | KDE Plasma (Wayland) with SDDM, themed by `ansible/roles/sddm` |
| Region | UK: timezone `Europe/London`, locale `en_GB.UTF-8`, keyboard `uk` |
| Identity | User `jack`, real name `Jack Cooper-McEwan`, hostname `optiplex` |
| SSH | `sshd` enabled, password login allowed |
| First boot | `ansible-pull` from `https://github.com/cqkh42/llangvilla.git`, playbook `ansible/site.yml` |
| Graphics | Open-source drivers (AMD/Intel just work; Nvidia boots with nouveau, install proprietary drivers later) |
| Not covered | Disk encryption, Secure Boot signing, dual boot |

---

## 1. What you need

- [ ] A USB stick, **16 GB or bigger** (a USB 3 stick is much nicer). Installing Ventoy erases it.
- [ ] A Linux computer with internet and about 10 GB free disk space.
- [ ] The target desktop (UEFI) with internet via cable or Wi-Fi.
- [ ] Your Wi-Fi name (SSID) and password (WPA2 or WPA2/WPA3 mixed).
- [ ] About an hour for the first run, mostly waiting for downloads.

Decide these now (you will enter them later):

| Decision | Example |
|---|---|
| Hostname | `optiplex` |
| Username / real name | `jack` / `Jack Cooper-McEwan` |
| Password | Set it in the archinstall menu, or paste a SHA-512 hash from `openssl passwd -6` |
| Timezone | `Europe/London` |
| Locale / keyboard | `en_GB.UTF-8` / `uk` |
| Ansible repo / playbook | `https://github.com/cqkh42/llangvilla.git` / `ansible/site.yml` |

---

## 2. Prepare the build computer

Install Docker, QEMU and UEFI firmware for the VM tests, then start Docker.

On Arch:

```bash
sudo pacman -S --needed docker qemu-desktop edk2-ovmf jq curl rsync openssh udisks2 git
sudo systemctl enable --now docker
OVMF=/usr/share/edk2/x64/OVMF.4m.fd
```

On Debian/Ubuntu:

```bash
sudo apt install -y docker.io qemu-system-x86 qemu-utils ovmf jq curl rsync openssh-client udisks2 git
sudo systemctl enable --now docker
OVMF=/usr/share/ovmf/OVMF.fd
```

Check the firmware file exists (`ls "$OVMF"`). If it doesn't, look in `/usr/share/edk2/` or `/usr/share/OVMF/` for an `OVMF*.fd` file and set `OVMF` to that. The VM commands below use `$OVMF`.

Sanity-check Docker:

```bash
sudo docker run --rm hello-world
```

You should see "Hello from Docker!".

Why Docker even on Arch? It gives a clean, current Arch with `archiso` for every build, without installing build tooling on your machine.

---

## 3. Get the scripts

```bash
git clone https://github.com/cqkh42/llangvilla.git
cd llangvilla
```

`build-usb.sh` uses the `build.sh` and `install.sh` next to it, so local edits are baked into the next ISO. (It can also run straight from GitHub, `bash -c "$(curl -fsSL https://raw.githubusercontent.com/cqkh42/llangvilla/refs/heads/main/autoinstall/build-usb.sh)"`, in which case it downloads them from `main`.)

Everything it downloads or builds is cached in `~/.cache/llangvilla/`.

---

## 4. Build the ISO

```bash
eval "$(autoinstall/build-usb.sh)"
```

With no disk given, this only builds the ISO and downloads Ventoy:

- The ISO is built in an `archlinux:latest` container with `--privileged` (`mkarchiso` needs mounts and chroots). It takes roughly 5-15 minutes and prints a lot.
- The result lands in `~/.cache/llangvilla/iso-build/out/arch-autoinstall-YYYY.MM.DD-x86_64.iso` (about 1.2-1.5 GB) and the `eval` sets `$ISO` to it.
- Re-runs reuse the cached ISO unless `build.sh` or `install.sh` changed. `--rebuild` forces a fresh one.
- Ventoy is downloaded and checked against a pinned SHA-256.

**If the build fails:** read the last 30 lines of output. Most failures are network hiccups (just re-run).

---

## 5. Generate your archinstall config in a VM

You need `user_configuration.json` and `user_credentials.json`. **Do not hand-write them.** Their format changes between archinstall versions, so generate them with the same archinstall that is inside your ISO. A VM makes that painless and safe.

### 5a. Boot the ISO in a VM

```bash
mkdir -p ~/.cache/llangvilla/generated
qemu-img create -f qcow2 /tmp/test-disk.qcow2 40G
qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 4 -m 6G \
  -bios "$OVMF" \
  -drive file=/tmp/test-disk.qcow2,if=virtio \
  -cdrom "$ISO" -boot d \
  -nic user,hostfwd=tcp::2222-:22
```

- A window opens. Pick the first menu entry (**Arch Linux install medium (x86_64, UEFI)**) or wait 15 seconds.
- If you get a KVM permission error, remove `-enable-kvm -cpu host` (it will be slow but works).
- The installer script will run, hunt for a USB stick for about 30 seconds, then print an error and leave you at a root shell. **That is expected here**, since there is no stick yet.

### 5b. Run archinstall interactively

At the VM's prompt:

```bash
archinstall
```

Menu names vary slightly by version. Set these (use the arrow keys, Enter to select):

| Menu | Choose |
|---|---|
| Mirrors and repositories | Region: **United Kingdom** (optionally enable `multilib` if you game) |
| Locales | Keyboard layout `uk`, language `en_GB.UTF-8`, encoding `UTF-8` |
| Disk configuration | Pick "best-effort default layout", btrfs, default subvolumes. **This is ignored by the script (it partitions for itself), but the menu insists on something.** |
| Disk encryption | None |
| Swap | Enabled (zram) |
| Bootloader | **systemd-boot** |
| Hostname | `optiplex` (or whatever you want; `HOSTNAME_OVERRIDE` can change it per run) |
| Authentication: root password | Skip it (use sudo) or set one |
| Authentication: user account | Add user -> username `jack`, password, **superuser (sudo): yes**. (archinstall has no real-name field; the script sets it, see `REAL_NAME`.) |
| Profile | Type **Desktop** -> **KDE Plasma**. Greeter should be **sddm** |
| Graphics driver | **All open-source** |
| Audio | **pipewire** |
| Kernels | `linux` and `linux-lts` (lts is your fallback if an update breaks the main kernel) |
| Network configuration | **Use NetworkManager** (KDE's Wi-Fi UI and the script's Wi-Fi profile both need it) |
| Additional packages | `git ansible openssh firefox nano vim htop btop base-devel reflector man-db bluez bluez-utils snapper snap-pac gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg` (edit to taste) |
| Timezone | `Europe/London` |
| Automatic time sync (NTP) | Yes |

> **Do not** put your real Wi-Fi password anywhere in archinstall. The script handles Wi-Fi separately.

### 5c. Save the configuration

1. Choose **Save configuration** in the menu.
2. Save **all** (configuration and credentials). When asked for a folder, enter `/root`.
3. If it asks about encrypting the credentials file, answer **No**. (Zero-touch needs it readable. The passwords inside are hashed, not plain text.)
4. Check the files exist: `ls -l /root/user_*.json`. You need **both** `user_configuration.json` and `user_credentials.json`.
5. You can now select **Abort** instead of installing. (Or choose **Install** if you want to test the whole config in the VM now. It downloads a few GB.)

### 5d. Copy the files out of the VM

In the VM, set a throwaway root password so SSH works:

```bash
passwd
```

On your computer (a second terminal):

```bash
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  'root@localhost:/root/user_*.json' ~/.cache/llangvilla/generated/
ls -l ~/.cache/llangvilla/generated/
```

`build-usb.sh` copies them onto the stick from there. (Keep them somewhere else and set `CONFIG_DIR=/path/to/folder` when running it.)

Shut the VM down (`poweroff` inside it). Then delete the VM disk, you will want a clean one later:

```bash
rm /tmp/test-disk.qcow2
```

### 5e. Inspect the config

```bash
cd ~/.cache/llangvilla/generated
jq '{hostname, timezone, kernels, bootloader, network_config, profile_config, packages, swap, custom_commands}' user_configuration.json
```

Check that:

- `network_config` shows NetworkManager (`"type": "nm"`).
- `profile_config` mentions KDE Plasma and sddm.
- `packages` contains what you typed.
- `hostname` and `timezone` are right.
- `custom_commands` is empty or absent. (The script adds the Wi-Fi, SSH, real-name and ansible-pull commands at install time.)
- You can ignore `disk_config`. The script replaces it.

Your password is in `user_credentials.json` as a hash (a long string starting `$y$` or `$6$`). That's normal.

**To use a hash you already have:** open `user_credentials.json`, find the user's password field (the key is named something like `enc_password`; the exact name depends on the version) and paste your hash (e.g. from `openssl passwd -6`) over its value. Keep the JSON valid (quotes and commas), then check with `jq . user_credentials.json`.

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
4. copies the files from section 0 onto it, as described in section 7.

Safe to re-run: the ISO is only re-copied if it changed, `ventoy.json` and `autoinstall.env` are never overwritten, and the two JSON files are refreshed from `~/.cache/llangvilla/generated`.

---

## 7. What goes on the stick

### 7a. The ISO and config

The ISO is copied to `$V/arch-autoinstall.iso` (a fixed name, so `ventoy.json` never needs editing when you rebuild), and the JSON files to `$V/arch-autoinstall/`.

### 7b. Fill in `autoinstall.env`

The script copies `autoinstall.env.example` to the stick the first time. Fill in the placeholders **on the stick**:

```bash
nano "$V/arch-autoinstall/autoinstall.env"
grep -n '__' "$V/arch-autoinstall/autoinstall.env"     # must print nothing
```

| Setting | Meaning |
|---|---|
| `WIFI_SSID`, `WIFI_PSK`, `WIFI_HIDDEN` | Wi-Fi used by the live installer if there is no cable, and configured on the installed system. Empty both for cable only |
| `TARGET_DISK` | `auto` = largest internal (non-USB) disk, or pin one with `/dev/disk/by-id/...` |
| `CONFIRM_SECONDS` | Countdown before erasing (any key aborts). 0 = no wait |
| `ROOT_FS` | `btrfs` (subvolumes, snapshots) or `ext4` |
| `ENABLE_SSH` | 1 = enable `sshd` (password login works by default) |
| `USER_NAME`, `REAL_NAME` | Login name (must match `user_credentials.json`) and full name |
| `LOCK_ROOT` | 1 = lock the root account (use your user + sudo) |
| `HOSTNAME_OVERRIDE` | Empty = hostname from the JSON; set to override per run |
| `ANSIBLE_BEFORE_LOGIN` | 1 = run ansible-pull before the login screen; 0 = in the background (section 11b) |
| `ANSIBLE_REBOOT_AFTER` | 1 = reboot once after a successful ansible-pull |
| `ANSIBLE_PULL_URL`, `ANSIBLE_PLAYBOOK` | First-boot ansible-pull. Empty URL = skip |

Notes: the file is sourced by bash, so use single quotes. A Wi-Fi password containing a single quote `'` needs escaping (avoid it or change the password). WPA3-only (SAE) networks need `key-mgmt=sae` in the script; WPA2 and WPA2/WPA3 mixed work as written.

### 7c. `ventoy/ventoy.json`

Written only if the stick doesn't have one:

```json
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/arch-autoinstall.iso" }
  ]
}
```

Ventoy boots the Arch ISO automatically after 10 seconds unless someone presses a key to pick another entry. If the stick already has a `ventoy.json` that doesn't mention `/arch-autoinstall.iso`, the script warns you: **merge** the two `control` entries into it by hand. If you'd rather choose manually every time, leave out `VTOY_DEFAULT_IMAGE`.

### 7d. Flush and eject

```bash
sync
udisksctl unmount -b "$(findmnt -no SOURCE "$V")"
```

Then unplug the stick.

---

## 8. Test the real stick in a VM first

Do this before trusting the stick with real hardware.

1. Make sure the stick is **not mounted** (see 7d). Find its device name (`lsblk -d -o NAME,SIZE,MODEL,TRAN`).
2. Create a fresh virtual target disk:

   ```bash
   qemu-img create -f qcow2 /tmp/test-disk.qcow2 60G
   ```

3. Boot the stick in QEMU (`sudo` is needed to read the raw USB device):

   ```bash
   sudo qemu-system-x86_64 \
     -enable-kvm -cpu host -smp 4 -m 6G \
     -bios "$OVMF" \
     -drive file=/dev/sdX,format=raw,if=virtio \
     -drive file=/tmp/test-disk.qcow2,if=virtio \
     -nic user
   ```

4. In the VM, the Ventoy menu appears. Wait for the 10-second timer (or select the Arch ISO). The installer should:
   - find the config, report "Online" (the VM uses a virtual cable, so Wi-Fi isn't exercised),
   - choose the 60 GB virtual disk, show the countdown,
   - run `archinstall`, then power off.
5. Boot the installed system (no stick this time):

   ```bash
   qemu-system-x86_64 \
     -enable-kvm -cpu host -smp 4 -m 6G \
     -bios "$OVMF" \
     -drive file=/tmp/test-disk.qcow2,if=virtio \
     -nic user
   ```

6. You should reach the SDDM login screen. Log in as your user. Check the Wi-Fi profile was written:

   ```bash
   sudo ls /etc/NetworkManager/system-connections/
   ```

   You should see `autoinstall-wifi.nmconnection`.

If anything failed, read the log the installer saved on the stick: `arch-autoinstall/logs/install-*.log`.

---

## 9. Run it on the real machine

1. Plug the stick into the target desktop. Plug in an Ethernet cable if you can (more reliable than Wi-Fi for the first run, optional).
2. Enter the firmware setup (usually `Del`, `F2`, `F10`, `F12` or `Esc` at power-on) and make sure:
   - **Secure Boot is OFF.** The Arch ISO and systemd-boot are unsigned. With it on, Ventoy shows a "verification failed" screen.
   - Boot mode is **UEFI** (turn off CSM / legacy if you see it).
3. Open the one-time boot menu (often `F12`) and choose the **USB stick, UEFI entry**.
4. The Ventoy menu appears and auto-boots the ISO after 10 seconds.
5. Watch the first minute: you should see `[autoinstall] TARGET DISK: ...` and the countdown. **Check that disk is the one you want erased.** Press any key to abort.
6. Walk away. When it says `INSTALL COMPLETE`, the machine powers off.
7. **Remove the stick** and power on. If you configured `ansible-pull`, the first boot runs the playbook (console text for a few minutes) and then reboots by itself once. The second boot lands on the SDDM login.

If Ventoy hangs at boot: restart, select the Arch ISO manually and use Ventoy's **GRUB2 mode** (press `F1` in the Ventoy menu for the key combo).

---

## 10. Verify the installed system

Log in and open a terminal (Konsole):

```bash
nmcli device status                 # Wi-Fi shows "connected"
ping -c3 archlinux.org
lsblk -f                            # EFI (vfat) + btrfs
sudo btrfs subvolume list /         # @, @home, @log, @pkg, @.snapshots
bootctl status                      # systemd-boot installed
sudo pacman -Syu                    # fully up to date, no errors
systemctl --failed                  # ideally empty
hostnamectl                         # hostname 'optiplex'
getent passwd jack                  # full name in the 5th field
systemctl status sshd               # active (running) if ENABLE_SSH=1
systemctl status ansible-pull-firstboot.service
journalctl -u ansible-pull-firstboot.service -b   # the playbook's output
```

Confirm microcode is installed (archinstall does this automatically): `pacman -Q intel-ucode amd-ucode` (one of them should exist).

---

## 11. Optional extras

### 11a. Snapshots with snapper (undo button for a rolling release)

`snapper` and `snap-pac` should already be installed from your package list. The standard Arch-wiki sequence for an `@.snapshots` layout:

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

`snap-pac` then snapshots before and after every `pacman` transaction. Caveat: `/boot` (the EFI partition) is not in snapshots, so after rolling back root, kernels in `/boot` can be newer than the restored modules. Use `linux-lts` as your fallback and reinstall kernels after a rollback.

### 11b. First-boot `ansible-pull` (built in)

This is done by `install.sh`, so you don't hand-edit JSON. Set `ANSIBLE_PULL_URL` and `ANSIBLE_PLAYBOOK` in `autoinstall.env` (section 7b). The script will:

- add `git` and `ansible` to the package list,
- write `/etc/systemd/system/ansible-pull-firstboot.service`,
- enable it together with `NetworkManager-wait-online.service`, so `network-online.target` genuinely waits for the network.

**When it runs** is controlled by `ANSIBLE_BEFORE_LOGIN`:

- `1` (default): the unit is ordered `Before=display-manager.service`, so SDDM does not start until the playbook has finished. The first boot shows console text for a few minutes, then the login screen appears already customised (SDDM themes and config included). If the playbook fails, SDDM still starts, no "done" marker is written, and the next boot tries again.
- `0`: it runs in the background while the login screen is already showing, and retries every 60 seconds until it succeeds.

**Reboot after success:** with `ANSIBLE_REBOOT_AFTER=1` (default) the machine reboots once when the playbook finishes successfully. The done marker is written *before* the reboot, so it can't loop, and a failed run never reboots. The sequence is: install, power off, you power on, first boot runs the playbook, automatic reboot, second boot straight to the finished login screen. Set `ANSIBLE_REBOOT_AFTER=0` to skip the reboot. Using the reboot together with `ANSIBLE_BEFORE_LOGIN=0` isn't recommended, since the machine could reboot while someone is already logged in.

Leave `ANSIBLE_PULL_URL` empty to skip it. Read section 14 before relying on it, in particular the rules for a playbook that runs before login.

### 11c. Nvidia graphics

The stick installs open-source drivers (nouveau), which gives a working desktop. After install: `sudo pacman -S nvidia-open nvidia-utils` (for recent cards) and reboot. Put this in your Ansible instead if you manage Nvidia machines.

---

## 12. Maintenance

- **Rebuild the ISO about monthly**, or whenever something breaks: `autoinstall/build-usb.sh --rebuild /dev/sdX` builds a fresh ISO and copies it over `arch-autoinstall.iso`. The Arch ISO is a snapshot of the repos, and an old one carries an old `archinstall`. Changing `install.sh` or `build.sh` triggers a rebuild automatically.
- **If archinstall complains about the JSON after a rebuild**, the schema changed. Redo section 5 with the new ISO and replace the two JSON files on the stick.
- **Changing user, packages, desktop, etc.:** edit the JSON on the stick (or regenerate it). No rebuild needed.
- **Changing Wi-Fi:** edit `autoinstall.env`. No rebuild needed.

---

## 13. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| "Verification failed" / blue Ventoy screen | Secure Boot is on. Turn it off in firmware. |
| Stick doesn't appear in the boot menu | Write was incomplete or the port is odd. Try another port, run `sync` after copying, re-run Ventoy install. |
| Black screen / hang after choosing the ISO | Reboot, select the ISO, choose **GRUB2 mode** (`F1` for key hints). |
| `Could not find ... user_configuration.json` (and `mount` says "can't open blockdev") | Ventoy holds its data partition open, so mount the device-mapper copy instead (`ls /dev/mapper`, e.g. `/dev/mapper/VentoyPart`). Current `install.sh` scans these automatically, so rebuild the ISO if yours is older. |
| `Could not find ... user_configuration.json` (other causes) | At the root shell, run `lsblk -f`. The data partition should be exFAT. Mount it by hand (`mount /dev/sdX1 /mnt/usbdata`) and confirm the folder is named exactly `arch-autoinstall`. |
| `No wireless interface found` | Missing Wi-Fi firmware or an unusual chip. Use an Ethernet cable for the install; Wi-Fi will still work on the installed system if the driver exists. |
| `No internet over Wi-Fi` | SSID or password typo in `autoinstall.env`; check quoting. WPA3-only networks aren't supported by the profile as written. |
| `No suitable target disk found` | The internal disk is under 40 GB, or is on a USB bridge. Set `TARGET_DISK=/dev/disk/by-id/...` explicitly (find it with `ls -l /dev/disk/by-id/`). |
| It picked the wrong disk | Press a key during the countdown, then pin `TARGET_DISK` in `autoinstall.env`. |
| `archinstall` fails with a JSON/schema error | The config doesn't match the ISO's archinstall version. Redo section 5 using the current ISO. |
| `sgdisk`/`mkfs` says the disk is busy | Leftover RAID/LVM on the old disk got auto-activated. At the shell: `vgchange -an; mdadm --stop --scan`, then re-run `/root/install.sh`. |
| Installed OS boots straight back to the stick | Remove the stick, or set the internal disk first in firmware boot order. |
| Installed system has no entry in the boot menu | Firmware lost the entry; boot from `\EFI\BOOT\BOOTX64.EFI` on the internal disk (usually listed as the disk itself) and run `sudo bootctl install`. |
| Wi-Fi not connected after install | `nmcli device wifi connect 'SSID' password 'PASS'`, and check `sudo ls -l /etc/NetworkManager/system-connections/` (file must be mode 600, owned by root). |
| First-boot ansible keeps failing | `journalctl -u ansible-pull-firstboot.service -b`. Usually a task that needs a running desktop session, or no network yet. See section 14. With `ANSIBLE_BEFORE_LOGIN=1` it runs once per boot (SDDM starts anyway); with `0` it retries every 60 s until it succeeds, so stop it with `sudo systemctl stop ansible-pull-firstboot.service` while you fix the playbook. |
| Can't SSH in | `systemctl status sshd`; confirm `ENABLE_SSH=1` and that `openssh` is installed. Arch has no firewall by default, so it's not blocked. Host keys are generated on first start. |
| Every machine has the same hostname | Expected: one JSON, one hostname. Use `HOSTNAME_OVERRIDE` per run or rename in Ansible. |
| `user_credentials.json is missing` | The script refuses to run without it (before wiping anything). Generate it as described in section 5c. |

Saved logs from every run (including failures) are in `arch-autoinstall/logs/` on the stick.

---

### Using `jack` instead of root

The setup already does this: `jack` is the normal login and administrator (member of `wheel`, can use `sudo`), and with `LOCK_ROOT=1` (the default) the root account is locked so nobody can log in as root. In the archinstall menu, skip the root password. To get a root shell, run `sudo -i`.

Don't rename root to `jack` or give `jack` UID 0. It breaks packages and services that expect `root`, and it gives up the safety of a normal user. Using `sudo` gives you the same power.

## 14. Gotchas specific to this setup

**1. Playbook rules for Arch.** `ansible/site.yml` targets Arch. When adding to it:

- Use `community.general.pacman` for packages. Arch names differ from other distros (`openssh`, `python-*`, `base-devel`).
- AUR packages are not available via `pacman`. You need an AUR helper (`paru` or `yay`) built and run **as a normal user**, never root.
- `ansible-pull` runs as **root** from systemd. Use `become_user: jack` for user-level tasks.
- The Arch `ansible` package includes the common collections. If you ever switch to `ansible-core` you must install `community.general` yourself.
- Test the playbook on the VM from section 8 before the real machine.

**2. Failure behaviour depends on `ANSIBLE_BEFORE_LOGIN`.** With `1`, a failing playbook is attempted once per boot (SDDM then starts anyway, so you can always log in and read `journalctl -u ansible-pull-firstboot.service -b`). With `0`, the unit retries every 60 seconds until it passes, which can hammer the machine and network. The "done" marker is only written on success.

**3. With `ANSIBLE_BEFORE_LOGIN=1` the first boot is slow.** Expect text on the console, possibly for several minutes (up to 30, then systemd gives up and SDDM starts regardless). Don't power off during it. With `0`, the playbook may be mid-way through installing packages while SDDM is already showing; some changes (kernel modules, display manager, groups) then need a reboot.

**4. The repo must be public.** The unit clones over HTTPS with no credentials. A private repo needs a deploy key or token, which means putting a secret on the machine.

**5. KDE Plasma is fairly minimal out of the box.** The archinstall KDE profile pulls in a modest set (Plasma, Konsole, Kate, Dolphin, SDDM). Add anything else (`kde-applications-meta`, Discover, Firefox integration) via packages or Ansible. Desktop settings belong in KDE config files (`kwriteconfig6`, files in `~/.config`), written by Ansible.

**6. KDE Plasma on Wayland + Nvidia.** The stick installs open-source drivers (nouveau), which is fine for Intel/AMD graphics. For Nvidia, install `nvidia-open nvidia-utils` and reboot; Plasma's Wayland session works with them but occasionally needs the X11 session as a fallback (pick it on the SDDM login screen). Do the driver install from Ansible so it's repeatable.

**7. SSH with password login is on, and Arch has no firewall.** Once `sshd` is enabled, the machine accepts password logins from the whole LAN as soon as it boots. Add your key and set `PasswordAuthentication no` later, or have Ansible do it.

**8. Password hash format.** `$6$` (SHA-512) from `openssl passwd -6` works. Don't paste a hash into the wrong field. The generated JSON shows which key holds it, and `jq . user_credentials.json` validates the syntax.

**9. Same hostname on every machine.** One JSON means one hostname (`optiplex`). Two machines installed from the same stick will clash on the network. Use `HOSTNAME_OVERRIDE` or rename in Ansible.

**10. ext4 vs btrfs.** If the playbook or backup tooling assumes ext4, set `ROOT_FS=ext4`. With ext4, section 11a (snapper) doesn't apply.

**11. Real name is applied late.** It's set at the end of install via `usermod -c`. If `USER_NAME` doesn't match the archinstall user exactly, the command fails (the install still completes) and the full name stays empty. Check with `getent passwd jack`.

**12. First-boot network timing.** The unit waits for `network-online.target`. The script also enables `NetworkManager-wait-online.service`. Without it the playbook can start before Wi-Fi is up and fail its first attempt (it then retries).

**13. Secure Boot and Ventoy.** It must be off: the Arch ISO and systemd-boot are unsigned.

**14. Things a before-login playbook must not do.** The run happens before any user session exists:

- **Don't restart or start `sddm` / `display-manager` from the playbook** (for example in a handler after changing its config). SDDM is waiting for the playbook to finish, so the restart waits for the playbook and the playbook waits for the restart: a deadlock until the 30-minute timeout. Just write the config; SDDM reads it when it starts afterwards. If you must trigger something, use `systemctl restart --no-block`.
- **No tasks that need a logged-in desktop session** (user dconf, user systemd units, `loginctl`, `kwriteconfig6` against a running session). Writing config files into `/etc` or `/home/jack/.config` is fine; changing live session state isn't.
- **Don't reboot from the playbook.** The unit reboots once by itself after a successful run (`ANSIBLE_REBOOT_AFTER=1`), so kernel, driver and display-manager changes take effect then. A reboot from inside the playbook would end the run before the done marker is written, and the playbook would run again.
- **SDDM config goes in `/etc/sddm.conf.d/*.conf`** (themes, default session, autologin). Put a drop-in file there rather than editing `/etc/sddm.conf`.
- **Alternative to running at boot:** you can run the same `ansible-pull` inside the install itself (a `custom_commands` entry). It finishes before the machine ever boots, but the install environment has no running systemd, so service start/restart tasks fail there. Only choose it if the playbook is purely files and packages.

## 15. Keeping secrets out of the repo

The repo is public. Only templates and scripts live in git; the real values exist **only on the stick** (and in `~/.cache/llangvilla/generated` on your build computer):

| Secret | Lives in |
|---|---|
| Wi-Fi SSID and password | `arch-autoinstall/autoinstall.env` on the stick (from `autoinstall/autoinstall.env.example`) |
| Password hash | `arch-autoinstall/user_credentials.json` on the stick |

`.gitignore` blocks `autoinstall.env`, `user_credentials.json`, `user_configuration.json`, `*.iso` and `*.qcow2` in case one is ever copied into the checkout. A password hash in a public repo can be cracked offline, so keep `user_credentials.json` out of git even though it's "only" a hash.

---

## Appendix: what each file does

| File | Where it lives | Purpose |
|---|---|---|
| `build-usb.sh` | Your PC (repo `autoinstall/`) | Builds the ISO via Docker, downloads Ventoy, installs and populates the stick |
| `build.sh` | Docker container | Builds the ISO with `archiso` and bakes in `install.sh` plus the auto-run hook |
| `install.sh` | Inside the ISO (`/root/install.sh`) | Finds config, gets online, picks the disk, partitions, adds Wi-Fi/SSH/real-name/ansible-pull commands, runs archinstall, powers off |
| `arch-autoinstall.iso` | Stick root | The generic installer image. Rebuild monthly, no secrets inside |
| `ventoy/ventoy.json` | Stick | Auto-boots the ISO after 10 s |
| `user_configuration.json` | Stick `arch-autoinstall/` | archinstall settings (profile, packages, locale...). Its `disk_config` is replaced at runtime |
| `user_credentials.json` | Stick `arch-autoinstall/` | Username and hashed password |
| `autoinstall.env` | Stick `arch-autoinstall/` | Wi-Fi, target disk, root filesystem, SSH, user real name, hostname override, ansible-pull repo, countdown |
| `logs/` | Stick `arch-autoinstall/` | Install logs copied back after each run |
