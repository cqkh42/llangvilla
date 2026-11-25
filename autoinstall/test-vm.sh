#!/usr/bin/env bash
# Tests the zero-touch installer in a QEMU VM (UEFI via OVMF). No stick or real
# hardware needed, and nothing outside ~/.cache/llangvilla/vm is touched.
# README section 7 is the guide.
#
# Usage: autoinstall/test-vm.sh [COMMAND] [OPTIONS]
#
# Commands:
#   all       (default) install, then check
#   install   blank virtual disk + the ISO + a small virtual USB stick with test
#             config; waits until the installer powers the VM off
#   check     boots the installed disk headless, runs checks over SSH, powers off
#   boot      boots the installed disk in a window to look around (SSH on port 2222)
#   ssh       SSH into a VM started with `boot` (extra args run as a command)
#   live      boots the ISO in a window with a separate blank disk and no stick:
#             the installer stops at a root shell, for poking at the live system
#   clean     deletes the VM disk, firmware variables, stick image and test key
#
# Options:
#   --iso FILE       ISO to boot (default: $ISO, else the newest build in the cache)
#   --env FILE       base autoinstall.env (default: autoinstall.env.example). Any
#                    placeholders are filled with test values, then test overrides are
#                    appended (blank disk, no countdown, test password and SSH key).
#   --ansible        keep ANSIBLE_PULL_URL (off by default: it tests the repo's main
#                    branch, not your working tree; set ANSIBLE_PULL_BRANCH to test one)
#   --baked          use the install.sh baked into the ISO. By default the working
#                    tree's install.sh goes on the test stick and replaces it, so
#                    installer changes can be tested without rebuilding the ISO
#   --stick DEV      install from a REAL stick (e.g. /dev/sdb) instead of the ISO +
#                    test stick, exactly as the real machine would (needs sudo). Its
#                    own autoinstall.env is used, so `check` cannot log in; use `boot`.
#   --gui / --headless   show or hide the VM window (default: shown for boot/live only)
#   --disk-size GB   size of the virtual target disk (default 60)
#   --timeout MIN    give up on the install after this long (default 90)
#
# Environment: OVMF_CODE / OVMF_VARS (firmware files, found automatically on Arch,
# Debian/Ubuntu and Fedora), VM_SSH_PORT (2222), VM_MEMORY (4G), TEST_PASSWORD (test).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/llangvilla"
state="$cache/vm"
disk="$state/disk.qcow2"
live_disk="$state/live-disk.qcow2"
vars="$state/OVMF_VARS.fd"
stick_img="$state/stick.img"
key="$state/id_ed25519"
test_env="$state/autoinstall.env"
ssh_port="${VM_SSH_PORT:-2222}"
memory="${VM_MEMORY:-4G}"
test_password="${TEST_PASSWORD:-test}"

# ---------- logging ----------
if [[ -t 2 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET" >&2; }
info() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '  %s✖%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

# ---------- arguments ----------
cmd=all
case "${1:-}" in
  all|install|check|boot|ssh|live|clean) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
esac
iso="${ISO:-}" base_env="$here/autoinstall.env.example" keep_ansible=0 baked=0 stick_dev=""
gui="" disk_size=60 timeout_min=90 ssh_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)       iso=$2; shift ;;
    --env)       base_env=$2; shift ;;
    --ansible)   keep_ansible=1 ;;
    --baked)     baked=1 ;;
    --stick)     stick_dev=$2; shift ;;
    --gui)       gui=1 ;;
    --headless)  gui=0 ;;
    --disk-size) disk_size=$2; shift ;;
    --timeout)   timeout_min=$2; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)
      if [[ $cmd == ssh ]]; then ssh_args+=("$1"); else usage; die "Unknown argument: $1"; fi ;;
  esac
  shift
done

mkdir -p "$state"

# ---------- helpers ----------
find_ovmf() {
  local code
  if [[ -n ${OVMF_CODE:-} ]]; then
    [[ -f $OVMF_CODE && -f ${OVMF_VARS:-} ]] || die "Set both OVMF_CODE and OVMF_VARS to existing files."
    return 0
  fi
  for code in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    if [[ -f $code && -f ${code/CODE/VARS} ]]; then
      OVMF_CODE=$code; OVMF_VARS=${code/CODE/VARS}; return 0
    fi
  done
  die "UEFI firmware (OVMF) not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu), or set OVMF_CODE and OVMF_VARS."
}

need() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "Missing command: $c (README section 2)"; done
}

find_iso() {
  if [[ -z $iso ]]; then
    # shellcheck disable=SC2012  # our own fixed-pattern filenames
    iso=$(ls -1t "$cache"/iso-build/out/arch-autoinstall-*.iso 2>/dev/null | head -n1 || true)
  fi
  [[ -n $iso && -f $iso ]] || die "No ISO found. Build one first: autoinstall/build-usb.sh (or pass --iso)."
  info "ISO: $iso"
}

# Common QEMU arguments: q35 + UEFI with persistent variables (so the boot entry
# bootctl creates survives into the next boot, as on real hardware), the target
# disk on virtio with a fixed serial, user networking with SSH forwarded.
qemu_base() {
  local target=$1 show=$2 smp
  smp=$(nproc); (( smp > 4 )) && smp=4
  Q=(qemu-system-x86_64 -machine q35 -m "$memory" -smp "$smp"
     -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
     -drive "if=pflash,format=raw,file=$vars"
     -drive "file=$target,if=none,id=target,format=qcow2"
     -device "virtio-blk-pci,drive=target,serial=llangvilla-test,bootindex=1"
     -device virtio-rng-pci
     -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${ssh_port}-:22")
  if [[ -w /dev/kvm ]]; then
    Q+=(-accel kvm -cpu host)
  else
    warn "/dev/kvm is not usable: falling back to software emulation, which is MUCH slower"
    warn "(an install can take hours). On Arch: sudo usermod -aG kvm \$USER, then log in again."
    Q+=(-accel tcg -cpu max)
  fi
  if (( show )); then Q+=(-display "${VM_DISPLAY:-default}"); else Q+=(-display none); fi
}

ssh_opts() {
  S=(-i "$key" -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
}

# Values the test env sets, read in a subshell so they cannot clobber ours.
# shellcheck source=/dev/null
env_value() { (set +u; source "$test_env" >/dev/null 2>&1; printf '%s' "${!1:-${2:-}}"); }

# The stick-side config: base env with placeholders filled + test overrides.
make_test_env() {
  local hash pub
  [[ -f $base_env ]] || die "No such env file: $base_env"
  [[ -f $key ]] || ssh-keygen -q -t ed25519 -N '' -C llangvilla-test-vm -f "$key"
  pub=$(cat "$key.pub")
  hash=$(openssl passwd -6 "$test_password")
  sed -e "s|__WIFI_SSID__|TestNetwork|" -e "s|__WIFI_PASSWORD__|test-wifi-password|" \
      -e "s|__PASSWORD_HASH__|${hash}|" "$base_env" > "$test_env"
  {
    echo
    echo "# ---- test-vm.sh overrides (later assignments win) ----"
    echo "TARGET_DISK=auto"
    echo "CONFIRM_SECONDS=0"
    echo "NONBLANK_DISK=ask"
    echo "ON_FAILURE=poweroff"
    echo "PASSWORD_HASH='${hash}'"
    echo "SSH_AUTHORIZED_KEYS='${pub}'"
    (( keep_ansible )) || echo "ANSIBLE_PULL_URL=''"
  } >> "$test_env"
  chmod 600 "$test_env"
  bash "$here/install.sh" --check "$test_env" >/dev/null || {
    bash "$here/install.sh" --check "$test_env" || true
    die "The test autoinstall.env is invalid (see above)."
  }
  ok "Test config: $test_env (password '$test_password', key $key)"
}

# A small unpartitioned FAT image attached as a USB stick, like the Ventoy data partition.
make_stick() {
  need mkfs.fat mmd mcopy
  rm -f "$stick_img"
  mkfs.fat -C -n AUTOINSTALL "$stick_img" 65536 >/dev/null
  mmd -i "$stick_img" ::/arch-autoinstall
  mcopy -i "$stick_img" "$test_env" ::/arch-autoinstall/autoinstall.env
  mcopy -i "$stick_img" "$here/packages.txt" ::/arch-autoinstall/packages.txt
  if (( baked )); then
    info "Using the install.sh baked into the ISO (--baked)"
  else
    mcopy -i "$stick_img" "$here/install.sh" ::/arch-autoinstall/install.sh
    info "Using the working tree's install.sh (no ISO rebuild needed; --baked to test the ISO's copy)"
  fi
  ok "Test stick image: $stick_img"
}

# ---------- commands ----------
do_install() {
  local show=${gui:-0} logs status rc=0
  need qemu-system-x86_64 qemu-img
  find_ovmf
  step "Fresh virtual machine"
  rm -f "$disk"
  qemu-img create -q -f qcow2 "$disk" "${disk_size}G"
  cp "$OVMF_VARS" "$vars"
  ok "Blank ${disk_size} GB disk, fresh UEFI variables"
  qemu_base "$disk" "$show"

  if [[ -n $stick_dev ]]; then
    [[ -b $stick_dev ]] || die "$stick_dev is not a block device"
    [[ $(lsblk -dnro TRAN "$stick_dev") == usb ]] || die "$stick_dev is not a USB disk, refusing"
    if lsblk -nro MOUNTPOINT "$stick_dev" | grep -q .; then
      die "$stick_dev is mounted. Unmount it first (README section 6d)"
    fi
    step "Installing from the real stick $stick_dev (Ventoy menu, then the installer)"
    warn "This uses the stick's own autoinstall.env: its countdown applies, and a pinned"
    warn "TARGET_DISK will not exist in the VM (the installer then stops safely)."
    Q=(sudo "${Q[@]}"
       -drive "file=$stick_dev,format=raw,if=none,id=stick"
       -device qemu-xhci -device "usb-storage,drive=stick,removable=on,bootindex=0")
  else
    find_iso
    step "Preparing the test stick"
    make_test_env
    make_stick
    Q+=(-drive "file=$iso,media=cdrom,if=none,id=cd,readonly=on" -device "ide-cd,drive=cd,bootindex=0"
        -drive "file=$stick_img,format=raw,if=none,id=stick"
        -device qemu-xhci -device "usb-storage,drive=stick,removable=on")
  fi

  step "Installing (the VM powers off when done; timeout ${timeout_min} min)"
  (( show )) || info "Headless. Watch it with --gui. Typical: 10-25 min with KVM"
  timeout --foreground "${timeout_min}m" "${Q[@]}" || rc=$?
  (( rc == 124 )) && warn "Timed out after ${timeout_min} minutes"
  (( rc != 0 && rc != 124 )) && warn "QEMU exited with status $rc"

  if [[ -n $stick_dev ]]; then
    (( rc == 0 )) || die "Install did not finish cleanly."
    ok "VM powered off. Logs are in arch-autoinstall/logs/ on the stick."
    info "Look around with: autoinstall/test-vm.sh boot"
    return 0
  fi

  logs="$state/logs/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$logs"
  mcopy -n -s -i "$stick_img" ::/arch-autoinstall/logs/ "$logs/" 2>/dev/null || true
  status=$(cat "$logs"/logs/last-status 2>/dev/null || true)
  info "Installer logs copied to $logs/logs/"
  case "$status" in
    OK*) ok "Installer reported: $status" ;;
    "")  die "The installer left no status (it stopped before finding the stick, or hung). Re-run with --gui." ;;
    *)   tail -n 30 "$(find "$logs/logs" -name 'install-*.log' | sort | tail -n1)" >&2 || true
         die "Installer reported: $status" ;;
  esac
}

# Wait until SSH answers (and, with --ansible, until the first-boot playbook is done).
wait_ssh() {
  local deadline=$1 what=$2
  ssh_opts
  until ssh "${S[@]}" "$vm_user@127.0.0.1" true 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    kill -0 "$qemu_pid" 2>/dev/null || die "The VM exited before SSH came up ($what)."
    sleep 5
  done
}

do_check() {
  local show=${gui:-0} deadline ansible_url reboot_after fails=0 remote
  [[ -f $disk && -f $vars ]] || die "No installed VM disk. Run: autoinstall/test-vm.sh install"
  [[ -f $test_env && -f $key ]] || die "No test config (check needs the test SSH key; not available after --stick)."
  need qemu-system-x86_64 ssh
  find_ovmf
  vm_user=$(env_value USER_NAME)
  ansible_url=$(env_value ANSIBLE_PULL_URL)
  reboot_after=$(env_value ANSIBLE_REBOOT_AFTER 1)

  step "Booting the installed system (headless unless --gui)"
  qemu_base "$disk" "$show"
  "${Q[@]}" &
  qemu_pid=$!
  trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT

  deadline=$(( SECONDS + 15 * 60 ))
  wait_ssh "$deadline" "first boot" || die "SSH did not come up within 15 minutes."
  ok "SSH is up"

  if [[ -n $ansible_url ]]; then
    info "Waiting for the first-boot ansible-pull to finish (up to 40 min)..."
    deadline=$(( SECONDS + 40 * 60 ))
    until ssh "${S[@]}" "$vm_user@127.0.0.1" test -e /var/lib/ansible-pull-firstboot.done 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        ssh "${S[@]}" "$vm_user@127.0.0.1" journalctl -u ansible-pull-firstboot.service -b --no-pager 2>/dev/null | tail -n 40 >&2 || true
        die "ansible-pull did not finish (journal above)."
      fi
      sleep 10
    done
    ok "ansible-pull finished"
    if [[ $reboot_after == 1 ]]; then
      info "Waiting for the automatic reboot..."
      sleep 30
      wait_ssh $(( SECONDS + 10 * 60 )) "after the ansible reboot" || die "SSH did not come back after the reboot."
    fi
  fi

  step "Running checks"
  # Expected values go in as environment variables; the checks run on the VM.
  printf -v remote 'PW=%q EXP_HOST=%q EXP_USER=%q EXP_REAL=%q EXP_FS=%q EXP_TZ=%q EXP_LOCALE=%q EXP_KERNELS=%q EXP_WIFI=%q EXP_SSH_PW=%q EXP_ANSIBLE=%q EXP_LOCK_ROOT=%q bash -s' \
    "$test_password" "$(env_value HOST_NAME)" "$vm_user" "$(env_value REAL_NAME)" \
    "$(env_value ROOT_FS btrfs)" "$(env_value TIMEZONE)" "$(env_value LOCALE)" "$(env_value KERNELS linux)" \
    "$(env_value WIFI_SSID)" "$(env_value SSH_PASSWORD_AUTH 0)" "$ansible_url" "$(env_value LOCK_ROOT 1)"
  # shellcheck disable=SC2029  # expanding on the client side is the point
  ssh "${S[@]}" "$vm_user@127.0.0.1" "$remote" <<'CHECKS' || fails=1
fails=0
pass() { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✖\e[0m %s: %s\n' "$1" "$2"; fails=1; }
# </dev/null: this script arrives on stdin, so no check may read from it.
check() { local name=$1; shift; if out=$("$@" 2>&1 </dev/null); then pass "$name"; else fail "$name" "${out:-failed}"; fi; }
s() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
root_locked()  { s passwd -S root | awk '{exit $2 != "L"}'; }
sshd_no_pw()   { s sshd -T | grep -qx 'passwordauthentication no'; }
wifi_profile() { [[ $(s stat -c %a /etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection) == 600 ]]; }

state=$(timeout 300 systemctl is-system-running --wait 2>&1 </dev/null)
if [[ $state == running ]]; then pass "systemd: running, no failed units"
else fail "systemd" "$state; failed: $(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)"; fi
check "sudo works for $EXP_USER"   s true
check "hostname is $EXP_HOST"      test "$(cat /etc/hostname)" = "$EXP_HOST"
check "full name is '$EXP_REAL'"   test "$(getent passwd "$EXP_USER" | cut -d: -f5)" = "$EXP_REAL"
check "root fs is $EXP_FS"         test "$(findmnt -no FSTYPE /)" = "$EXP_FS"
if [[ $EXP_FS == btrfs ]]; then
  check "/ is subvolume @"         bash -c 'findmnt -no OPTIONS / | grep -q "subvol=/@\(,\|$\)"'
  for m in /home /var/log /var/cache/pacman/pkg /.snapshots; do check "$m is mounted" findmnt -n "$m"; done
  check "fstab has no subvolid="   bash -c '! grep -q subvolid= /etc/fstab'
fi
check "/boot is the vfat ESP"      test "$(findmnt -no FSTYPE /boot)" = vfat
check "systemd-boot is installed"  s bootctl is-installed
for k in $EXP_KERNELS; do
  check "boot entry for $k"        s test -f "/boot/loader/entries/arch-$k.conf"
  check "kernel image for $k"      s test -f "/boot/vmlinuz-$k"
done
check "timezone is $EXP_TZ"        bash -c "readlink /etc/localtime | grep -q '$EXP_TZ\$'"
check "LANG is $EXP_LOCALE"        grep -qx "LANG=$EXP_LOCALE" /etc/locale.conf
check "zram swap is on"            bash -c 'swapon --show=NAME --noheadings | grep -q zram'
check "NetworkManager is active"   systemctl is-active NetworkManager
check "sshd is active"             systemctl is-active sshd
if pacman -Q sddm >/dev/null 2>&1; then check "sddm (login screen) is active" systemctl is-active sddm; fi
if [[ $EXP_LOCK_ROOT == 1 ]]; then check "root is locked" root_locked; fi
if [[ $EXP_SSH_PW == 0 ]]; then check "sshd refuses passwords" sshd_no_pw; fi
if [[ -n $EXP_WIFI ]]; then check "Wi-Fi profile, mode 600" wifi_profile; fi
if [[ -n $EXP_ANSIBLE ]]; then check "ansible-pull done marker" test -e /var/lib/ansible-pull-firstboot.done; fi
exit $fails
CHECKS

  # From the outside: password logins must be refused when key-only is configured.
  if [[ $(env_value SSH_PASSWORD_AUTH 0) == 0 ]]; then
    if ssh -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
         -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
         "$vm_user@127.0.0.1" true 2>&1 | grep -q 'Permission denied (publickey)'; then
      ok "SSH offers key login only (checked from the host)"
    else
      warn "SSH still offers password login"; fails=1
    fi
  fi

  step "Powering the VM off"
  # shellcheck disable=SC2029
  ssh "${S[@]}" "$vm_user@127.0.0.1" "printf '%s\n' $(printf %q "$test_password") | sudo -S -p '' systemctl poweroff" 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 2; done
  kill "$qemu_pid" 2>/dev/null || true
  trap - EXIT
  (( fails == 0 )) || die "Some checks failed (see above)."
  ok "All checks passed"
}

do_boot() {
  local show=${gui:-1}
  [[ -f $disk && -f $vars ]] || die "No installed VM disk. Run: autoinstall/test-vm.sh install"
  need qemu-system-x86_64
  find_ovmf
  qemu_base "$disk" "$show"
  step "Booting the installed system"
  info "Log in as $(env_value USER_NAME jack) (password '$test_password' for a test install)"
  info "SSH from another terminal: autoinstall/test-vm.sh ssh"
  info "Changes persist on $disk until the next install"
  exec "${Q[@]}"
}

do_live() {
  local show=${gui:-1}
  need qemu-system-x86_64 qemu-img
  find_ovmf
  find_iso
  [[ -f $live_disk ]] || qemu-img create -q -f qcow2 "$live_disk" "${disk_size}G"
  cp "$OVMF_VARS" "$state/OVMF_VARS.live.fd"
  vars="$state/OVMF_VARS.live.fd"
  qemu_base "$live_disk" "$show"
  Q+=(-drive "file=$iso,media=cdrom,if=none,id=cd,readonly=on" -device "ide-cd,drive=cd,bootindex=0")
  step "Booting the live ISO (no stick: the installer gives up after ~30 s and leaves a root shell)"
  info "Scratch disk: $live_disk (separate from the installed test disk)"
  exec "${Q[@]}"
}

do_ssh() {
  [[ -f $key ]] || die "No test key yet. Run: autoinstall/test-vm.sh install"
  ssh_opts
  exec ssh "${S[@]}" -o BatchMode=no "$(env_value USER_NAME jack)@127.0.0.1" "${ssh_args[@]}"
}

case $cmd in
  install) do_install ;;
  check)   do_check ;;
  all)     do_install
           if [[ -n $stick_dev ]]; then info "Skipping check (--stick: the test key is not on that install)"
           else do_check; fi ;;
  boot)    do_boot ;;
  live)    do_live ;;
  ssh)     do_ssh ;;
  clean)   rm -f "$disk" "$live_disk" "$vars" "$state/OVMF_VARS.live.fd" "$stick_img" "$key" "$key.pub" "$test_env"
           ok "Removed the VM files in $state (logs kept in $state/logs)" ;;
esac
