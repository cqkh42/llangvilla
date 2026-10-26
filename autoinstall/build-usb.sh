#!/usr/bin/env bash
# Prepares the download-and-unpack parts of autoinstall/README.md:
#   - the Ubuntu desktop ISO (section 2), verified against Ubuntu's SHA256SUMS
#   - the Ventoy Linux tarball (section 3), verified against a pinned hash,
#     then unpacked ready for Ventoy2Disk.sh
#
# Everything lives in $XDG_CACHE_HOME/llangvilla (default ~/.cache/llangvilla).
# Anything already cached and verified is skipped. Downloads go to a resumable
# .part file and are only renamed once the checksum passes.
#
# Logs go to stderr. Stdout is two shell-evaluable lines, so you can do:
#     eval "$(./fetch-ubuntu-iso.sh)"      # sets $ISO and $VENTOY_DIR
set -euo pipefail

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
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET" >&2; }
info() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

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

# ---------- preflight ----------
step "Preflight"
for cmd in curl sha256sum awk tar; do
  command -v "$cmd" >/dev/null || die "Missing required command: ${cmd}"
done
mkdir -p "$CACHE_DIR"
info "Cache directory: ${CACHE_DIR}"

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

# ---------- summary ----------
step "All done"
ok "ISO:    ${ISO_PATH}"
ok "Ventoy: ${VENTOY_DIR}"
info "Next: sudo sh ${VENTOY_DIR}/Ventoy2Disk.sh -i /dev/sdX   (check lsblk first!)"

printf 'ISO=%q\nVENTOY_DIR=%q\n' "$ISO_PATH" "$VENTOY_DIR"
