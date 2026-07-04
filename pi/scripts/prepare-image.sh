#!/usr/bin/env bash

set -Eeuoa pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source $SCRIPT_DIR/core.sh


prepare_image() {
    mkdir -p "$IMAGE_CACHE_DIR"

    IMAGE_PATH="$IMAGE_CACHE_DIR/$(basename "$IMAGE_URL")"
    IMAGE_IMG_PATH="${IMAGE_PATH%.xz}"

    if [[ -f "$IMAGE_IMG_PATH" ]]; then
        info "Using cached image:"
        info "  $IMAGE_IMG_PATH"
        return
    fi

    download_image
}

download_image() {
  if [[ ! -f "$IMAGE_PATH" ]]; then
        info "Downloading image..."

        if ! curl -fL "$IMAGE_URL" -o "$IMAGE_PATH"; then
            rm -f "$IMAGE_PATH"
            error "Image download failed"
        fi
    fi

    verify_checksum

    info "Decompressing image..."

    if ! xz -d --keep "$IMAGE_PATH"; then
        error "Image decompression failed. Delete cache and re-run."
    fi
}

verify_checksum() {
    local expected actual

    expected=$(curl -fsSL "${IMAGE_URL}.sha256" | tr -d '[:space:]') || \
        error "Failed to fetch checksum"

    actual=$(shasum -a 256 "$IMAGE_PATH" | awk '{print $1}')
    actual="${actual}$(basename "$IMAGE_URL")"


    if [[ "$expected" != "$actual" ]]; then
        rm -f "$IMAGE_PATH"

        cat <<EOF
Checksum mismatch.

Expected: $expected
Actual:   $actual

Delete cache and re-run.
EOF
        exit 1
    fi
}

main() {
  prepare_image
}

main