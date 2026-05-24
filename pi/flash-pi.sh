#!/bin/bash
set -euo pipefail

# =============================================================================
# flash-pi.sh — Fully scripted Raspberry Pi SD card prep for Mac
#
# Usage:
#   ./flash-pi.sh [options]
#
# Options:
#   --disk        /dev/diskN     SD card disk (auto-detected if omitted)
#   --password    secret         Password (prompted if omitted)
#   --bootstrap   https://...    URL to bootstrap.sh to run on first boot
#   --help
#
# Examples:
#   # Minimal (auto-detect disk, prompt for password):
#   ./flash-pi.sh
#
#   # Full with WiFi and bootstrap:
#   ./flash-pi.sh \
#     --password secret \
#     --bootstrap https://raw.githubusercontent.com/you/dotfiles/main/bootstrap.sh
# =============================================================================

# --- Defaults ----------------------------------------------------------------
PI_HOSTNAME="pi"
PI_USERNAME="cqkh42"
PI_PASSWORD=""
WIFI_SSID="EE-X6PRG2"
WIFI_PASS="d9Qn3cKvxV9KrR7P"
WIFI_COUNTRY="GB"
BOOTSTRAP_URL=""
TARGET_DISK=""

IMAGE_URL="https://downloads.raspberrypi.com/raspios_full_arm64/images/raspios_full_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-full.img.xz"
IMAGE_CACHE="$HOME/.cache/pi-images"

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# bash 3.2-compatible lowercase (macOS ships bash 3.2)
lowercase() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

confirm_or_abort() {
  # Usage: confirm_or_abort "Your prompt text"
  local prompt="$1"
  local reply
  read -rp "$prompt [y/N]: " reply
  if [[ "$(lowercase "$reply")" != "y" ]]; then
    echo
    warn "Aborted by user."
    exit 0
  fi
}

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)         TARGET_DISK="$2";    shift 2 ;;
    --password)     PI_PASSWORD="$2";    shift 2 ;;
    --bootstrap)    BOOTSTRAP_URL="$2";  shift 2 ;;
    --help)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) error "Unknown option: $1. Run with --help for usage." ;;
  esac
done

# --- Checks ------------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  error "This script is designed for macOS."
fi

if ! command -v openssl &>/dev/null; then
  error "openssl is required. Install via: brew install openssl"
fi

# --- Password ----------------------------------------------------------------
if [[ -z "$PI_PASSWORD" ]]; then
  echo -n "Enter password for Pi user '$PI_USERNAME': "
  read -rs PI_PASSWORD
  echo
  if [[ -z "$PI_PASSWORD" ]]; then
    error "Password cannot be empty."
  fi
fi

HASHED_PASSWORD=$(openssl passwd -6 "$PI_PASSWORD")

# --- Disk auto-detection -----------------------------------------------------
detect_disk() {
  info "Detecting SD card..."

  # Try physical external first, fall back to any external (some readers
  # don't register as "physical" on macOS)
  local candidates
  candidates=$(diskutil list external physical 2>/dev/null | grep '^/dev/disk' | awk '{print $1}')

  if [[ -z "$candidates" ]]; then
    candidates=$(diskutil list external 2>/dev/null | grep '^/dev/disk' | awk '{print $1}')
  fi

  if [[ -z "$candidates" ]]; then
    echo
    echo -e "${RED}[ERROR]${NC} No external disks found." >&2
    echo >&2
    echo "  Possible reasons:" >&2
    echo "    • SD card not inserted" >&2
    echo "    • Card reader not recognised by macOS" >&2
    echo "    • Disk already unmounted or sleeping" >&2
    echo >&2
    echo "  To diagnose, run:" >&2
    echo "    diskutil list" >&2
    echo >&2
    echo "  Then re-run with the disk specified explicitly:" >&2
    echo "    $0 --disk /dev/diskN" >&2
    echo >&2
    exit 1
  fi

  local count
  count=$(echo "$candidates" | wc -l | tr -d ' ')

  if [[ "$count" -eq 1 ]]; then
    TARGET_DISK=$(echo "$candidates" | head -1)
    warn "Auto-detected disk: $TARGET_DISK"
    diskutil list "$TARGET_DISK"
    echo
    confirm_or_abort "Is this the correct SD card? This will ERASE it."
  else
    echo "Multiple external disks found:"
    echo "$candidates" | nl
    echo
    diskutil list external
    echo
    read -rp "Enter the disk to use (e.g. /dev/disk2): " TARGET_DISK
    [[ "$TARGET_DISK" =~ ^/dev/disk[0-9]+$ ]] || error "Invalid disk: $TARGET_DISK"
    echo
    confirm_or_abort "Confirm ERASE of $TARGET_DISK?"
  fi
}

if [[ -z "$TARGET_DISK" ]]; then
  detect_disk
fi

# --- Image acquisition -------------------------------------------------------
get_image() {
  mkdir -p "$IMAGE_CACHE"
  local cached_xz="$IMAGE_CACHE/raspios-latest.img.xz"
  local cached_img="$IMAGE_CACHE/raspios-latest.img"

  if [[ -f "$cached_img" ]]; then
    info "Using cached image: $cached_img"
    IMAGE_PATH="$cached_img"
    return
  fi

  if [[ ! -f "$cached_xz" ]]; then
    info "Downloading Raspberry Pi OS (arm64)..."
    curl -L --progress-bar -o "$cached_xz" "$IMAGE_URL"
  else
    info "Using cached compressed image: $cached_xz"
  fi

  info "Decompressing image..."
  xz -dk "$cached_xz"
  IMAGE_PATH="$cached_img"
}

# --- Flash -------------------------------------------------------------------
flash_image() {
  info "Unmounting $TARGET_DISK..."
  diskutil unmountDisk "$TARGET_DISK" || true

  local raw_disk="${TARGET_DISK/disk/rdisk}"
  info "Flashing $IMAGE_PATH → $raw_disk (this may take a few minutes)..."
  info "macOS may now prompt for your Mac password (needed for disk write access)..."
  sudo dd if="$IMAGE_PATH" of="$raw_disk" bs=4M status=progress 2>&1 || \
    sudo dd if="$IMAGE_PATH" of="$raw_disk" bs=4M  # fallback without status on older dd
  sync
  success "Flash complete."

  info "Re-mounting partitions..."
  sleep 2
  diskutil mountDisk "$TARGET_DISK" || true
  sleep 2
}

# --- Boot partition config ---------------------------------------------------
configure_boot() {
  # Find the boot partition mount point
  local boot_vol=""
  for candidate in /Volumes/bootfs /Volumes/boot /Volumes/BOOT; do
    if [[ -d "$candidate" ]]; then
      boot_vol="$candidate"
      break
    fi
  done

  if [[ -z "$boot_vol" ]]; then
    # Try mounting explicitly
    diskutil mount "${TARGET_DISK}s1" 2>/dev/null || true
    sleep 1
    for candidate in /Volumes/bootfs /Volumes/boot /Volumes/BOOT; do
      if [[ -d "$candidate" ]]; then
        boot_vol="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$boot_vol" ]]; then
    error "Could not find boot partition. Try mounting manually and re-run with --skip-flash."
  fi

  info "Configuring boot partition at $boot_vol..."

  # Enable SSH
  touch "$boot_vol/ssh"
  success "SSH enabled."

  # Set username and hashed password
  echo "${PI_USERNAME}:${HASHED_PASSWORD}" > "$boot_vol/userconf.txt"
  success "User '$PI_USERNAME' configured."

  # Set hostname via cmdline.txt
  if [[ -f "$boot_vol/cmdline.txt" ]]; then
    sed -i '' "s/$/ systemd.hostname=${PI_HOSTNAME}/" "$boot_vol/cmdline.txt"
    success "Hostname set to '$PI_HOSTNAME'."
  fi

  # WiFi config
  if [[ -n "$WIFI_SSID" ]]; then
    cat > "$boot_vol/wpa_supplicant.conf" <<EOF
country=${WIFI_COUNTRY}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
    key_mgmt=WPA-PSK
}
EOF
    success "WiFi configured for SSID '$WIFI_SSID'."
  else
    warn "No WiFi configured. Pi will need an ethernet connection."
  fi

  # Bootstrap script
  if [[ -n "$BOOTSTRAP_URL" ]]; then
    inject_bootstrap "$boot_vol"
  fi

  success "Boot partition configured."
}

# --- Bootstrap injection -----------------------------------------------------
inject_bootstrap() {
  local boot_vol="$1"

  if [[ -f "$boot_vol/firstrun.sh" ]]; then
    info "Injecting bootstrap into existing firstrun.sh..."
    cat >> "$boot_vol/firstrun.sh" <<EOF

# --- Bootstrap injected by flash-pi.sh ---
curl -fsSL "${BOOTSTRAP_URL}" -o /home/${PI_USERNAME}/bootstrap.sh
chmod +x /home/${PI_USERNAME}/bootstrap.sh
sudo -u ${PI_USERNAME} bash /home/${PI_USERNAME}/bootstrap.sh >> /var/log/bootstrap.log 2>&1 &
EOF
  else
    info "Creating bootstrap firstrun.sh..."
    cat > "$boot_vol/firstrun.sh" <<EOF
#!/bin/bash
set -e

# Wait for network
for i in \$(seq 1 30); do
  curl -fsSL --max-time 5 "${BOOTSTRAP_URL}" -o /tmp/bootstrap.sh && break
  sleep 2
done

if [[ -f /tmp/bootstrap.sh ]]; then
  chmod +x /tmp/bootstrap.sh
  bash /tmp/bootstrap.sh >> /var/log/bootstrap.log 2>&1

  # Remove this service so it doesn't run again
  rm -f /etc/systemd/system/firstrun.service
  systemctl daemon-reload
fi
EOF
    chmod +x "$boot_vol/firstrun.sh"

    if [[ -f "$boot_vol/cmdline.txt" ]]; then
      sed -i '' "s|$| systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot|" \
        "$boot_vol/cmdline.txt"
    fi
  fi

  success "Bootstrap URL configured: $BOOTSTRAP_URL"
}

# --- Eject -------------------------------------------------------------------
eject_disk() {
  info "Ejecting $TARGET_DISK..."
  diskutil eject "$TARGET_DISK" || true
  success "SD card ejected. Safe to remove."
}

# --- Main --------------------------------------------------------------------
echo
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  Pi Image Flasher${NC}"
echo -e "${CYAN}================================================${NC}"
echo "  Hostname:   $PI_HOSTNAME"
echo "  Username:   $PI_USERNAME"
echo "  WiFi:       ${WIFI_SSID:-"(none — use ethernet)"}"
echo "  Bootstrap:  ${BOOTSTRAP_URL:-"(none)"}"
[[ -n "$TARGET_DISK" ]] && echo "  Disk:       $TARGET_DISK"
echo

get_image
flash_image
configure_boot
eject_disk

echo
success "Done! Insert SD card into Pi and power on."
[[ -n "$BOOTSTRAP_URL" ]] && info "Bootstrap will run automatically on first boot. Logs at /var/log/bootstrap.log"
info "SSH in with: ssh ${PI_USERNAME}@${PI_HOSTNAME}.local"
echo