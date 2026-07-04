#!/usr/bin/env bash

set -Eeuoa pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $SCRIPT_DIR/core.sh

validate_path() {
    [[ -d "$BOOT_VOLUME" ]] || \
        error "BOOT_VOLUME does not exist: $BOOT_VOLUME"
}


plist_value() {
    local plist="$1"
    local key="$2"

    plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}

validate_target_disk() {
    local plist
    plist=$(mktemp)

    if ! diskutil info -plist "$TARGET_DISK" >"$plist"; then
        rm -f "$plist"
        error "TARGET_DISK not found: $TARGET_DISK"
    fi

    local bus
    local removable
    local total_size

    bus=$(plist_value "$plist" BusProtocol || true)
    removable=$(plist_value "$plist" RemovableMedia || true)
    total_size=$(plist_value "$plist" TotalSize || true)

    rm -f "$plist"

    [[ "$bus" == "USB" || "$bus" == "SD" ]] || \
        error "TARGET_DISK bus is '$bus' (must be USB or SD)"

    local size_gb
    size_gb=$(awk "BEGIN { printf \"%.0f\", $total_size / 1024 / 1024 / 1024 }")

    if (( size_gb > 128 )); then
        error "TARGET_DISK size ${size_gb}GB exceeds limit 128GB"
    fi

    [[ "$removable" == "true" || "$removable" == "Yes" || "$removable" == "Removable" ]] || \
        error "TARGET_DISK is not removable (value: $removable)"

    echo "✓ TARGET_DISK $TARGET_DISK looks safe to flash"
    echo "  Bus:       $bus"
    echo "  Size:      ${size_gb} GB"
    echo "  Removable: $removable"

    if diskutil list "$TARGET_DISK" | grep -qi bootfs; then
        warn "Warning: this disk looks like a previously flashed Pi card (bootfs partition detected)"
    fi
}

main() {
  validate_path
  validate_target_disk
}

main "$@"