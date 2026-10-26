#!/usr/bin/env bash
# Prepares autoinstall/README.md sections 2-3:
#   - downloads the Ubuntu desktop ISO (verified against Ubuntu's SHA256SUMS)
#   - downloads + unpacks Ventoy (verified against a pinned SHA-256)
#   - optionally builds the whole stick (ERASES it): installs Ventoy, mounts it,
#     then copies the ISO, ventoy.json and the raw user-data template onto it
#     (README sections 3-4). Filling in the placeholders (section 5) is still manual.
#
# Usage (disk is optional; without it the script only downloads/unpacks):
#   bash -c "$(curl -fsSL "$URL")" _ /dev/sdb          # "_" fills $0, so the disk is $1
#   DISK=/dev/sdb bash -c "$(curl -fsSL "$URL")"       # or via the environment
#   ... add --force to reinstall over an existing Ventoy (Ventoy2Disk.sh -I)
#
# Everything is cached in $XDG_CACHE_HOME/llangvilla (default ~/.cache/llangvilla).
# Logs go to stderr; the only stdout is two shell-evaluable lines at the very end:
#   eval "$(bash -c "$(curl -fsSL "$URL")" _ /dev/sdb)"   # sets $ISO, $VENTOY_DIR and $V
# ($V is the mount point of the freshly made Ventoy partition, if a disk was given.
#  After installing, the script re-reads the partition table and mounts the stick,
#  so there is no need to unplug and replug it.)
set -euo pipefail

# Send all stdout (ours and every child process's) to stderr, keeping the real
# stdout on fd 3 for the final result. This stops Ventoy's output from being
# captured by an `eval "$(...)"` wrapper.
exec 3>&1 1>&2

UBUNTU_VERSION="26.04.1"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
ISO_BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"

# Ventoy publishes its SHA-256 in the release notes, so it is pinned here.
# To upgrade: bump the version and paste the new linux.tar.gz hash from
# https://github.com/ventoy/Ventoy/releases
VENTOY_VERSION="1.1.16"
VENTOY_SHA256="a9ffd7bd5e26df486cafff924b8dbcb6caae20cbe2b179a009fe59ae740c7572"
VENTOY_TARBALL="ventoy-${VENTOY_VERSION}-linux.tar.gz"
VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${VENTOY_TARBALL}"

USER_DATA_URL="https://raw.githubusercontent.com/cqkh42/llangvilla/refs/heads/main/autoinstall/user-data"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/llangvilla"
ISO_PATH="${CACHE_DIR}/${ISO_NAME}"
VENTOY_TARBALL_PATH="${CACHE_DIR}/${VENTOY_TARBALL}"
VENTOY_DIR="${CACHE_DIR}/ventoy-${VENTOY_VERSION}"

# ---------- pretty logging (colour only when stderr is a terminal) ----------
if [[ -t 2 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'
  YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*"; exit 1; }

usage() {
  cat <<USAGE
Usage: fetch-ubuntu-iso.sh [--force] [DISK]

  DISK     whole USB disk to install Ventoy on, e.g. /dev/sdb (or set \$DISK).
           Without it the script only downloads and unpacks.
  --force  reinstall over an existing Ventoy (Ventoy2Disk.sh -I)

Find your stick with:
  lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN=="usb"'
USAGE
}

# ---------- arguments ----------
DISK="${DISK:-}"
VENTOY_FLAG="-i"
VENTOY_MOUNT=""
VENTOY_PART=""
STICK_POPULATED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) VENTOY_FLAG="-I" ;;
    -h|--help)  usage; exit 0 ;;
    -*)         usage; die "Unknown option: $1" ;;
    *)          DISK="$1" ;;
  esac
  shift
done
if [[ -n "$DISK" && "$DISK" != /dev/* ]]; then DISK="/dev/${DISK}"; fi

# ---------- helpers ----------
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# fetch_verified <label> <url> <dest> <expected-sha256>
# Skips the download if <dest> already exists with the right checksum.
fetch_verified() {
  local label=$1 url=$2 dest=$3 expected=$4 part="$3.part"

  if [[ -f "$dest" ]]; then
    info "Found cached ${label} ($(du -h "$dest" | cut -f1)), verifying..."
    if [[ "$(sha256_of "$dest")" == "$expected" ]]; then
      ok "Checksum matches, skipping download"
      return 0
    fi
    warn "Cached ${label} is corrupt or outdated, re-downloading"
    rm -f "$dest"
  else
    info "${label} not cached yet"
  fi

  if [[ -f "$part" ]]; then info "Resuming partial download"; fi
  info "From: ${url}"
  curl -fL --retry 3 -C - --progress-bar -o "$part" "$url" \
    || die "Download failed (re-run to resume)"

  info "Verifying download..."
  if [[ "$(sha256_of "$part")" != "$expected" ]]; then
    rm -f "$part"
    die "Checksum mismatch, deleted the bad download. Re-run to try again"
  fi
  mv "$part" "$dest"
  ok "Downloaded and verified ${label}"
}

# Light sanity checks that the target is a whole, USB-attached, non-system disk.
validate_disk() {
  local disk=$1 type tran size_bytes
  [[ -b "$disk" ]] || die "${disk} is not a block device"
  type=$(lsblk -dnro TYPE "$disk" 2>/dev/null) || die "lsblk could not inspect ${disk}"
  [[ "$type" == "disk" ]] \
    || die "${disk} is a '${type}', not a whole disk (use e.g. /dev/sdb, not /dev/sdb1)"
  tran=$(lsblk -dnro TRAN "$disk" 2>/dev/null) || die "lsblk could not inspect ${disk}"
  [[ "$tran" == "usb" ]] \
    || die "${disk} is not attached over USB (transport: ${tran:-unknown}), refusing"
  if lsblk -nro MOUNTPOINT "$disk" | grep -qx '/'; then
    die "${disk} holds the running system, refusing"
  fi
  size_bytes=$(lsblk -dnbo SIZE "$disk" 2>/dev/null) || die "lsblk could not inspect ${disk}"
  if (( size_bytes > 256 * 1000 * 1000 * 1000 )); then
    warn "${disk} is larger than 256 GB, which is unusual for a USB stick. Double-check it"
  fi
  ok "${disk} looks like a USB disk: $(lsblk -dn -o SIZE,MODEL "$disk" | tr -s ' ')"
}

# Unmount every mounted partition of the disk (desktops auto-mount USB sticks).
unmount_disk() {
  local disk=$1 part found=0
  while read -r part; do
    found=1
    info "Unmounting ${part}"
    sudo umount "$part" || die "Could not unmount ${part} (is something using it?)"
  done < <(lsblk -nrpo NAME,MOUNTPOINT "$disk" | awk 'NF >= 2 {print $1}')
  if (( found == 0 )); then info "Nothing mounted from ${disk}"; fi
}

# Show what is on the disk and make the user type its path to proceed.
confirm_wipe() {
  local disk=$1 answer
  step "Confirm: this will ERASE ${disk}"
  lsblk -p -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk"
  printf '\n  %sEverything on this disk will be lost.%s\n' "$RED" "$RESET"
  printf '  Type the device path (%s) to continue: ' "$disk"
  if ! read -r answer </dev/tty; then die "No terminal available to confirm"; fi
  [[ "$answer" == "$disk" ]] || die "Input did not match, nothing was changed"
}

# Re-read the partition table and mount the big Ventoy partition, so the next
# step works without unplugging the stick. Sets VENTOY_MOUNT on success.
mount_ventoy() {
  local disk=$1 part="" mnt="" i
  sync
  sudo partprobe "$disk" || warn "partprobe failed, carrying on"
  udevadm settle || true

  # Find this disk's Ventoy partition (give udev a few seconds to create it)
  for i in {1..20}; do
    part=$(lsblk -nrpo NAME,LABEL "$disk" | awk '$2 == "Ventoy" {print $1}')
    part=${part%%$'\n'*}
    if [[ -n "$part" ]]; then break; fi
    sleep 0.5
  done
  [[ -n "$part" ]] || { warn "Ventoy partition did not appear"; return 1; }

  # The desktop may already have auto-mounted it
  mnt=$(findmnt -n -o TARGET -S "$part" 2>/dev/null || true)
  mnt=${mnt%%$'\n'*}
  if [[ -z "$mnt" ]]; then
    command -v udisksctl >/dev/null || { warn "udisksctl not found"; return 1; }
    info "Mounting ${part}"
    udisksctl mount -b "$part" >/dev/null || { warn "Could not mount ${part}"; return 1; }
    mnt=$(findmnt -n -o TARGET -S "$part" 2>/dev/null || true)
    mnt=${mnt%%$'\n'*}
  fi
  [[ -n "$mnt" ]] || { warn "Could not work out where ${part} is mounted"; return 1; }

  VENTOY_PART=$part
  VENTOY_MOUNT=$mnt
  ok "Ventoy partition ${part} mounted at ${mnt}"
}

# README section 4: put the ISO, ventoy.json and the raw user-data on the stick.
populate_stick() {
  local v=$1
  local iso_dest="${v}/ISO/ubuntu-desktop.iso"
  local ud_dest="${v}/ventoy/script/user-data"
  mkdir -p "${v}/ISO" "${v}/ventoy/script"

  info "Copying ISO ($(du -h "$ISO_PATH" | cut -f1), this can take a few minutes)..."
  if command -v rsync >/dev/null; then
    rsync --no-perms --no-owner --no-group --info=progress2 "$ISO_PATH" "$iso_dest" \
      || die "Copying the ISO to the stick failed"
  else
    cp "$ISO_PATH" "$iso_dest" || die "Copying the ISO to the stick failed"
  fi
  info "Flushing to the stick..."
  sync
  [[ "$(stat -c %s "$iso_dest")" == "$(stat -c %s "$ISO_PATH")" ]] \
    || die "Copied ISO is a different size from the original"
  ok "ISO copied to ${iso_dest}"

  info "Fetching the user-data template"
  curl -fsSL "$USER_DATA_URL" -o "$ud_dest" || die "Could not download ${USER_DATA_URL}"
  ok "user-data copied to ${ud_dest}"

  cat > "${v}/ventoy/ventoy.json" <<'JSON'
{
  "auto_install": [
    {
      "image": "/ISO/ubuntu-desktop.iso",
      "template": "/ventoy/script/user-data"
    }
  ]
}
JSON
  ok "ventoy.json written"
  STICK_POPULATED=1
}

install_ventoy() {
  local disk=$1
  confirm_wipe "$disk"
  step "Installing Ventoy on ${disk}"
  unmount_disk "$disk"
  info "Running Ventoy2Disk.sh ${VENTOY_FLAG} ${disk} (Ventoy will ask for its own y/n confirmations)"
  (cd "$VENTOY_DIR" && sudo sh Ventoy2Disk.sh "$VENTOY_FLAG" "$disk") \
    || die "Ventoy install failed. If the stick already has Ventoy, re-run with --force"
  ok "Ventoy installed"

  step "Mounting the stick"
  if mount_ventoy "$disk"; then
    step "Copying files onto the stick"
    populate_stick "$VENTOY_MOUNT"
  else
    warn "Could not mount automatically. Unplug and replug the stick, then do README section 4 by hand"
  fi
}

# ---------- preflight ----------
step "Preflight"
required=(curl sha256sum awk tar)
if [[ -n "$DISK" ]]; then required+=(lsblk sudo umount); fi
for cmd in "${required[@]}"; do
  command -v "$cmd" >/dev/null || die "Missing required command: ${cmd}"
done
mkdir -p "$CACHE_DIR"
info "Cache directory: ${CACHE_DIR}"
if [[ -n "$DISK" ]]; then
  info "Target disk: ${DISK}"
  validate_disk "$DISK"   # fail fast, before any big downloads
else
  info "No disk given, will only download and unpack"
fi

# ---------- Ubuntu ISO ----------
step "Ubuntu ${UBUNTU_VERSION} desktop ISO"
iso_sha256=$(curl -fsSL "${ISO_BASE_URL}/SHA256SUMS" \
  | awk -v f="$ISO_NAME" '$2 == f || $2 == "*" f {print $1}') \
  || die "Could not download ${ISO_BASE_URL}/SHA256SUMS"
[[ -n "$iso_sha256" ]] || die "No checksum for ${ISO_NAME} in SHA256SUMS"
info "Official SHA-256: ${iso_sha256}"
fetch_verified "Ubuntu ISO" "${ISO_BASE_URL}/${ISO_NAME}" "$ISO_PATH" "$iso_sha256"

# ---------- Ventoy ----------
step "Ventoy ${VENTOY_VERSION}"
fetch_verified "Ventoy tarball" "$VENTOY_URL" "$VENTOY_TARBALL_PATH" "$VENTOY_SHA256"

step "Unpacking Ventoy"
if [[ -f "${VENTOY_DIR}/Ventoy2Disk.sh" ]]; then
  ok "Already unpacked"
else
  tmp=$(mktemp -d "${CACHE_DIR}/.unpack.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  tar xzf "$VENTOY_TARBALL_PATH" -C "$tmp"
  [[ -d "${tmp}/ventoy-${VENTOY_VERSION}" ]] \
    || die "Tarball did not contain ventoy-${VENTOY_VERSION}/"
  rm -rf "$VENTOY_DIR"
  mv "${tmp}/ventoy-${VENTOY_VERSION}" "$VENTOY_DIR"
  ok "Unpacked to ${VENTOY_DIR}"
fi

# ---------- install onto the stick (optional) ----------
if [[ -n "$DISK" ]]; then install_ventoy "$DISK"; fi

# ---------- summary ----------
step "All done"
ok "ISO:    ${ISO_PATH}"
ok "Ventoy: ${VENTOY_DIR}"
if [[ -n "$VENTOY_MOUNT" ]]; then
  ok "Stick:  ${VENTOY_MOUNT}"
fi
if (( STICK_POPULATED )); then
  ud="${VENTOY_MOUNT}/ventoy/script/user-data"
  left=$(grep -c '__[A-Z_]*__' "$ud" || true)
  warn "${left} lines in user-data still hold placeholders (README section 5):"
  info "  nano \"${ud}\""
  info "  grep -n '__' \"${ud}\"    # must print nothing"
  info "Then flush and unmount:"
  info "  sync && udisksctl unmount -b ${VENTOY_PART}"
elif [[ -z "$DISK" ]]; then
  info "To build the stick, re-run with a disk. Find it with:"
  info "  lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN==\"usb\"'"
fi

printf 'ISO=%q\nVENTOY_DIR=%q\n' "$ISO_PATH" "$VENTOY_DIR" >&3
if [[ -n "$VENTOY_MOUNT" ]]; then printf 'V=%q\n' "$VENTOY_MOUNT" >&3; fi
