#!/usr/bin/env bash
# Step 2 of autoinstall/README.md: download the Ubuntu ISO and check it.
#
# - Caches the ISO in $XDG_CACHE_HOME/llangvilla (default ~/.cache/llangvilla)
# - Skips the download if a cached copy exists and its checksum is good
# - Downloads to a .part file (resumable) and only renames it once verified
# - Logs go to stderr; the final ISO path is printed on stdout, so you can do:
#       ISO=$(./fetch-ubuntu-iso.sh)
#       cp "$ISO" "$V/ISO/ubuntu-desktop.iso"
set -euo pipefail

UBUNTU_VERSION="26.04.1"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/llangvilla"
ISO_PATH="${CACHE_DIR}/${ISO_NAME}"
PART_PATH="${ISO_PATH}.part"

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

# ---------- preflight ----------
step "Ubuntu ${UBUNTU_VERSION} desktop ISO"
for cmd in curl sha256sum awk; do
  command -v "$cmd" >/dev/null || die "Missing required command: ${cmd}"
done
info "Cache directory: ${CACHE_DIR}"
mkdir -p "$CACHE_DIR"

# ---------- expected checksum ----------
step "Fetching official checksum"
expected=$(curl -fsSL "${BASE_URL}/SHA256SUMS" \
  | awk -v f="$ISO_NAME" '$2 == f || $2 == "*" f {print $1}') \
  || die "Could not download ${BASE_URL}/SHA256SUMS"
[[ -n "$expected" ]] || die "No checksum for ${ISO_NAME} in SHA256SUMS"
ok "Expected SHA-256: ${expected}"

# ---------- cached copy? ----------
step "Checking cache"
if [[ -f "$ISO_PATH" ]]; then
  info "Found cached ISO ($(du -h "$ISO_PATH" | cut -f1)), verifying (takes a few seconds)..."
  if [[ "$(sha256_of "$ISO_PATH")" == "$expected" ]]; then
    ok "Checksum matches, skipping download"
    printf '%s\n' "$ISO_PATH"
    exit 0
  fi
  warn "Cached ISO is corrupt or outdated, re-downloading"
  rm -f "$ISO_PATH"
else
  info "Not cached yet"
fi

# ---------- download ----------
step "Downloading ${ISO_NAME}"
[[ -f "$PART_PATH" ]] && info "Resuming partial download"
info "From: ${BASE_URL}/${ISO_NAME}"
curl -fL --retry 3 -C - --progress-bar -o "$PART_PATH" "${BASE_URL}/${ISO_NAME}" \
  || die "Download failed (re-run to resume)"
ok "Download complete"

# ---------- verify, then publish atomically ----------
step "Verifying download"
if [[ "$(sha256_of "$PART_PATH")" != "$expected" ]]; then
  rm -f "$PART_PATH"
  die "Checksum mismatch, deleted the bad download. Re-run to try again"
fi
mv "$PART_PATH" "$ISO_PATH"
ok "Checksum matches"

step "Done"
ok "ISO ready: ${ISO_PATH}"
printf '%s\n' "$ISO_PATH"
