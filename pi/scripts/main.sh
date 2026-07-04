#!/usr/bin/env bash

set -Eeuoa pipefail

DRY_RUN=false
START_TIME=$(date +%s)

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $SCRIPT_DIR/core.sh

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}

validate_ssh_path() {
    SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"

    [[ -f "$SSH_KEY_FILE" ]] || \
        error "SSH_KEY_FILE does not exist: $SSH_KEY_FILE"
}


read_ssh_key() {
    SSH_PUBLIC_KEY_CONTENT="$(<"$SSH_KEY_FILE")"

    [[ -n "$SSH_PUBLIC_KEY_CONTENT" ]] || \
        error "SSH public key file is empty: $SSH_KEY_FILE"
}

print_summary() {
    cat <<EOF

---- Flash Configuration ----
Image:        $IMAGE_IMG_PATH
Target disk:  $TARGET_DISK
Boot volume:  $BOOT_VOLUME
Hostname:     $HOSTNAME
Username:     $USERNAME
WiFi SSID:    $WIFI_SSID
SSH key:      $SSH_KEY_FILE
Git repo:     $GIT_REPO_URL
-----------------------------

EOF
}

confirm_or_exit() {
    if $DRY_RUN; then
        echo "Dry run complete. No disk was written."
        exit 0
    fi

    echo "⚠️  This will permanently erase $TARGET_DISK."
    read -r -p "Type YES to continue: " response

    [[ "$response" == "YES" ]] || {
        echo "Aborted."
        exit 0
    }
}

raw_disk() {
    echo "$TARGET_DISK" | sed 's#/dev/disk#/dev/rdisk#'
}

flash_image() {
    local rdisk
    rdisk="$(raw_disk)"

    diskutil unmountDisk "$TARGET_DISK"

    info "Flashing image..."

    if command -v pv >/dev/null 2>&1; then
        pv "$IMAGE_IMG_PATH" | dd of="$rdisk" bs=4m conv=sync
    else
        dd of="$rdisk" bs=4m if="$IMAGE_IMG_PATH" &
        local dd_pid=$!

        while kill -0 "$dd_pid" 2>/dev/null; do
            kill -INFO "$dd_pid" 2>/dev/null || true
            sleep 5
        done

        wait "$dd_pid"
    fi

    sync
}

wait_for_boot_volume() {
    local timeout=120
    local elapsed=0

    until [[ -d "$BOOT_VOLUME" ]]; do
        sleep 2
        elapsed=$((elapsed + 2))

        if (( elapsed >= timeout )); then
            error "BOOT_VOLUME did not reappear: $BOOT_VOLUME"
        fi
    done
}

write_meta_data() {
    cat >"$BOOT_VOLUME/meta-data" <<EOF
instance-id: rpi-$(date +%s)
local-hostname: $HOSTNAME
EOF
}

write_network_config() {
    cat >"$BOOT_VOLUME/network-config" <<EOF
network:
  version: 2
  renderer: NetworkManager
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "$WIFI_SSID":
          password: "$WIFI_PASSWORD"
      regulatory-domain: $WIFI_COUNTRY
EOF
}

write_user_data() {
    cat >"$BOOT_VOLUME/user-data" <<EOF
#cloud-config

output:
  all: '| tee -a /var/log/cloud-init-output.log'

hostname: $HOSTNAME
manage_etc_hosts: true

timezone: $TIMEZONE
locale: $LOCALE

ssh_pwauth: false
disable_root: true
enable_ssh: true

users:
  - name: $USERNAME
    groups: [users, adm, dialout, audio, netdev, video, plugdev, cdrom, games, input, gpio, spi, i2c, render, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $SSH_PUBLIC_KEY_CONTENT

  - name: pi
    lock_passwd: true
    shell: /usr/sbin/nologin
    ssh_authorized_keys: []

packages:
  - avahi-daemon

runcmd:
  - mountpoint -q /boot/firmware || mount /boot/firmware || true
  - passwd -l pi
  - usermod --expiredate 1 pi
  - systemctl enable --now avahi-daemon

ansible:
  install_method: pip
  run_user: $USERNAME
  pull:
    - url: $GIT_REPO_URL
      playbook_names:
        - $ANSIBLE_PLAYBOOK

final_message: |
  Cloud-init finished after \$UPTIME seconds.
  SSH: ssh $USERNAME@${HOSTNAME}.local
  Logs: /var/log/cloud-init-output.log
EOF
}

write_seed_files() {
    wait_for_boot_volume

    write_meta_data
    write_network_config
    write_user_data

    sync
}

verify_files() {
    local files=(
        meta-data
        network-config
        user-data
    )

    echo
    echo "Verification:"

    for file in "${files[@]}"; do
        local path="$BOOT_VOLUME/$file"

        [[ -f "$path" ]] || \
            error "Verification failed: missing $file"

        [[ -s "$path" ]] || \
            error "Verification failed: empty $file"

        printf "  %-15s %8d bytes\n" \
            "$file" \
            "$(stat -f%z "$path")"
    done
}

eject_disk() {
    if ! diskutil eject "$TARGET_DISK"; then
        warn "Failed to eject card. Please eject manually."
        return
    fi
}

print_completion() {
    local end
    local minutes

    end=$(date +%s)
    minutes=$(( (end - START_TIME) / 60 ))

    cat <<EOF

✓ SD card ready.

Insert into Pi and power on.
Once booted, connect via:

    ssh $USERNAME@${HOSTNAME}.local

Cloud-init will run automatically on first boot.

Note: flashing took approximately ${minutes} minutes.
EOF
}

main() {
    require_root
    validate_ssh_path
    source $SCRIPT_DIR/validate-boot-volume.sh
    source $SCRIPT_DIR/prepare-image.sh
    read_ssh_key
    print_summary
    confirm_or_exit
    flash_image
    write_seed_files
    verify_files
    eject_disk
    print_completion
}

main "$@"

