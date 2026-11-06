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
: "${ANSIBLE_PULL_URL:=}" "${ANSIBLE_PLAYBOOK:=ansible/site.yml}" "${LOCK_ROOT:=1}" "${ANSIBLE_BEFORE_LOGIN:=1}" "${ANSIBLE_REBOOT_AFTER:=1}"
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

# 5d. First-boot ansible-pull (based on your Ubuntu late-commands unit)
if [[ -n $ANSIBLE_PULL_URL ]]; then
  if [[ $ANSIBLE_BEFORE_LOGIN == 1 ]]; then
    # Run to completion BEFORE the login screen (SDDM) starts. A failure does not
    # block SDDM; the unit simply tries again on the next boot.
    UNIT_BEFORE="Before=display-manager.service"
    UNIT_SERVICE_EXTRA=$'TimeoutStartSec=1800\nStandardOutput=journal+console\nStandardError=journal+console'
  else
    # Run in the background while the login screen is already showing; retry every 60 s.
    UNIT_BEFORE=""
    UNIT_SERVICE_EXTRA=$'Restart=on-failure\nRestartSec=60'
  fi
  # Reboot once after a SUCCESSFUL run. The done-marker is written first, so this can never loop.
  UNIT_REBOOT=""
  [[ $ANSIBLE_REBOOT_AFTER == 1 ]] && UNIT_REBOOT="ExecStartPost=/usr/bin/systemctl reboot --no-block"
  CMDS+=("$(cat <<EOF
cat > /etc/systemd/system/ansible-pull-firstboot.service <<'UNITEOF'
[Unit]
Description=Initial ansible-pull
After=network-online.target
Wants=network-online.target
$UNIT_BEFORE
ConditionPathExists=!/var/lib/ansible-pull-firstboot.done

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/bin/ansible-pull -U $ANSIBLE_PULL_URL $ANSIBLE_PLAYBOOK
ExecStartPost=/usr/bin/touch /var/lib/ansible-pull-firstboot.done
$UNIT_REBOOT
$UNIT_SERVICE_EXTRA

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
