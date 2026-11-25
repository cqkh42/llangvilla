#!/usr/bin/env bash
# Builds the zero-touch Arch Linux USB stick (autoinstall/README.md sections 4-6):
#   - builds the custom Arch ISO in an Arch Docker container (build.sh + install.sh),
#     reusing the cached ISO unless install.sh/build.sh changed or --rebuild is given
#   - downloads + unpacks Ventoy (verified against a pinned SHA-256)
#   - optionally builds the stick (ERASES it if Ventoy is not already on it):
#     installs Ventoy, mounts it, then copies the ISO, ventoy.json, the
#     autoinstall.env template and packages.txt onto it.
#     Filling in the autoinstall.env placeholders is still manual; the script
#     then checks it with `install.sh --check`.
#
# Usage (disk is optional; without it the script only builds/downloads):
#   autoinstall/build-usb.sh [--rebuild] [--force] [/dev/sdX]   # from a checkout
#   DISK=/dev/sdb bash -c "$(curl -fsSL "$URL")"                # or straight from GitHub
#   bash -c "$(curl -fsSL "$URL")" _ /dev/sdb                   # "_" fills $0, so the disk is $1
#
# Re-running on a stick that already has Ventoy is safe: Ventoy is kept, the ISO
# is only re-copied if it differs, ventoy.json and autoinstall.env are left alone,
# and packages.txt is refreshed from the repo.
#
# Everything is cached in $XDG_CACHE_HOME/llangvilla (default ~/.cache/llangvilla).
# Logs go to stderr; the only stdout is shell-evaluable lines at the very end:
#   eval "$(autoinstall/build-usb.sh /dev/sdb)"   # sets $ISO, $VENTOY_DIR and $V
# ($V is the mount point of the Ventoy partition, if a disk was given.)
set -euo pipefail

# Send all stdout (ours and every child process's) to stderr, keeping the real
# stdout on fd 3 for the final result. This stops Ventoy's and Docker's output
# from being captured by an `eval "$(...)"` wrapper.
exec 3>&1 1>&2

# Ventoy publishes its SHA-256 in the release notes, so it is pinned here.
# To upgrade: bump the version and paste the new linux.tar.gz hash from
# https://github.com/ventoy/Ventoy/releases
VENTOY_VERSION="1.1.16"
VENTOY_SHA256="a9ffd7bd5e26df486cafff924b8dbcb6caae20cbe2b179a009fe59ae740c7572"
VENTOY_TARBALL="ventoy-${VENTOY_VERSION}-linux.tar.gz"
VENTOY_URL="https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VERSION}/${VENTOY_TARBALL}"

RAW_BASE="https://raw.githubusercontent.com/cqkh42/llangvilla/refs/heads/main/autoinstall"
BUILD_FILES=(build.sh install.sh autoinstall.env.example packages.txt)

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/llangvilla"
BUILD_DIR="${CACHE_DIR}/iso-build"        # mounted at /work in the container
ISO_OUT_DIR="${BUILD_DIR}/out"
ISO_STAMP="${ISO_OUT_DIR}/.sources.sha256"
VENTOY_TARBALL_PATH="${CACHE_DIR}/${VENTOY_TARBALL}"
VENTOY_DIR="${CACHE_DIR}/ventoy-${VENTOY_VERSION}"

STICK_ISO="arch-autoinstall.iso"
STICK_CFG="arch-autoinstall"

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
Usage: build-usb.sh [--rebuild] [--force] [DISK]

  DISK       whole USB disk to build, e.g. /dev/sdb (or set \$DISK).
             Without it the script only builds the ISO and downloads Ventoy.
             If the stick already has Ventoy it is kept (nothing is erased).
  --rebuild  rebuild the Arch ISO even if a cached one is up to date
             (do this about monthly so the ISO's archinstall stays current)
  --force    wipe the stick and reinstall Ventoy (Ventoy2Disk.sh -I)

Find your stick with:
  lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN=="usb"'
USAGE
}

# ---------- arguments ----------
DISK="${DISK:-}"
VENTOY_FLAG="-i"
FORCE=0
REBUILD=0
VENTOY_MOUNT=""
VENTOY_PART=""
STICK_POPULATED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)   FORCE=1; VENTOY_FLAG="-I" ;;
    -r|--rebuild) REBUILD=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           usage; die "Unknown option: $1" ;;
    *)            DISK="$1" ;;
  esac
  shift
done
if [[ -n "$DISK" && "$DISK" != /dev/* ]]; then DISK="/dev/${DISK}"; fi

# Run from a checkout? Then use the scripts next to this one, not GitHub's copy.
SRC_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  candidate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f "${candidate}/build.sh" && -f "${candidate}/install.sh" ]]; then
    SRC_DIR=$candidate
  fi
fi

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

# Copy build.sh, install.sh, the env template and packages.txt into BUILD_DIR, from the
# checkout if we are in one, otherwise from GitHub.
stage_sources() {
  local f
  mkdir -p "$BUILD_DIR"
  for f in "${BUILD_FILES[@]}"; do
    if [[ -n "$SRC_DIR" ]]; then
      cp "${SRC_DIR}/${f}" "${BUILD_DIR}/${f}"
    else
      curl -fsSL "${RAW_BASE}/${f}" -o "${BUILD_DIR}/${f}.new" \
        || { rm -f "${BUILD_DIR}/${f}.new"; die "Could not download ${RAW_BASE}/${f}"; }
      mv -f "${BUILD_DIR}/${f}.new" "${BUILD_DIR}/${f}"
    fi
  done
  if [[ -n "$SRC_DIR" ]]; then
    ok "Using scripts from ${SRC_DIR}"
  else
    ok "Downloaded scripts from GitHub (main)"
  fi
}

# One hash over the files baked into the ISO, so a changed install.sh triggers a rebuild.
sources_hash() {
  (cd "$BUILD_DIR" && sha256sum build.sh install.sh) | sha256sum | awk '{print $1}'
}

latest_iso() {
  local iso
  # shellcheck disable=SC2012  # our own fixed-pattern filenames
  iso=$(ls -1t "${ISO_OUT_DIR}"/arch-autoinstall-*.iso 2>/dev/null | head -n1 || true)
  printf '%s' "$iso"
}

build_iso() {
  local docker=(docker) iso
  command -v docker >/dev/null || die "Docker is needed to build the ISO (README section 2)"
  if ! docker info >/dev/null 2>&1; then docker=(sudo docker); fi

  info "Building in an archlinux:latest container (5-15 minutes, lots of output is normal)"
  rm -f "${ISO_OUT_DIR}"/arch-autoinstall-*.iso
  # mkarchiso needs root inside the container; hand the output back to us afterwards.
  "${docker[@]}" run --rm --privileged --pull=always \
    -v "${BUILD_DIR}":/work archlinux:latest \
    bash -c "bash /work/build.sh && chown -R $(id -u):$(id -g) /work/out" \
    || die "ISO build failed. Read the last lines of output above, then re-run"

  iso=$(latest_iso)
  [[ -n "$iso" ]] || die "Build finished but no ISO appeared in ${ISO_OUT_DIR}"
  sources_hash > "$ISO_STAMP"
  ok "Built $(basename "$iso") ($(du -h "$iso" | cut -f1))"
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

# Does this disk already carry a Ventoy install (both Ventoy partitions)?
has_ventoy() {
  local labels
  labels=$(lsblk -nro LABEL "$1" 2>/dev/null || true)
  grep -qx 'Ventoy' <<<"$labels" && grep -qx 'VTOYEFI' <<<"$labels"
}

# Mount the big Ventoy partition. With rescan=1 (right after an install) the
# partition table is re-read first, so no unplugging is needed.
# Sets VENTOY_PART and VENTOY_MOUNT on success.
mount_ventoy() {
  local disk=$1 rescan=${2:-1} part="" mnt=""
  if (( rescan )); then
    sync
    sudo partprobe "$disk" || warn "partprobe failed, carrying on"
    udevadm settle || true
  fi

  # Find this disk's Ventoy partition (give udev a few seconds to create it)
  for _ in {1..20}; do
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

# README section 6, safe to re-run on a stick from a previous flash:
#   arch-autoinstall.iso       copied only if missing or different from the local build
#   ventoy/ventoy.json         written only if missing
#   arch-autoinstall/autoinstall.env   template copied only if missing (holds your secrets)
#   arch-autoinstall/packages.txt     refreshed from the repo on every run
populate_stick() {
  local v=$1 need_copy=1 f
  local iso_dest="${v}/${STICK_ISO}"
  local cfg_dest="${v}/${STICK_CFG}"
  local json_dest="${v}/ventoy/ventoy.json"
  mkdir -p "$cfg_dest" "${v}/ventoy"

  # --- ISO ---
  if [[ -f "$iso_dest" ]]; then
    if [[ "$(stat -c %s "$iso_dest")" == "$(stat -c %s "$ISO")" ]]; then
      info "An ISO is already on the stick, verifying (reads the whole file, can take a minute or two)..."
      if [[ "$(sha256_of "$iso_dest")" == "$(sha256_of "$ISO")" ]]; then
        need_copy=0
        ok "ISO on the stick matches the local build, not copying"
      else
        warn "ISO on the stick differs from the local build, replacing it"
      fi
    else
      warn "ISO on the stick is a different size (older build or partial copy), replacing it"
    fi
  fi
  if (( need_copy )); then
    info "Copying ISO ($(du -h "$ISO" | cut -f1), this can take a few minutes)..."
    if command -v rsync >/dev/null; then
      rsync --no-perms --no-owner --no-group --info=progress2 "$ISO" "$iso_dest" \
        || die "Copying the ISO to the stick failed"
    else
      cp "$ISO" "$iso_dest" || die "Copying the ISO to the stick failed"
    fi
    info "Flushing to the stick..."
    sync
    [[ "$(stat -c %s "$iso_dest")" == "$(stat -c %s "$ISO")" ]] \
      || die "Copied ISO is a different size from the original"
    ok "ISO copied to ${iso_dest}"
  fi

  # --- ventoy.json: only if missing ---
  if [[ -f "$json_dest" ]]; then
    if grep -q "\"/${STICK_ISO}\"" "$json_dest"; then
      ok "ventoy.json already present, leaving it alone"
    else
      warn "ventoy.json exists but does not auto-boot /${STICK_ISO}. Merge in README section 6c by hand"
    fi
  else
    cat > "$json_dest" <<JSON
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/${STICK_ISO}" }
  ]
}
JSON
    ok "ventoy.json written (auto-boots /${STICK_ISO} after 10 s)"
  fi

  # --- autoinstall.env: template only if missing, never overwrite real values ---
  if [[ -f "${cfg_dest}/autoinstall.env" ]]; then
    ok "autoinstall.env already present, leaving it alone"
  else
    cp "${BUILD_DIR}/autoinstall.env.example" "${cfg_dest}/autoinstall.env"
    ok "autoinstall.env template written"
  fi

  # --- packages.txt: always refreshed (edit it in the repo, not on the stick) ---
  cp "${BUILD_DIR}/packages.txt" "${cfg_dest}/packages.txt"
  ok "packages.txt copied ($(grep -cv '^[[:space:]]*\(#\|$\)' "${cfg_dest}/packages.txt") lines of packages)"

  # --- leftovers from the old archinstall flow ---
  for f in user_configuration.json user_credentials.json; do
    if [[ -f "${cfg_dest}/${f}" ]]; then
      warn "${STICK_CFG}/${f} is from the old archinstall flow and is no longer used."
      warn "  It may hold a password hash: delete it with  rm \"${cfg_dest}/${f}\""
    fi
  done
  sync
  STICK_POPULATED=1
}

install_ventoy() {
  local disk=$1
  confirm_wipe "$disk"
  step "Installing Ventoy on ${disk}"
  unmount_disk "$disk"
  info "Running Ventoy2Disk.sh ${VENTOY_FLAG} ${disk} (Ventoy will ask for its own y/n confirmations)"
  (cd "$VENTOY_DIR" && sudo sh Ventoy2Disk.sh "$VENTOY_FLAG" "$disk") \
    || die "Ventoy install failed"
  ok "Ventoy installed"
}

# Install Ventoy if the stick needs it (or --force), then mount it and bring
# its files up to date.
build_stick() {
  local disk=$1 rescan=0
  if (( FORCE )) || ! has_ventoy "$disk"; then
    install_ventoy "$disk"
    rescan=1
  else
    step "Ventoy already on ${disk}"
    ok "Found an existing Ventoy install (version not checked), keeping it"
    info "Nothing will be erased. Use --force to wipe and reinstall"
  fi

  step "Mounting the stick"
  if mount_ventoy "$disk" "$rescan"; then
    step "Updating files on the stick"
    populate_stick "$VENTOY_MOUNT"
  else
    warn "Could not mount automatically. Unplug and replug the stick, then do README section 6 by hand"
  fi
}

# ---------- preflight ----------
step "Preflight"
required=(curl sha256sum awk tar)
if [[ -n "$DISK" ]]; then required+=(lsblk sudo umount); fi
for cmd in "${required[@]}"; do
  command -v "$cmd" >/dev/null || die "Missing required command: ${cmd}"
done
mkdir -p "$CACHE_DIR" "$ISO_OUT_DIR"
info "Cache directory: ${CACHE_DIR}"
if [[ -n "$DISK" ]]; then
  info "Target disk: ${DISK}"
  validate_disk "$DISK"   # fail fast, before the long build
else
  info "No disk given, will only build the ISO and download Ventoy"
fi

# ---------- Arch ISO ----------
step "Arch autoinstall ISO"
stage_sources
ISO=$(latest_iso)
if (( REBUILD )); then
  info "--rebuild given"
  build_iso
elif [[ -z "$ISO" ]]; then
  info "No cached ISO yet"
  build_iso
elif [[ ! -f "$ISO_STAMP" || "$(cat "$ISO_STAMP")" != "$(sources_hash)" ]]; then
  info "build.sh or install.sh changed since the cached ISO was built"
  build_iso
else
  ok "Cached ISO is up to date: $(basename "$ISO")"
  if [[ -n "$(find "$ISO" -mtime +30)" ]]; then
    warn "It is over 30 days old. Consider --rebuild so its archinstall stays current"
  fi
fi
ISO=$(latest_iso)

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
if [[ -n "$DISK" ]]; then build_stick "$DISK"; fi

# ---------- summary ----------
step "All done"
ok "ISO:    ${ISO}"
ok "Ventoy: ${VENTOY_DIR}"
if [[ -n "$VENTOY_MOUNT" ]]; then
  ok "Stick:  ${VENTOY_MOUNT}"
fi
if (( STICK_POPULATED )); then
  env_file="${VENTOY_MOUNT}/${STICK_CFG}/autoinstall.env"
  if bash "${BUILD_DIR}/install.sh" --check "$env_file"; then
    ok "autoinstall.env passes install.sh --check"
  else
    warn "autoinstall.env is not ready yet (README section 6b). Edit it, then re-check:"
    info "  nano \"${env_file}\""
    info "  bash \"${BUILD_DIR}/install.sh\" --check \"${env_file}\""
  fi
  info "Then flush and unmount:"
  info "  sync && udisksctl unmount -b ${VENTOY_PART}"
elif [[ -z "$DISK" ]]; then
  info "To build the stick, re-run with a disk. Find it with:"
  info "  lsblk -d -p -o NAME,SIZE,MODEL,TRAN --filter 'TRAN==\"usb\"'"
fi

printf 'ISO=%q\nVENTOY_DIR=%q\n' "$ISO" "$VENTOY_DIR" >&3
if [[ -n "$VENTOY_MOUNT" ]]; then printf 'V=%q\n' "$VENTOY_MOUNT" >&3; fi
