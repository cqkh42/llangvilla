#!/usr/bin/env bash
# /root/install.sh - zero-touch Arch Linux installer (pacstrap based). Runs on the live ISO.
#
#   install.sh                    find arch-autoinstall/ on the stick and install
#                                 (live ISO only: ERASES the target disk)
#   install.sh --check ENV_FILE   validate an autoinstall.env and exit. Safe anywhere,
#                                 e.g. on the build computer before booting the stick.
#
# Config, all on the stick in arch-autoinstall/:
#   autoinstall.env   settings and secrets (template: autoinstall.env.example)
#   packages.txt      package list (copied from the repo by build-usb.sh / vm/test-vm.sh)
#   install.sh        optional: if present, it replaces this baked-in copy (vm/test-vm.sh
#                     uses this so installer changes can be tested without an ISO rebuild)
#
# The installer builds a clean base system. Personalisation is the config's job
# (config/README.md); the only link is the first-boot hook (CONFIG_* settings),
# which clones the repo and runs its entrypoint.
#
# No `set -e` on purpose: every step that matters is checked, and a failure drops
# to a root shell (or powers off with ON_FAILURE=poweroff) instead of vanishing.
set -uo pipefail

USB_MNT=/mnt/usbdata
CFG_SUBDIR=arch-autoinstall
T=/mnt/target                 # the new system is assembled here
WORK=/tmp/autoinstall
LOG=$WORK/install.log
ESP_SIZE=1G
STAMP=$(date +%Y%m%d-%H%M%S)

CFG=""                        # set once the stick is found
CHECK_ONLY=0
ON_FAILURE=shell

# ---------------------------------------------------------------- output and failure handling
say()  { printf '\n\033[1;36m[autoinstall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[autoinstall] WARNING:\033[0m %s\n' "$*" >&2; }

# Copy this run's log to the stick and record the outcome (test-vm.sh reads last-status).
save_logs() {
  [[ -n $CFG && -d $CFG ]] || return 0
  mkdir -p "$CFG/logs" 2>/dev/null || return 0
  cp "$LOG" "$CFG/logs/install-$STAMP.log" 2>/dev/null
  if [[ -f $T/etc/fstab ]]; then cp "$T/etc/fstab" "$CFG/logs/fstab-$STAMP" 2>/dev/null; fi
  printf '%s %s\n' "$1" "$STAMP" > "$CFG/logs/last-status" 2>/dev/null
  sync
}

die() {
  printf '\n\033[1;31m[autoinstall] ERROR:\033[0m %s\n' "$*" >&2
  (( CHECK_ONLY )) && exit 1
  save_logs "FAILED: $*"
  if [[ $ON_FAILURE == poweroff ]]; then
    echo "ON_FAILURE=poweroff: logs saved to $CFG_SUBDIR/logs/ on the stick, powering off." >&2
    sleep 5
    systemctl poweroff
    exit 1
  fi
  echo "Nothing more will happen automatically. You are at a root shell." >&2
  echo "The log is in $LOG (and $CFG_SUBDIR/logs/ on the stick, if it was found)." >&2
  echo "Fix the problem, then re-run:  /root/install.sh" >&2
  exit 1
}

# ---------------------------------------------------------------- config
load_env() {
  # shellcheck source=/dev/null
  source "$1" || die "Could not read $1."
  : "${WIFI_SSID:=}" "${WIFI_PSK:=}" "${WIFI_HIDDEN:=0}"
  : "${TARGET_DISK:=auto}" "${CONFIRM_SECONDS:=30}" "${NONBLANK_DISK:=ask}" "${ROOT_FS:=btrfs}"
  : "${HOST_NAME:=archlinux}" "${TIMEZONE:=UTC}" "${LOCALE:=en_US.UTF-8}" "${KEYMAP:=us}" "${X11_KEYMAP:=}"
  : "${KERNELS:=linux}" "${EXTRA_PACKAGES:=}"
  : "${USER_NAME:=}" "${REAL_NAME:=}" "${PASSWORD_HASH:=}" "${LOCK_ROOT:=1}"
  : "${ENABLE_SSH:=1}" "${SSH_KEYS_URL:=}" "${SSH_AUTHORIZED_KEYS:=}" "${SSH_PASSWORD_AUTH:=0}"
  : "${CONFIG_REPO_URL:=}" "${CONFIG_REPO_BRANCH:=}" "${CONFIG_ENTRYPOINT:=config/apply.sh}"
  : "${FIRSTBOOT_BEFORE_LOGIN:=1}" "${FIRSTBOOT_REBOOT_AFTER:=1}"
  : "${ON_FAILURE:=shell}"
}

# Collect every problem with the loaded settings, print them all, return 1 if any.
check_config() {
  local env_file=$1 errs=() v line
  # Any placeholder left on a non-comment line
  while IFS= read -r line; do
    errs+=("placeholder not filled in: ${line}")
  done < <(grep -nE '^[^#]*__[A-Z_]+__' "$env_file")

  # Settings from before the first-boot hook was made generic: fail rather than
  # silently skipping the config on a stick with an old env file.
  while IFS= read -r line; do
    errs+=("${line}: the ANSIBLE_* settings were renamed (CONFIG_REPO_URL, CONFIG_REPO_BRANCH, CONFIG_ENTRYPOINT, FIRSTBOOT_*); see autoinstall.env.example")
  done < <(grep -nE '^[[:space:]]*ANSIBLE_[A-Z_]+=' "$env_file")

  for v in WIFI_HIDDEN LOCK_ROOT ENABLE_SSH SSH_PASSWORD_AUTH FIRSTBOOT_BEFORE_LOGIN FIRSTBOOT_REBOOT_AFTER; do
    [[ ${!v} == 0 || ${!v} == 1 ]] || errs+=("$v must be 0 or 1 (is '${!v}')")
  done
  [[ $CONFIRM_SECONDS =~ ^[0-9]+$ ]] || errs+=("CONFIRM_SECONDS must be a number of seconds")
  [[ $ROOT_FS == btrfs || $ROOT_FS == ext4 ]] || errs+=("ROOT_FS must be btrfs or ext4")
  [[ $NONBLANK_DISK == ask || $NONBLANK_DISK == wipe ]] || errs+=("NONBLANK_DISK must be ask or wipe")
  [[ $ON_FAILURE == shell || $ON_FAILURE == poweroff ]] || errs+=("ON_FAILURE must be shell or poweroff")
  [[ $TARGET_DISK == auto || $TARGET_DISK == /dev/* ]] || errs+=("TARGET_DISK must be auto or a /dev/... path")

  [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || errs+=("USER_NAME '$USER_NAME' is not a valid login name")
  [[ $REAL_NAME != *[:$'\n']* ]] || errs+=("REAL_NAME must not contain ':' or a newline")
  [[ $PASSWORD_HASH =~ ^\$(6|5|y|gy|2[aby])\$ ]] \
    || errs+=("PASSWORD_HASH must be a crypt hash (e.g. from 'openssl passwd -6'), not a plain password")
  [[ $HOST_NAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})$ ]] || errs+=("HOST_NAME '$HOST_NAME' is not a valid hostname")
  [[ $LOCALE =~ ^[A-Za-z0-9_.@-]+$ ]] || errs+=("LOCALE '$LOCALE' looks wrong (e.g. en_GB.UTF-8)")
  [[ $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ && $TIMEZONE != *..* ]] || errs+=("TIMEZONE '$TIMEZONE' looks wrong")
  if [[ -d /usr/share/zoneinfo && ! -f /usr/share/zoneinfo/$TIMEZONE ]]; then
    errs+=("TIMEZONE '$TIMEZONE' is not a known zone")
  fi
  if [[ -f /usr/share/i18n/SUPPORTED ]] && ! grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED; then
    errs+=("LOCALE '$LOCALE' is not a supported locale")
  fi
  [[ -n ${KERNELS// /} ]] || errs+=("KERNELS must name at least one kernel (e.g. 'linux linux-lts')")

  if [[ -n $WIFI_SSID ]]; then
    (( ${#WIFI_PSK} >= 8 && ${#WIFI_PSK} <= 64 )) || errs+=("WIFI_PSK must be 8-63 characters (or 64 hex digits)")
  elif [[ -n $WIFI_PSK ]]; then
    errs+=("WIFI_PSK is set but WIFI_SSID is empty")
  fi
  [[ $CONFIG_REPO_URL$CONFIG_REPO_BRANCH$CONFIG_ENTRYPOINT != *[[:space:]]* ]] \
    || errs+=("CONFIG_REPO_URL, CONFIG_REPO_BRANCH and CONFIG_ENTRYPOINT must not contain spaces")
  [[ $CONFIG_ENTRYPOINT != /* && $CONFIG_ENTRYPOINT != *..* && -n $CONFIG_ENTRYPOINT ]] \
    || errs+=("CONFIG_ENTRYPOINT must be a path inside the repo (e.g. config/apply.sh)")

  if (( ${#errs[@]} )); then
    printf '\033[1;31m[autoinstall] %s has problems:\033[0m\n' "$env_file" >&2
    printf '  - %s\n' "${errs[@]}" >&2
    return 1
  fi
  return 0
}

if [[ ${1:-} == --check ]]; then
  CHECK_ONLY=1
  [[ -n ${2:-} && -f ${2:-} ]] || die "Usage: install.sh --check /path/to/autoinstall.env"
  load_env "$2"
  check_config "$2" || exit 1
  echo "OK: $2 looks valid (host '$HOST_NAME', user '$USER_NAME', $ROOT_FS, disk $TARGET_DISK)."
  exit 0
fi

# ---------------------------------------------------------------- 0. start
mkdir -p "$USB_MNT" "$WORK" "$T"
# Everything below is also written to $LOG, which is copied to the stick at the end
# (or on failure). A delegated copy (see step 1) inherits this, so skip it there.
if [[ -z ${AUTOINSTALL_DELEGATED:-} ]]; then exec > >(tee -a "$LOG") 2>&1; fi

[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Boot the stick's UEFI entry."

# ---------------------------------------------------------------- 1. find the config on the USB stick
USB_PART=""
find_usb() {
  local dev
  while read -r dev; do
    mount -o ro "$dev" "$USB_MNT" 2>/dev/null || continue
    if [[ -f "$USB_MNT/$CFG_SUBDIR/autoinstall.env" ]]; then
      USB_PART=$dev
      mount -o remount,rw "$USB_MNT" 2>/dev/null || true   # so we can save logs back
      return 0
    fi
    umount "$USB_MNT"
  # Ventoy keeps its own partition open and re-exposes it as a device-mapper device
  # (e.g. /dev/mapper/VentoyPart), so scan those as well as plain partitions. Whole
  # disks are scanned too, for unpartitioned images (test-vm.sh).
  done < <(lsblk -rpno NAME,TYPE | awk '$2!="loop" && $2!="rom" {print $1}')
  return 1
}

say "Looking for the '$CFG_SUBDIR' folder on the USB stick..."
for _ in $(seq 1 15); do find_usb && break; sleep 2; done
[[ -n $USB_PART ]] || die "Could not find $CFG_SUBDIR/autoinstall.env on any partition."
CFG="$USB_MNT/$CFG_SUBDIR"

# A newer installer on the stick replaces this baked-in one (fast iteration in test-vm.sh).
if [[ -f $CFG/install.sh && -z ${AUTOINSTALL_DELEGATED:-} ]] && ! cmp -s "$CFG/install.sh" "$0"; then
  say "Using $CFG_SUBDIR/install.sh from the stick instead of the copy in the ISO."
  cp "$CFG/install.sh" "$WORK/install-from-stick.sh"
  umount "$USB_MNT"
  AUTOINSTALL_DELEGATED=1 exec bash "$WORK/install-from-stick.sh"
fi

# Walk up from the mounted device (partition or dm device) to the physical disk
USB_DISK=$USB_PART
while parent=$(lsblk -dno PKNAME "$USB_DISK" 2>/dev/null | head -n1) && [[ -n $parent ]]; do
  USB_DISK=/dev/$parent
done
say "Found config on $USB_PART (disk $USB_DISK)."

load_env "$CFG/autoinstall.env"
check_config "$CFG/autoinstall.env" || die "Fix autoinstall.env on the stick (nothing has been erased)."
[[ -f $CFG/packages.txt ]] || die "$CFG_SUBDIR/packages.txt is missing. Re-run build-usb.sh to copy it."

# ---------------------------------------------------------------- 2. get online
online() { curl -fsS -o /dev/null --max-time 5 https://archlinux.org/ 2>/dev/null; }
wait_online() { local i; for ((i = 0; i < $1; i++)); do online && return 0; sleep 2; done; return 1; }

say "Checking for a wired connection..."
if ! wait_online 8; then
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

# ---------------------------------------------------------------- 3. prepare the live environment
# Wait for a oneshot unit that is still starting (the ISO runs these at boot).
wait_unit() {
  local unit=$1 secs=$2 i
  for ((i = 0; i < secs; i++)); do
    [[ $(systemctl show -p ActiveState --value "$unit" 2>/dev/null) == activating ]] || return 0
    sleep 1
  done
  warn "$unit is still running after ${secs}s, carrying on."
}

say "Preparing the live environment (clock, keyring, mirrors)..."
timedatectl set-ntp true 2>/dev/null || true
for _ in $(seq 1 30); do
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && break
  sleep 1
done
[[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] \
  || warn "Clock not NTP-synchronised yet; package signature checks may fail if it is far off."
wait_unit pacman-init.service 120
wait_unit reflector.service 120
# An older ISO carries an older keyring: refresh it so new packages' signatures verify.
pacman -Sy --noconfirm --needed archlinux-keyring || die "Could not refresh the Arch keyring."

# ---------------------------------------------------------------- 4. package list (checked BEFORE erasing anything)
# mkinitcpio is named explicitly: with --noconfirm pacman would pick the first
# 'initramfs' provider, which is not necessarily mkinitcpio.
PKGS=(base linux-firmware mkinitcpio sudo networkmanager zram-generator)
read -ra kernels <<<"$KERNELS"
PKGS+=("${kernels[@]}")
UCODE=""
if grep -q GenuineIntel /proc/cpuinfo; then UCODE=intel-ucode; fi
if grep -q AuthenticAMD /proc/cpuinfo; then UCODE=amd-ucode; fi
[[ -n $UCODE ]] && PKGS+=("$UCODE")
[[ $ROOT_FS == btrfs ]] && PKGS+=(btrfs-progs)
[[ $ENABLE_SSH == 1 ]] && PKGS+=(openssh)
[[ -n $CONFIG_REPO_URL ]] && PKGS+=(git)
read -ra extra <<<"$EXTRA_PACKAGES"
PKGS+=("${extra[@]}")
mapfile -t listed < <(sed -e 's/#.*//' "$CFG/packages.txt" | tr -s '[:space:]' '\n' | grep -v '^$')
PKGS+=("${listed[@]}")
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | awk 'NF && !seen[$0]++')

say "Checking that all ${#PKGS[@]} packages exist in the repositories..."
# Resolve against an EMPTY local database (like pacstrap does), not the live system's,
# so conflicts with packages on the ISO cannot cause false alarms.
mkdir -p "$WORK/pacdb/local"
ln -sfn /var/lib/pacman/sync "$WORK/pacdb/sync"
if ! pacman -Sp --noconfirm --dbpath "$WORK/pacdb" --print-format '%n' "${PKGS[@]}" >/dev/null; then
  die "Some packages in packages.txt / EXTRA_PACKAGES / KERNELS do not exist (see the error above). Nothing has been erased."
fi

# ---------------------------------------------------------------- 5. choose and confirm the target disk
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

# Blank = no partitions and no filesystem/partition-table signature on the disk.
disk_is_blank() {
  [[ -z $(wipefs --noheadings "$1" 2>/dev/null) ]] && (( $(lsblk -nro NAME "$1" | wc -l) == 1 ))
}

if [[ $TARGET_DISK == auto ]]; then TARGET=$(pick_disk); else TARGET=$(readlink -f "$TARGET_DISK"); fi
[[ -n $TARGET && -b $TARGET ]] || die "No suitable target disk found (need an internal disk of at least 40 GB, or TARGET_DISK is wrong)."
[[ $TARGET != "$USB_DISK" ]] || die "Refusing to install onto the USB stick itself."
[[ $(lsblk -dno TYPE "$TARGET") == disk ]] || die "$TARGET is not a whole disk."

say "PLAN: host '$HOST_NAME', user '$USER_NAME', $ROOT_FS root, kernels: $KERNELS, ${#PKGS[@]} packages"
say "TARGET DISK: $TARGET"
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL "$TARGET"

if ! disk_is_blank "$TARGET" && [[ $NONBLANK_DISK == ask ]]; then
  # Never wipe a disk that holds data on a timer: a stick left in a working machine
  # must not reinstall it. Someone has to be at the keyboard.
  printf '\n\033[1;33m!!! %s ALREADY HOLDS PARTITIONS OR A FILESYSTEM (see above) !!!\033[0m\n' "$TARGET"
  echo "If the stick was left in by mistake: remove it and reboot, or just press Enter."
  read -r -p "Type YES (capitals) to ERASE $TARGET and install: " answer
  [[ $answer == YES ]] || die "Not confirmed, nothing was erased."
elif (( CONFIRM_SECONDS > 0 )); then
  printf '\n\033[1;33m!!! EVERYTHING ON %s WILL BE ERASED !!!\033[0m\n' "$TARGET"
  echo "Press any key to ABORT."
  for ((i = CONFIRM_SECONDS; i > 0; i--)); do
    printf '\r  Starting in %2d seconds... ' "$i"
    if read -r -s -n1 -t1 _; then echo; die "Aborted by keypress, nothing was erased."; fi
  done
  echo
fi

# ---------------------------------------------------------------- 6. partition, format, mount
must_mount() { mount "$@" || die "mount $* failed."; }

say "Partitioning $TARGET..."
swapoff -a 2>/dev/null || true
umount -R "$T" 2>/dev/null || true
# Old LVM/RAID on the disk gets auto-activated and keeps it busy
command -v vgchange >/dev/null && vgchange -an >/dev/null 2>&1
command -v mdadm >/dev/null && mdadm --stop --scan >/dev/null 2>&1
wipefs -af "$TARGET" >/dev/null || die "wipefs on $TARGET failed (is it in use?)."
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
  must_mount "$ROOT" "$T"
else
  mkfs.btrfs -f -L archroot "$ROOT" >/dev/null || die "mkfs.btrfs failed."
  mkdir -p /mnt/btrfs-top
  must_mount "$ROOT" /mnt/btrfs-top
  for sv in @ @home @log @pkg @.snapshots; do
    btrfs subvolume create "/mnt/btrfs-top/$sv" >/dev/null || die "Creating btrfs subvolume $sv failed."
  done
  umount /mnt/btrfs-top || die "Could not unmount the btrfs top level."

  OPTS="noatime,compress=zstd:3"
  must_mount -o "$OPTS,subvol=@" "$ROOT" "$T"
  mkdir -p "$T"/{home,var/log,var/cache/pacman/pkg,.snapshots}
  must_mount -o "$OPTS,subvol=@home"       "$ROOT" "$T/home"
  must_mount -o "$OPTS,subvol=@log"        "$ROOT" "$T/var/log"
  must_mount -o "$OPTS,subvol=@pkg"        "$ROOT" "$T/var/cache/pacman/pkg"
  must_mount -o "$OPTS,subvol=@.snapshots" "$ROOT" "$T/.snapshots"
fi
mkdir -p "$T/boot"
must_mount -o fmask=0077,dmask=0077 "$ESP" "$T/boot"   # root-only, as bootctl expects

# If anything above silently did not happen, the kernel would land in the wrong place
# and the machine would not boot. Check before spending 15 minutes installing.
mountpoint -q "$T" || die "$T is not a mount point."
[[ $(findmnt -no FSTYPE "$T/boot") == vfat ]] || die "The EFI partition is not mounted at $T/boot."

# ---------------------------------------------------------------- 7. install packages
say "Installing ${#PKGS[@]} packages with pacstrap. This takes a while (downloads a few GB)..."
installed=0
for attempt in 1 2; do
  if pacstrap -K "$T" "${PKGS[@]}"; then installed=1; break; fi
  warn "pacstrap attempt $attempt failed (often a mirror hiccup)."
  sleep 10
done
(( installed )) || die "pacstrap failed twice. See the log for the failing package or mirror."

in_target() { arch-chroot "$T" "$@"; }
has_unit()  { [[ -e $T/usr/lib/systemd/system/$1 ]]; }

# ---------------------------------------------------------------- 8. configure the system
say "Configuring the system..."

# fstab. genfstab pins btrfs subvolumes by id as well as name; drop the id so
# snapshot rollbacks (which replace a subvolume) still mount.
genfstab -U "$T" >> "$T/etc/fstab" || die "genfstab failed."
sed -i -e 's/subvolid=[0-9]*,//g' -e 's/,subvolid=[0-9]*//g' "$T/etc/fstab"
grep -q '[[:space:]]/boot[[:space:]]' "$T/etc/fstab" || die "fstab has no /boot entry."

# time, locale, keyboard, hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$T/etc/localtime"
in_target hwclock --systohc || warn "hwclock --systohc failed."
sed -i "s/^#\(${LOCALE} \)/\1/" "$T/etc/locale.gen"
grep -q "^${LOCALE} " "$T/etc/locale.gen" || die "LOCALE '$LOCALE' is not in /etc/locale.gen."
in_target locale-gen >/dev/null || die "locale-gen failed."
echo "LANG=$LOCALE" > "$T/etc/locale.conf"
echo "KEYMAP=$KEYMAP" > "$T/etc/vconsole.conf"
if [[ -n $X11_KEYMAP ]]; then
  mkdir -p "$T/etc/X11/xorg.conf.d"
  cat > "$T/etc/X11/xorg.conf.d/00-keyboard.conf" <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$X11_KEYMAP"
EndSection
EOF
fi
echo "$HOST_NAME" > "$T/etc/hostname"
cat > "$T/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOF

# swap on zram
cat > "$T/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

# user, sudo, root
in_target useradd -m -G wheel -s /bin/bash -c "$REAL_NAME" "$USER_NAME" || die "useradd $USER_NAME failed."
printf '%s:%s\n' "$USER_NAME" "$PASSWORD_HASH" | in_target chpasswd -e || die "Setting the password failed."
echo '%wheel ALL=(ALL:ALL) ALL' > "$T/etc/sudoers.d/10-wheel"
chmod 440 "$T/etc/sudoers.d/10-wheel"
in_target visudo -cf /etc/sudoers.d/10-wheel >/dev/null || die "The sudoers drop-in is invalid."
if [[ $LOCK_ROOT == 1 ]]; then in_target passwd -l root >/dev/null || die "Locking root failed."; fi

# Wi-Fi profile for the installed system (NetworkManager keyfile, root-only)
if [[ -n $WIFI_SSID ]]; then
  nm_dir=$T/etc/NetworkManager/system-connections
  install -d -m 700 "$nm_dir"
  ( umask 077
    {
      printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' \
        "${WIFI_SSID//\\/\\\\}" "$(cat /proc/sys/kernel/random/uuid)"
      printf '[wifi]\nmode=infrastructure\nssid=%s\n' "${WIFI_SSID//\\/\\\\}"
      [[ $WIFI_HIDDEN == 1 ]] && printf 'hidden=true\n'
      printf '\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n' "${WIFI_PSK//\\/\\\\}"
      printf '\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } > "$nm_dir/autoinstall-wifi.nmconnection" )
  chmod 600 "$nm_dir/autoinstall-wifi.nmconnection"
fi

# SSH: authorized keys, and key-only login when a key was installed
if [[ $ENABLE_SSH == 1 ]]; then
  keys=""
  if [[ -n $SSH_KEYS_URL ]]; then
    if fetched=$(curl -fsSL --max-time 20 "$SSH_KEYS_URL"); then
      keys+="$fetched"$'\n'
    else
      warn "Could not fetch SSH keys from $SSH_KEYS_URL."
    fi
  fi
  keys+="$SSH_AUTHORIZED_KEYS"
  keys=$(grep -E '^(ssh-|ecdsa-|sk-)' <<<"$keys" || true)
  if [[ -n $keys ]]; then
    ssh_dir=$T/home/$USER_NAME/.ssh
    install -d -m 700 "$ssh_dir"
    printf '%s\n' "$keys" > "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    in_target chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh" || die "chown of ~/.ssh failed."
    say "Installed $(wc -l <<<"$keys") SSH key(s) for $USER_NAME."
  fi
  if [[ $SSH_PASSWORD_AUTH == 0 ]]; then
    if [[ -n $keys ]]; then
      grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' "$T/etc/ssh/sshd_config" \
        || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$T/etc/ssh/sshd_config"
      install -d -m 755 "$T/etc/ssh/sshd_config.d"
      printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' \
        > "$T/etc/ssh/sshd_config.d/10-autoinstall.conf"
    else
      warn "No SSH key could be installed, so SSH password login stays ON."
    fi
  fi
fi

# First-boot hook: hand over to the config (part 2). The installer knows only how
# to fetch the repo and which script to run; what that script does is the repo's
# business. The checkout stays at /opt/llangvilla for later re-runs.
if [[ -n $CONFIG_REPO_URL ]]; then
  install -d "$T/usr/local/lib/llangvilla"
  {
    echo '#!/bin/bash'
    echo '# Written by installer/install.sh. Run once by llangvilla-firstboot.service.'
    echo 'set -euo pipefail'
    printf 'url=%q branch=%q entry=%q dir=/opt/llangvilla\n' \
      "$CONFIG_REPO_URL" "$CONFIG_REPO_BRANCH" "$CONFIG_ENTRYPOINT"
    cat <<'EOF'
if [[ ! -d $dir/.git ]]; then
  rm -rf "$dir"
  git clone ${branch:+--branch "$branch"} "$url" "$dir"
fi
exec bash "$dir/$entry"
EOF
  } > "$T/usr/local/lib/llangvilla/firstboot.sh"
  chmod 755 "$T/usr/local/lib/llangvilla/firstboot.sh"

  unit_before="" unit_reboot="" unit_extra=""
  if [[ $FIRSTBOOT_BEFORE_LOGIN == 1 ]]; then
    # Run to completion BEFORE the login screen (SDDM) starts. A failure does not
    # block SDDM; the unit simply tries again on the next boot.
    unit_before="Before=display-manager.service"
    unit_extra=$'TimeoutStartSec=1800\nStandardOutput=journal+console\nStandardError=journal+console'
  else
    # Run in the background while the login screen is already showing; retry every 60 s.
    unit_extra=$'Restart=on-failure\nRestartSec=60'
  fi
  # Reboot once after a SUCCESSFUL run. The done-marker is written first, so this can never loop.
  [[ $FIRSTBOOT_REBOOT_AFTER == 1 ]] && unit_reboot="ExecStartPost=/usr/bin/systemctl reboot --no-block"
  cat > "$T/etc/systemd/system/llangvilla-firstboot.service" <<EOF
[Unit]
Description=First-boot hand-over to the config repo
After=network-online.target
Wants=network-online.target
$unit_before
ConditionPathExists=!/var/lib/llangvilla/firstboot.done

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/local/lib/llangvilla/firstboot.sh
ExecStartPost=/usr/bin/mkdir -p /var/lib/llangvilla
ExecStartPost=/usr/bin/touch /var/lib/llangvilla/firstboot.done
$unit_reboot
$unit_extra

[Install]
WantedBy=multi-user.target
EOF
fi

# Services
UNITS=(NetworkManager.service systemd-timesyncd.service fstrim.timer systemd-boot-update.service)
[[ $ENABLE_SSH == 1 ]] && UNITS+=(sshd.service)
[[ -n $CONFIG_REPO_URL ]] && UNITS+=(NetworkManager-wait-online.service llangvilla-firstboot.service)
for u in sddm.service bluetooth.service; do has_unit "$u" && UNITS+=("$u"); done
in_target systemctl enable "${UNITS[@]}" || die "Enabling services failed: ${UNITS[*]}"

# ---------------------------------------------------------------- 9. bootloader (systemd-boot)
say "Installing systemd-boot..."
# Without writable EFI variables (some firmware, some VMs) fall back to the
# removable-media path \EFI\BOOT\BOOTX64.EFI, which firmware boots anyway.
in_target bootctl install || in_target bootctl --no-variables install || die "bootctl install failed."

ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
[[ -n $ROOT_UUID ]] || die "Could not read the root filesystem's UUID."
options="root=UUID=$ROOT_UUID rw"
[[ $ROOT_FS == btrfs ]] && options+=" rootflags=subvol=@"

# Current mkinitcpio embeds microcode via its 'microcode' hook; older configs need an initrd line.
ucode_line=""
if [[ -n $UCODE ]] && ! grep -Eq '^HOOKS=.*\bmicrocode\b' "$T/etc/mkinitcpio.conf"; then
  ucode_line="initrd  /$UCODE.img"
fi

mkdir -p "$T/boot/loader/entries"
for k in "${kernels[@]}"; do
  [[ -f $T/boot/vmlinuz-$k ]] || die "Kernel $k did not install a /boot/vmlinuz-$k."
  {
    echo "title   Arch Linux ($k)"
    echo "linux   /vmlinuz-$k"
    [[ -n $ucode_line ]] && echo "$ucode_line"
    echo "initrd  /initramfs-$k.img"
    echo "options $options"
  } > "$T/boot/loader/entries/arch-$k.conf"
done
cat > "$T/boot/loader/loader.conf" <<EOF
default arch-${kernels[0]}.conf
timeout 3
console-mode max
editor no
EOF

# Rebuild the initramfs now that vconsole.conf etc. exist.
in_target mkinitcpio -P || die "mkinitcpio failed."
for k in "${kernels[@]}"; do
  [[ -f $T/boot/initramfs-$k.img ]] || die "No initramfs for kernel $k."
done

# ---------------------------------------------------------------- 10. finish
sync
say "INSTALL COMPLETE."
save_logs "OK"
umount -R "$T" 2>/dev/null || true
umount "$USB_MNT" 2>/dev/null || true
say "Powering off in 15 seconds. REMOVE THE USB STICK, then power the machine on."
sleep 15
systemctl poweroff
