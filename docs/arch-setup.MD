# Zero-touch Arch Linux USB (Ventoy + custom ISO + archinstall)

**End goal:** plug a USB stick into a new UEFI desktop, boot it, walk away. About 15-25 minutes later the machine powers itself off with Arch Linux installed: your user, your Wi-Fi, SSH, KDE Plasma, btrfs (or ext4), systemd-boot, and a first-boot `ansible-pull` of your repo. Unplug the stick, power on, log in.

This is the Arch equivalent of your Ubuntu `autoinstall` + `user-data` stick. Section 14 maps every `user-data` key to its Arch equivalent, and section 15 lists the gotchas specific to your setup.

---

## 0. How it works

```
Ventoy USB stick
├── arch-autoinstall.iso        <- custom Arch ISO (built by you, generic, no secrets)
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
| Build computer | Ubuntu (desktop or server) with internet |
| Target machine | UEFI desktop, at least 40 GB disk, Secure Boot can be turned off |
| Target disk | The largest internal (non-USB) disk is erased and used |
| Filesystem / bootloader | btrfs with subvolumes by default, or ext4 (`ROOT_FS=ext4`, closest to Ubuntu `layout: direct`); systemd-boot |
| Desktop | KDE Plasma (Wayland) with SDDM (your Ubuntu setup is GNOME, so this is a deliberate change) |
| Region | UK: timezone `Europe/London`, locale `en_GB.UTF-8`, keyboard `uk` (Ubuntu's `gb`) |
| Identity | User `jack`, real name `Jack Cooper-McEwan`, hostname `optiplex` |
| SSH | `sshd` enabled, password login allowed (as in your `user-data`) |
| First boot | `ansible-pull` from `https://github.com/cqkh42/llangvilla.git`, playbook `ansible/site.yml` |
| Graphics | Open-source drivers (AMD/Intel just work; Nvidia boots with nouveau, install proprietary drivers later) |
| Not covered | Disk encryption, Secure Boot signing, dual boot, Ubuntu Pro (no Arch equivalent) |

---

## 1. What you need

- [ ] A USB stick, **16 GB or bigger** (a USB 3 stick is much nicer). Installing Ventoy erases it.
- [ ] An Ubuntu computer with internet and about 10 GB free disk space.
- [ ] The target desktop (UEFI) with internet via cable or Wi-Fi.
- [ ] Your Wi-Fi name (SSID) and password (WPA2 or WPA2/WPA3 mixed).
- [ ] About an hour for the first run, mostly waiting for downloads.

Decide these now (you will enter them later):

| Decision | Example |
|---|---|
| Hostname | `optiplex` |
| Username / real name | `jack` / `Jack Cooper-McEwan` |
| Password | Reuse the SHA-512 hash from your `user-data` (`openssl passwd -6`), or set one in the archinstall menu |
| Timezone | `Europe/London` |
| Locale / keyboard | `en_GB.UTF-8` / `uk` |
| Ansible repo / playbook | `https://github.com/cqkh42/llangvilla.git` / `ansible/site.yml` |

---

## 2. Prepare the build computer (Ubuntu)

Open a terminal.

```bash
sudo apt update
sudo apt install -y docker.io qemu-system-x86 qemu-utils ovmf jq curl openssh-client
sudo systemctl enable --now docker
```

Sanity-check Docker:

```bash
sudo docker run --rm hello-world
```

You should see "Hello from Docker!". Then check the UEFI firmware file QEMU will use later:

```bash
ls /usr/share/ovmf/OVMF.fd
```

If that file doesn't exist, run `ls /usr/share/OVMF/` and use the `OVMF.fd` or `OVMF_CODE*.fd` file you find there wherever this guide says `/usr/share/ovmf/OVMF.fd`.

Why Docker? The tool that builds Arch ISOs (`archiso`) only runs on Arch. An Arch container gives you that without installing Arch.

---

## 3. Create the working folder and the two scripts

```bash
mkdir -p ~/arch-autoinstall/out ~/arch-autoinstall/generated
cd ~/arch-autoinstall
curl -fsSL https://raw.githubusercontent.com/cqkh42/llangvilla/main/autoinstall/arch/install.sh -o install.sh
curl -fsSL https://raw.githubusercontent.com/cqkh42/llangvilla/main/autoinstall/arch/build.sh -o build.sh
chmod +x ~/arch-autoinstall/install.sh ~/arch-autoinstall/build.sh
```

---

## 4. Build the ISO

```bash
cd ~/arch-autoinstall
sudo docker run --rm --privileged --pull=always \
  -v "$PWD":/work archlinux:latest bash /work/build.sh
```

- Takes roughly 5-15 minutes. Lots of scrolling text is normal.
- `--privileged` is required: `mkarchiso` needs mounts and chroots.
- Success ends with `BUILD OK`.

Fix file ownership (the container wrote the ISO as root) and check:

```bash
sudo chown -R "$USER":"$USER" ~/arch-autoinstall
ls -lh ~/arch-autoinstall/out
```

You should see `arch-autoinstall-YYYY.MM.DD-x86_64.iso` (about 1.2-1.5 GB).

**If the build fails:** read the last 30 lines of output. Most failures are network hiccups (just re-run) or a typo in `build.sh`.

---

## 5. Generate your archinstall config in a VM

You need `user_configuration.json` and `user_credentials.json`. **Do not hand-write them.** Their format changes between archinstall versions, so generate them with the same archinstall that is inside your ISO. A VM makes that painless and safe.

### 5a. Boot the ISO in a VM

```bash
cd ~/arch-autoinstall
qemu-img create -f qcow2 test-disk.qcow2 40G
qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 4 -m 6G \
  -bios /usr/share/ovmf/OVMF.fd \
  -drive file=test-disk.qcow2,if=virtio \
  -cdrom out/arch-autoinstall-*.iso -boot d \
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
| Additional packages | `git ansible openssh firefox nano vim htop btop base-devel reflector man-db bluez bluez-utils snapper snap-pac gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg` (the `gst-*`/`ffmpeg` ones replace Ubuntu's `codecs: install: true`; edit to taste) |
| Timezone | `Europe/London` |
| Automatic time sync (NTP) | Yes |

> **Do not** put your real Wi-Fi password anywhere in archinstall. The script handles Wi-Fi separately.

### 5c. Save the configuration

1. Choose **Save configuration** in the menu.
2. Save **all** (configuration and credentials). When asked for a folder, enter `/root`.
3. If it asks about encrypting the credentials file, answer **No**. (Zero-touch needs it readable. The passwords inside are hashed, not plain text.)
4. Check the files exist: `ls -l /root/user_*.json`. You need **both** `user_configuration.json` and `user_credentials.json`.
5. You can now select **Abort** instead of installing. (Or choose **Install** if you want to test the whole config in the VM now. It downloads a few GB.)

#### If `user_credentials.json` was not written

The credentials file only contains a user and/or root password, and archinstall only writes it when it has something to put in it and you ask for it. Work through these in order:

1. **Make sure a user (or root password) is actually set.** In the menu, **Authentication** must show your user (with sudo) and/or a root password. An empty section means no credentials file.
2. **Save again, picking the credentials file explicitly.** In **Save configuration**, choose the option for `user_credentials.json` (or "all"), not just `user_configuration.json`, and use `/root` as the folder. If it asks about encrypting it, answer **No**.
3. **Let the installer write it for you.** In most versions, pressing **Install** makes archinstall write both files to `/var/log/archinstall/` before it starts installing. Press **Install**, wait until you see packages being downloaded, then press `Ctrl+C`. Then:

   ```bash
   ls -l /var/log/archinstall/
   cp /var/log/archinstall/user_*.json /root/
   ```

4. **Check what version you have** (it tells you which key names to expect): `archinstall --version`.
5. **Last resort: write it by hand.** Generate a password hash (on any machine with OpenSSL):

   ```bash
   openssl passwd -6
   ```

   Then create `user_credentials.json`. Recent archinstall versions (3.x) use this shape:

   ```json
   {
     "users": [
       {
         "username": "jack",
         "enc_password": "$6$PASTE_YOUR_HASH_HERE",
         "sudo": true,
         "groups": []
       }
     ]
   }
   ```

   Older versions use different key names (for example `"!users"` and `"!password"`). Because key names vary by version, treat this as a template: if archinstall rejects the file, compare it with a generated one (steps 1-3), which is always correct for your ISO.

   Validate the syntax with `jq . user_credentials.json`. If your version also wants a root entry (for example `"root_enc_password"`), add it the same way, or skip root and rely on sudo.

### 5d. Copy the files out of the VM

In the VM, set a throwaway root password so SSH works:

```bash
passwd
```

On your Ubuntu computer (a second terminal):

```bash
scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  'root@localhost:/root/user_*.json' ~/arch-autoinstall/generated/
ls -l ~/arch-autoinstall/generated/
```

Shut the VM down (`poweroff` inside it). Then delete the VM disk, you will want a clean one later:

```bash
rm ~/arch-autoinstall/test-disk.qcow2
```

### 5e. Inspect the config

```bash
cd ~/arch-autoinstall/generated
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

**To reuse the hash from your Ubuntu `user-data`:** open `user_credentials.json`, find the user's password field (the key is named something like `enc_password`; the exact name depends on the version) and paste your `$6$...` hash over its value. Keep the JSON valid (quotes and commas), then check with `jq . user_credentials.json`.

---

## 6. Put Ventoy on the USB stick

### If you already have a Ventoy stick (e.g. with your Ubuntu autoinstall setup)

Skip to **section 7**. Your existing files stay. Only run the steps below if you want a fresh stick or a newer Ventoy.

### Fresh install

1. Download and unpack Ventoy:

   ```bash
   mkdir -p ~/ventoy && cd ~/ventoy
   URL=$(curl -s https://api.github.com/repos/ventoy/Ventoy/releases/latest \
     | jq -r '.assets[].browser_download_url | select(endswith("-linux.tar.gz"))')
   echo "$URL"
   curl -L -o ventoy-linux.tar.gz "$URL"
   tar -xzf ventoy-linux.tar.gz
   cd ventoy-*/
   ```

2. **Find your stick's device name safely.** Run this with the stick **unplugged**, then again **plugged in**:

   ```bash
   lsblk -d -o NAME,SIZE,MODEL,TRAN
   ```

   The new line is your stick (for example `sdb`, `TRAN` = `usb`). It is `/dev/sdb` in the next command. **Triple-check the size and model. Picking the wrong disk destroys it.**

3. Install (this **erases the stick**; type `y` at both prompts):

   ```bash
   sudo sh Ventoy2Disk.sh -i /dev/sdX
   ```

   Replace `sdX` with your device. To update Ventoy on an existing stick without touching files, use `-u` instead of `-i`.

4. Unplug and re-plug the stick. Ubuntu mounts the big partition (labelled `Ventoy`) at `/media/$USER/Ventoy`.

---

## 7. Put the files on the stick

```bash
USB=/media/$USER/Ventoy
ls "$USB"      # sanity check: the stick is mounted
```

### 7a. Copy the ISO and config

```bash
cp ~/arch-autoinstall/out/arch-autoinstall-*.iso "$USB/arch-autoinstall.iso"
mkdir -p "$USB/arch-autoinstall" "$USB/ventoy"
cp ~/arch-autoinstall/generated/user_configuration.json \
   ~/arch-autoinstall/generated/user_credentials.json \
   "$USB/arch-autoinstall/"
```

(Renaming the ISO to a fixed name means `ventoy.json` never needs editing when you rebuild.)

### 7b. Create `autoinstall.env`

```bash
nano "$USB/arch-autoinstall/autoinstall.env"
```

```bash
# Wi-Fi used (a) by the live installer if there is no cable, and
# (b) configured on the installed system. Use SINGLE quotes.
WIFI_SSID='YourNetworkName'
WIFI_PSK='YourWifiPassword'
WIFI_HIDDEN=0

# auto = largest internal (non-USB) disk. Or pin one, e.g.:
# TARGET_DISK=/dev/disk/by-id/nvme-Samsung_SSD_980_1TB_XXXXXXXX
TARGET_DISK=auto

# Seconds to wait before erasing (any key aborts). 0 = no wait.
CONFIRM_SECONDS=30

# Root filesystem: btrfs (snapshots) or ext4 (closest to Ubuntu 'layout: direct')
ROOT_FS=btrfs

# Enable the SSH server on the installed system (1 = yes). Password login works by default.
ENABLE_SSH=1

# Login name (must match the user you made in archinstall) and full name
USER_NAME='jack'
REAL_NAME='Jack Cooper-McEwan'

# 1 = lock the root account (no root password login; use your user + sudo, like Ubuntu).
# Set 0 if you set a root password in archinstall and want to keep it.
LOCK_ROOT=1

# Leave empty to keep the hostname from the JSON ('optiplex'); set to override per run.
HOSTNAME_OVERRIDE=''

# 1 = run ansible-pull to completion BEFORE the login screen appears (the screen shows
#     boot text for a few minutes; if the playbook fails, the login screen starts anyway).
# 0 = run it in the background after the login screen is up (retries every 60 s).
ANSIBLE_BEFORE_LOGIN=1

# 1 = reboot once automatically after a successful ansible-pull (so kernel, driver and
#     display-manager changes take effect). Runs only on success, never loops.
ANSIBLE_REBOOT_AFTER=1

# First-boot ansible-pull. Empty ANSIBLE_PULL_URL = skip.
ANSIBLE_PULL_URL='https://github.com/cqkh42/llangvilla.git'
ANSIBLE_PLAYBOOK='ansible/site.yml'

```

Notes: a Wi-Fi password containing a single quote `'` needs escaping (avoid it or change the password). WPA3-only (SAE) networks need `key-mgmt=sae` in the script; WPA2 and WPA2/WPA3 mixed work as written.

### 7c. Make Ventoy auto-boot the Arch ISO

> If `$USB/ventoy/ventoy.json` already exists (from your Ubuntu setup), **merge** the `control` entries into it. Don't overwrite it.

```bash
nano "$USB/ventoy/ventoy.json"
```

```json
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/arch-autoinstall.iso" }
  ]
}
```

Ventoy will now boot the Arch ISO automatically after 10 seconds unless someone presses a key to pick another entry. If you'd rather choose manually every time, leave out `VTOY_DEFAULT_IMAGE`.

### 7d. Flush and eject

```bash
sync
udisksctl unmount -b "$(findmnt -no SOURCE "$USB")"
```

Then unplug the stick.

---

## 8. Test the real stick in a VM first

Do this before trusting the stick with real hardware.

1. Make sure the stick is **not mounted** (see 7d). Find its device name (`lsblk -d -o NAME,SIZE,MODEL,TRAN`).
2. Create a fresh virtual target disk:

   ```bash
   qemu-img create -f qcow2 ~/arch-autoinstall/test-disk.qcow2 60G
   ```

3. Boot the stick in QEMU (`sudo` is needed to read the raw USB device):

   ```bash
   sudo qemu-system-x86_64 \
     -enable-kvm -cpu host -smp 4 -m 6G \
     -bios /usr/share/ovmf/OVMF.fd \
     -drive file=/dev/sdX,format=raw,if=virtio \
     -drive file="$HOME/arch-autoinstall/test-disk.qcow2",if=virtio \
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
     -bios /usr/share/ovmf/OVMF.fd \
     -drive file="$HOME/arch-autoinstall/test-disk.qcow2",if=virtio \
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

Leave `ANSIBLE_PULL_URL` empty to skip it. Read section 15 before relying on it: if your playbook is Ubuntu-specific it will fail on Arch.

### 11c. Nvidia graphics

The stick installs open-source drivers (nouveau), which gives a working desktop. After install: `sudo pacman -S nvidia-open nvidia-utils` (for recent cards) and reboot. Put this in your Ansible instead if you manage Nvidia machines.

---

## 12. Maintenance

- **Rebuild the ISO about monthly**, or whenever something breaks: re-run section 4, copy the new ISO over `arch-autoinstall.iso`. The Arch ISO is a snapshot of the repos, and an old one carries an old `archinstall`.
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
| First-boot ansible keeps failing | `journalctl -u ansible-pull-firstboot.service -b`. Usually Ubuntu-only tasks (apt, PPAs, snap). See section 15. With `ANSIBLE_BEFORE_LOGIN=1` it runs once per boot (SDDM starts anyway); with `0` it retries every 60 s until it succeeds, so stop it with `sudo systemctl stop ansible-pull-firstboot.service` while you fix the playbook. |
| Can't SSH in | `systemctl status sshd`; confirm `ENABLE_SSH=1` and that `openssh` is installed. Arch has no firewall by default, so it's not blocked. Host keys are generated on first start. |
| Every machine has the same hostname | Expected: one JSON, one hostname. Use `HOSTNAME_OVERRIDE` per run or rename in Ansible. |
| `user_credentials.json is missing` | The script refuses to run without it (before wiping anything). Generate it as described in section 5c. |

Saved logs from every run (including failures) are in `arch-autoinstall/logs/` on the stick.

---

### Using `jack` instead of root

The setup already does this: `jack` is the normal login and administrator (member of `wheel`, can use `sudo`), and with `LOCK_ROOT=1` (the default) the root account is locked so nobody can log in as root. In the archinstall menu, skip the root password. To get a root shell, run `sudo -i`.

Don't rename root to `jack` or give `jack` UID 0. It breaks packages and services that expect `root`, and it gives up the safety of a normal user. Using `sudo` gives you the same power.

## 14. Mapping from your Ubuntu `user-data`

| `user-data` key | Arch equivalent |
|---|---|
| `locale`, `keyboard`, `timezone` | archinstall Locales / Timezone (section 5b). Ubuntu's `gb` layout is `uk` in archinstall. |
| `source.id: ubuntu-desktop-minimal` | archinstall profile **KDE Plasma** + **sddm** (a deliberate switch from Ubuntu's GNOME). |
| `network` (NetworkManager, DHCP on wired, Wi-Fi) | NetworkManager in archinstall (DHCP on wired is the default). Wi-Fi: `iwctl` on the live ISO, then a NetworkManager keyfile on the installed system, both written by `install.sh` from `autoinstall.env`. |
| `storage.layout: direct` | `install.sh` partitions: 1 GB EFI + one root partition. `ROOT_FS=ext4` is closest to `direct`; `btrfs` (default) adds subvolumes and snapshots. |
| `identity.username`, `hostname`, `password` | archinstall user + hostname (TUI), hash in `user_credentials.json`. |
| `identity.realname` | `USER_NAME` + `REAL_NAME` in `autoinstall.env` (`usermod -c`). |
| `ssh.install-server`, `allow-pw` | `openssh` package + `ENABLE_SSH=1`. Arch's sshd allows password login by default; root password login is refused by default. |
| `ubuntu-pro.token` | No equivalent. Dropped, so no token on the stick. |
| `codecs.install: true` | `gst-plugins-good/bad/ugly`, `gst-libav`, `ffmpeg` packages. |
| `drivers.install: false` | Graphics driver: **All open-source**. |
| `packages: ansible, git` | Added automatically when `ANSIBLE_PULL_URL` is set (and in the package list). |
| `late-commands` (ansible-pull unit) | Built into `install.sh`, see section 11b. |
| `__WIFI_SSID__` / `__PASSWORD_HASH__` placeholders | Real values live in `autoinstall.env` and `user_credentials.json` on the stick only (section 16). |

## 15. Gotchas specific to your setup

**1. Your playbook must support Arch (the big one).** `ansible/site.yml` was written for Ubuntu. Typical breakages:

- `apt` tasks, PPAs, `snap`, `ubuntu-drivers`, `ufw`: use `community.general.pacman` instead, guard Ubuntu-only tasks with `when: ansible_os_family == "Debian"` and add `Archlinux` equivalents.
- Package names differ (`openssh-server` -> `openssh`, `python3-*` -> `python-*`, `build-essential` -> `base-devel`).
- AUR packages are not available via `pacman`. You need an AUR helper (`paru` or `yay`) built and run **as a normal user**, never root.
- `ansible-pull` runs as **root** from systemd. Use `become_user: jack` for user-level tasks, and set `ansible_user`-style variables accordingly.
- The Arch `ansible` package includes the common collections. If you ever switch to `ansible-core` you must install `community.general` yourself.
- Test the playbook on the VM from section 8 before the real machine.

**2. Failure behaviour depends on `ANSIBLE_BEFORE_LOGIN`.** With `1`, a failing playbook is attempted once per boot (SDDM then starts anyway, so you can always log in and read `journalctl -u ansible-pull-firstboot.service -b`). With `0`, the unit retries every 60 seconds until it passes, which can hammer the machine and network. The "done" marker is only written on success.

**3. With `ANSIBLE_BEFORE_LOGIN=1` the first boot is slow.** Expect text on the console, possibly for several minutes (up to 30, then systemd gives up and SDDM starts regardless). Don't power off during it. With `0`, the playbook may be mid-way through installing packages while SDDM is already showing; some changes (kernel modules, display manager, groups) then need a reboot.

**4. The repo must be public.** The unit clones over HTTPS with no credentials. A private repo needs a deploy key or token, which means putting a secret on the machine.

**5. KDE Plasma is a different desktop from your Ubuntu GNOME.** Your muscle memory, GNOME extensions, dconf/gsettings tweaks and any `gnome-*` settings in the playbook won't apply. If the playbook sets GNOME settings (dconf, gsettings, extensions), those tasks do nothing useful on KDE; guard them or replace them with KDE equivalents (`kwriteconfig6`, files in `~/.config`). The archinstall KDE profile pulls in a modest set (Plasma, Konsole, Kate, Dolphin, SDDM). Add anything else (`kde-applications-meta`, Discover, Firefox integration) via packages or Ansible.

**6. KDE Plasma on Wayland + Nvidia.** The stick installs open-source drivers (nouveau), which is fine for Intel/AMD graphics. For Nvidia, install `nvidia-open nvidia-utils` and reboot; Plasma's Wayland session works with them but occasionally needs the X11 session as a fallback (pick it on the SDDM login screen). Do the driver install from Ansible so it's repeatable.

**7. SSH with password login is on, and Arch has no firewall.** Once `sshd` is enabled, the machine accepts password logins from the whole LAN as soon as it boots, exactly like your Ubuntu setup. Add your key and set `PasswordAuthentication no` later, or have Ansible do it.

**8. Password hash format.** `$6$` (SHA-512) from `openssl passwd -6` works. Don't paste a hash into the wrong field. The generated JSON shows which key holds it, and `jq . user_credentials.json` validates the syntax.

**9. Same hostname on every machine.** Your `user-data` hard-codes `optiplex`, and so does this one JSON. Two machines installed from the same stick will clash on the network. Use `HOSTNAME_OVERRIDE` or rename in Ansible.

**10. ext4 vs btrfs.** If the playbook or backup tooling assumes ext4 (Ubuntu `direct`), set `ROOT_FS=ext4`. With ext4, section 11a (snapper) doesn't apply.

**11. Real name is applied late.** It's set at the end of install via `usermod -c`. If `USER_NAME` doesn't match the archinstall user exactly, the command fails (the install still completes) and the full name stays empty. Check with `getent passwd jack`.

**12. First-boot network timing.** The unit waits for `network-online.target`. The script also enables `NetworkManager-wait-online.service`. Without it the playbook can start before Wi-Fi is up and fail its first attempt (it then retries).

**13. Secure Boot and Ventoy.** Same as before: it must be off. Your Ubuntu ISO may have booted with Secure Boot on; Arch will not.

**14. Things a before-login playbook must not do.** The run happens before any user session exists:

- **Don't restart or start `sddm` / `display-manager` from the playbook** (for example in a handler after changing its config). SDDM is waiting for the playbook to finish, so the restart waits for the playbook and the playbook waits for the restart: a deadlock until the 30-minute timeout. Just write the config; SDDM reads it when it starts afterwards. If you must trigger something, use `systemctl restart --no-block`.
- **No tasks that need a logged-in desktop session** (user dconf, user systemd units, `loginctl`, `kwriteconfig6` against a running session). Writing config files into `/etc` or `/home/jack/.config` is fine; changing live session state isn't.
- **Don't reboot from the playbook.** The unit reboots once by itself after a successful run (`ANSIBLE_REBOOT_AFTER=1`), so kernel, driver and display-manager changes take effect then. A reboot from inside the playbook would end the run before the done marker is written, and the playbook would run again.
- **SDDM config goes in `/etc/sddm.conf.d/*.conf`** (themes, default session, autologin). Put a drop-in file there rather than editing `/etc/sddm.conf`.
- **Alternative to running at boot:** you can run the same `ansible-pull` inside the install itself (a `custom_commands` entry). It finishes before the machine ever boots, but the install environment has no running systemd, so service start/restart tasks fail there. Only choose it if the playbook is purely files and packages.

## 16. Keeping your repo clean

Your `user-data` uses `__PLACEHOLDER__` values that you fill in on the USB copy. For Arch, split things so nothing secret needs templating:

```
llangvilla/
├── autoinstall/                    <- existing Ubuntu stuff
├── arch-autoinstall/
│   ├── build.sh
│   ├── install.sh
│   ├── user_configuration.json     <- safe to commit (no secrets)
│   └── autoinstall.env.example     <- same as section 7b with fake values
└── ansible/
```

`.gitignore` additions (the repo is public, so never commit these):

```
arch-autoinstall/user_credentials.json
arch-autoinstall/autoinstall.env
arch-autoinstall/out/
arch-autoinstall/generated/
*.iso
*.qcow2
```

A password hash in a public repo can be cracked offline, so keep `user_credentials.json` out of git even though it's "only" a hash. On the stick you copy the real `user_credentials.json` and `autoinstall.env` next to the committed JSON.

---

## Appendix: what each file does

| File | Where it lives | Purpose |
|---|---|---|
| `install.sh` | Inside the ISO (`/root/install.sh`) | Finds config, gets online, picks the disk, partitions, adds Wi-Fi/SSH/real-name/ansible-pull commands, runs archinstall, powers off |
| `build.sh` | Your PC | Builds the ISO inside Docker and bakes in `install.sh` plus the auto-run hook |
| `arch-autoinstall.iso` | Stick root | The generic installer image. Rebuild monthly, no secrets inside |
| `ventoy/ventoy.json` | Stick | Auto-boots the ISO after 10 s |
| `user_configuration.json` | Stick `arch-autoinstall/` | archinstall settings (profile, packages, locale...). Its `disk_config` is replaced at runtime |
| `user_credentials.json` | Stick `arch-autoinstall/` | Username and hashed password |
| `autoinstall.env` | Stick `arch-autoinstall/` | Wi-Fi, target disk, root filesystem, SSH, user real name, hostname override, ansible-pull repo, countdown |
| `logs/` | Stick `arch-autoinstall/` | Install logs copied back after each run |
