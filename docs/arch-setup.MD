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
```

You will create two files here: `install.sh` (runs on the target machine, inside the ISO) and `build.sh` (runs on your computer, inside Docker, to build the ISO).

### 3a. `install.sh`

```bash
nano ~/arch-autoinstall/install.sh
```

Paste **all** of this, then save (`Ctrl+O`, `Enter`) and exit (`Ctrl+X`):

```bash
#!/usr/bin/env bash
# /root/install.sh - zero-touch Arch Linux installer. Runs on the live ISO.
set -uo pipefail

USB_MNT=/mnt/usbdata
CFG_SUBDIR=arch-autoinstall
TARGET_MNT=/mnt/archinstall
WORK=/tmp/autoinstall
ESP_SIZE=1G

say() { printf '\n\033[1;36m[autoinstall]\033[0m %s\n' "$*"; }
die() {
  printf '\n\033[1;31m[autoinstall] ERROR:\033[0m %s\n' "$*" >&2
  echo "Nothing more will happen automatically. You are at a root shell." >&2
  echo "Fix the problem, then re-run:  /root/install.sh" >&2
  exit 1
}

mkdir -p "$USB_MNT" "$WORK" "$TARGET_MNT"

[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Boot the stick's UEFI entry."

# ---------------------------------------------------------------- 1. find the config on the USB stick
USB_PART=""
find_usb() {
  local dev
  while read -r dev; do
    mount -o ro "$dev" "$USB_MNT" 2>/dev/null || continue
    if [[ -f "$USB_MNT/$CFG_SUBDIR/user_configuration.json" ]]; then
      USB_PART=$dev
      mount -o remount,rw "$USB_MNT" 2>/dev/null || true   # so we can save logs back
      return 0
    fi
    umount "$USB_MNT"
  # Ventoy keeps its own partition open and re-exposes it as a device-mapper device
  # (e.g. /dev/mapper/VentoyPart), so scan those as well as plain partitions.
  done < <(lsblk -rpno NAME,TYPE | awk '$2!="disk" && $2!="loop" && $2!="rom" {print $1}')
  return 1
}

say "Looking for the '$CFG_SUBDIR' folder on the USB stick..."
for _ in $(seq 1 15); do find_usb && break; sleep 2; done
[[ -n $USB_PART ]] || die "Could not find $CFG_SUBDIR/user_configuration.json on any partition."
CFG="$USB_MNT/$CFG_SUBDIR"
# Walk up from the mounted device (partition or dm device) to the physical disk
USB_DISK=$USB_PART
while parent=$(lsblk -dno PKNAME "$USB_DISK" 2>/dev/null | head -n1) && [[ -n $parent ]]; do
  USB_DISK=/dev/$parent
done
say "Found config on $USB_PART (disk $USB_DISK)."

[[ -f $CFG/autoinstall.env ]] && source "$CFG/autoinstall.env"
: "${TARGET_DISK:=auto}" "${CONFIRM_SECONDS:=30}" "${WIFI_SSID:=}" "${WIFI_PSK:=}" "${WIFI_HIDDEN:=0}"
: "${ROOT_FS:=btrfs}" "${ENABLE_SSH:=1}" "${USER_NAME:=}" "${REAL_NAME:=}" "${HOSTNAME_OVERRIDE:=}"
: "${ANSIBLE_PULL_URL:=}" "${ANSIBLE_PLAYBOOK:=ansible/site.yml}" "${LOCK_ROOT:=1}"
[[ $ROOT_FS == btrfs || $ROOT_FS == ext4 ]] || die "ROOT_FS must be btrfs or ext4."
[[ -f $CFG/user_credentials.json ]] || die "$CFG_SUBDIR/user_credentials.json is missing. It holds the user and password."

# ---------------------------------------------------------------- 2. get online
online() { ping -c1 -W3 archlinux.org &>/dev/null; }
wait_online() { local i; for ((i = 0; i < $1; i++)); do online && return 0; sleep 2; done; return 1; }

say "Checking for a wired connection..."
if ! wait_online 6; then
  [[ -n $WIFI_SSID ]] || die "No wired network and no WIFI_SSID set in autoinstall.env."
  say "Connecting to Wi-Fi '$WIFI_SSID'..."
  rfkill unblock all 2>/dev/null || true
  iface=""
  for d in /sys/class/net/*; do
    [[ -d $d/wireless ]] && { iface=${d##*/}; break; }
  done
  [[ -n $iface ]] || die "No wireless interface found (missing firmware or driver?)."
  systemctl start iwd 2>/dev/null || true
  sleep 3
  iwctl station "$iface" scan 2>/dev/null || true
  sleep 5
  if [[ $WIFI_HIDDEN == 1 ]]; then
    iwctl --passphrase "$WIFI_PSK" station "$iface" connect-hidden "$WIFI_SSID" || true
  else
    iwctl --passphrase "$WIFI_PSK" station "$iface" connect "$WIFI_SSID" || true
  fi
  wait_online 20 || die "No internet over Wi-Fi. Check the SSID and password in autoinstall.env."
fi
say "Online."

# ---------------------------------------------------------------- 3. choose the target disk
pick_disk() {
  local best="" bestsize=0 line NAME SIZE TYPE TRAN
  while read -r line; do
    eval "$line"
    [[ $TYPE == disk ]] || continue
    [[ $TRAN == usb ]] && continue
    [[ $NAME == "$USB_DISK" ]] && continue
    [[ $NAME == /dev/zram* || $NAME == /dev/sr* || $NAME == /dev/ram* ]] && continue
    (( SIZE >= 40 * 1024 * 1024 * 1024 )) || continue
    if (( SIZE > bestsize )); then best=$NAME; bestsize=$SIZE; fi
  done < <(lsblk -dpnb -P -o NAME,SIZE,TYPE,TRAN)
  echo "$best"
}

if [[ $TARGET_DISK == auto ]]; then TARGET=$(pick_disk); else TARGET=$(readlink -f "$TARGET_DISK"); fi
[[ -b $TARGET ]] || die "No suitable target disk found (need an internal disk of at least 40 GB)."
[[ $TARGET != "$USB_DISK" ]] || die "Refusing to install onto the USB stick itself."

say "TARGET DISK: $TARGET"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL "$TARGET"

if (( CONFIRM_SECONDS > 0 )); then
  printf '\n\033[1;33m!!! EVERYTHING ON %s WILL BE ERASED !!!\033[0m\n' "$TARGET"
  echo "Press any key to ABORT."
  for ((i = CONFIRM_SECONDS; i > 0; i--)); do
    printf '\r  Starting in %2d seconds... ' "$i"
    if read -r -s -n1 -t1 _; then echo; die "Aborted by keypress."; fi
  done
  echo
fi

# ---------------------------------------------------------------- 4. partition, format, mount
say "Partitioning $TARGET..."
swapoff -a 2>/dev/null || true
umount -R "$TARGET_MNT" 2>/dev/null || true
wipefs -af "$TARGET" >/dev/null
sgdisk --zap-all "$TARGET" >/dev/null || die "sgdisk --zap-all failed."
sgdisk -n "1:0:+$ESP_SIZE" -t 1:ef00 -c 1:EFI \
       -n "2:0:0"          -t 2:8300 -c 2:ArchRoot "$TARGET" >/dev/null || die "Partitioning failed."
partprobe "$TARGET"; udevadm settle; sleep 2

mapfile -t PARTS < <(lsblk -lnpo NAME,TYPE "$TARGET" | awk '$2=="part" {print $1}')
ESP=${PARTS[0]:-}; ROOT=${PARTS[1]:-}
[[ -b $ESP && -b $ROOT ]] || die "Could not find the new partitions on $TARGET."

wipefs -af "$ESP" "$ROOT" >/dev/null
mkfs.fat -F32 -n EFI "$ESP" >/dev/null || die "mkfs.fat failed."

if [[ $ROOT_FS == ext4 ]]; then
  mkfs.ext4 -F -L archroot "$ROOT" >/dev/null || die "mkfs.ext4 failed."
  mount "$ROOT" "$TARGET_MNT"
  mkdir -p "$TARGET_MNT/boot"
else
  mkfs.btrfs -f -L archroot "$ROOT" >/dev/null || die "mkfs.btrfs failed."
  mkdir -p /mnt/btrfs-top
  mount "$ROOT" /mnt/btrfs-top
  for sv in @ @home @log @pkg @.snapshots; do btrfs subvolume create "/mnt/btrfs-top/$sv" >/dev/null; done
  umount /mnt/btrfs-top

  OPTS="noatime,compress=zstd:3"
  mount -o "$OPTS,subvol=@" "$ROOT" "$TARGET_MNT"
  mkdir -p "$TARGET_MNT"/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}
  mount -o "$OPTS,subvol=@home"       "$ROOT" "$TARGET_MNT/home"
  mount -o "$OPTS,subvol=@log"        "$ROOT" "$TARGET_MNT/var/log"
  mount -o "$OPTS,subvol=@pkg"        "$ROOT" "$TARGET_MNT/var/cache/pacman/pkg"
  mount -o "$OPTS,subvol=@.snapshots" "$ROOT" "$TARGET_MNT/.snapshots"
fi
mount "$ESP" "$TARGET_MNT/boot"

# ---------------------------------------------------------------- 5. build the final archinstall config
# Commands that archinstall runs inside the new system at the end (custom_commands).
CMDS=()

# 5-00. Lock the root account (log in as your user, use sudo) - like Ubuntu
[[ $LOCK_ROOT == 1 ]] && CMDS+=("passwd -l root")

# 5a. Wi-Fi profile for the installed system (NetworkManager keyfile)
if [[ -n $WIFI_SSID ]]; then
  HIDDEN_LINE=""; [[ $WIFI_HIDDEN == 1 ]] && HIDDEN_LINE="hidden=true"
  NM_FILE=$(cat <<EOF
[connection]
id=$WIFI_SSID
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID
$HIDDEN_LINE

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
method=auto
EOF
)
  CMDS+=("$(cat <<EOF
install -d -m 755 /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection <<'NMEOF'
$NM_FILE
NMEOF
chmod 600 /etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection
EOF
)")
fi

# 5b. SSH server
[[ $ENABLE_SSH == 1 ]] && CMDS+=("systemctl enable sshd.service")

# 5c. Full name (what Ubuntu's identity.realname does)
if [[ -n $USER_NAME && -n $REAL_NAME ]]; then
  printf -v c 'usermod -c %q %q' "$REAL_NAME" "$USER_NAME"
  CMDS+=("$c")
fi

# 5d. First-boot ansible-pull (same unit as your Ubuntu late-commands)
if [[ -n $ANSIBLE_PULL_URL ]]; then
  CMDS+=("$(cat <<EOF
cat > /etc/systemd/system/ansible-pull-firstboot.service <<'UNITEOF'
[Unit]
Description=Initial ansible-pull
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/ansible-pull-firstboot.done

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/bin/ansible-pull -U $ANSIBLE_PULL_URL $ANSIBLE_PLAYBOOK
ExecStartPost=/usr/bin/touch /var/lib/ansible-pull-firstboot.done
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl enable NetworkManager-wait-online.service ansible-pull-firstboot.service
EOF
)")
fi

# Extra packages the commands above rely on
PKGS=()
[[ $ROOT_FS == btrfs ]] && PKGS+=(btrfs-progs)
[[ $ENABLE_SSH == 1 ]] && PKGS+=(openssh)
[[ -n $ANSIBLE_PULL_URL ]] && PKGS+=(git ansible)

# Turn the bash arrays into JSON arrays (safe for any characters)
CMDS_JSON='[]'; for c in "${CMDS[@]}"; do CMDS_JSON=$(jq -c --arg c "$c" '. + [$c]' <<<"$CMDS_JSON"); done
PKGS_JSON='[]'; for k in "${PKGS[@]}"; do PKGS_JSON=$(jq -c --arg k "$k" '. + [$k]' <<<"$PKGS_JSON"); done

# Replace disk_config (we already partitioned/mounted), add packages and commands,
# optionally override the hostname.
jq --argjson cmds "$CMDS_JSON" --argjson pkgs "$PKGS_JSON" --arg host "$HOSTNAME_OVERRIDE" '
    .disk_config = {"config_type": "pre_mounted_config", "mountpoint": "/mnt/archinstall"}
  | .packages = (((.packages // []) + $pkgs) | unique)
  | .custom_commands = ((.custom_commands // []) + $cmds)
  | if $host != "" then .hostname = $host else . end
' "$CFG/user_configuration.json" > "$WORK/user_configuration.json" \
  || die "jq failed. Is user_configuration.json valid JSON?"

# ---------------------------------------------------------------- 6. install
say "Running archinstall. This takes a while (downloads several GB)..."
ARGS=(--config "$WORK/user_configuration.json" --creds "$CFG/user_credentials.json" --silent)

ok=0
archinstall "${ARGS[@]}" && ok=1

mkdir -p "$CFG/logs"
cp /var/log/archinstall/install.log "$CFG/logs/install-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || true
sync
(( ok )) || die "archinstall failed. Its log was copied to $CFG_SUBDIR/logs/ on the USB stick."

# ---------------------------------------------------------------- 7. finish
umount -R "$TARGET_MNT" 2>/dev/null || true
umount "$USB_MNT" 2>/dev/null || true
say "INSTALL COMPLETE. Powering off in 15 seconds. REMOVE THE USB STICK, then power the machine on."
sleep 15
systemctl poweroff
```

Why power off instead of reboot? If the machine rebooted with the stick still in, it could boot the stick again and reinstall in a loop.

### 3b. `build.sh`

```bash
nano ~/arch-autoinstall/build.sh
```

Paste, save, exit:

```bash
#!/bin/bash
# Runs INSIDE an Arch Linux Docker container. Builds the custom ISO.
set -euo pipefail

pacman -Syu --noconfirm archiso

rm -rf /tmp/profile /tmp/work
cp -r /usr/share/archiso/configs/releng /tmp/profile
cd /tmp/profile

# 1. extra packages on the live ISO
echo "jq" >> packages.x86_64

# 2. our installer script
install -Dm755 /work/install.sh airootfs/root/install.sh
sed -i '/^file_permissions=(/a\  ["/root/install.sh"]="0:0:755"' profiledef.sh
grep -q '/root/install.sh' profiledef.sh

# 3. ISO name
sed -i 's/^iso_name=.*/iso_name="arch-autoinstall"/' profiledef.sh

# 4. auto-run the installer when root logs in on tty1
cat >> airootfs/root/.zlogin <<'EOF'

# --- zero-touch install hook ---
if [[ $(tty) == /dev/tty1 && -z ${AUTOINSTALL_STARTED:-} ]]; then
    export AUTOINSTALL_STARTED=1
    /root/install.sh
fi
EOF

# 5. build
mkdir -p /work/out
mkarchiso -v -w /tmp/work -o /work/out /tmp/profile
echo "BUILD OK"
```

Make both scripts executable:

```bash
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
7. **Remove the stick**, power on, and you should land on the SDDM login.

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

This is now done by `install.sh`, so you no longer hand-edit JSON. Set `ANSIBLE_PULL_URL` and `ANSIBLE_PLAYBOOK` in `autoinstall.env` (section 7b). The script will:

- add `git` and `ansible` to the package list,
- write `/etc/systemd/system/ansible-pull-firstboot.service` (the same unit as your Ubuntu `late-commands`, plus `HOME=/root`),
- enable it together with `NetworkManager-wait-online.service`, so `network-online.target` genuinely waits for the network.

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
| First-boot ansible keeps failing | `journalctl -u ansible-pull-firstboot.service -b`. Usually Ubuntu-only tasks (apt, PPAs, snap). See section 15. The unit retries every 60 s until it succeeds, so stop it with `sudo systemctl stop ansible-pull-firstboot.service` while you fix the playbook. |
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

**2. A failing playbook retries forever.** The unit has `Restart=on-failure` and `RestartSec=60`, and the "done" marker is only touched on success. It will rerun every minute until it passes. That is useful, but it means a bad playbook hammers the machine and the network on every boot. Check `journalctl -u ansible-pull-firstboot.service -b`.

**3. It runs at boot, before you log in.** The playbook may be mid-way through installing packages while SDDM is already showing. Don't power off until `systemctl status ansible-pull-firstboot.service` shows it finished. Some changes (kernel modules, display manager, groups) need a reboot.

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
