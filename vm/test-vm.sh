#!/usr/bin/env bash
# Tries the whole flow in a QEMU VM (UEFI via OVMF): the installer (part 1) and the
# config (part 2), from the working tree. No stick or real hardware needed, and
# nothing outside ~/.cache/llangvilla/vm is touched. vm/README.md is the guide.
#
# Usage: vm/test-vm.sh [COMMAND] [OPTIONS]
#
# Commands:
#   all       (default) install, check, then config
#   install   blank virtual disk + the ISO + a small virtual USB stick with test
#             config; waits until the installer powers the VM off
#   check     boots the installed disk headless, checks the base system over SSH,
#             powers off
#   config    boots the installed disk headless, applies the working tree's config/
#             (config/apply.sh --no-pull), applies it again and fails if anything changes,
#             reboots, checks the login screen comes up, powers off. Repeatable on
#             the same install, so it is the quick loop for config changes
#   boot      boots the installed disk in a window to look around (SSH on port 2222)
#   ssh       SSH into a VM started with `boot` (extra args run as a command)
#   live      boots the ISO in a window with a separate blank disk and no stick:
#             the installer stops at a root shell, for poking at the live system
#   clean     deletes the VM disk, firmware variables, stick image and test key
#
# Options:
#   --iso FILE       ISO to boot (default: $ISO, else the newest build in the cache)
#   --env FILE       base autoinstall.env (default: installer/autoinstall.env.example).
#                    Any placeholders are filled with test values, then test overrides
#                    are appended (blank disk, no countdown, test password and SSH key).
#   --firstboot      keep CONFIG_REPO_URL, so the installed system runs the real
#                    first-boot hook (clones from GitHub: the default branch, or
#                    CONFIG_REPO_BRANCH from the env, NOT your working tree); `check`
#                    waits for it. Off by default; `config` tests the working tree.
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

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ai="$repo/installer"
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
worktree_dir=llangvilla-worktree     # in the VM user's home, for `config`

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
  all|install|check|config|boot|ssh|live|clean) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
esac
iso="${ISO:-}" base_env="$ai/autoinstall.env.example" keep_firstboot=0 baked=0 stick_dev=""
gui="" disk_size=60 timeout_min=90 ssh_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)       iso=$2; shift ;;
    --env)       base_env=$2; shift ;;
    --firstboot) keep_firstboot=1 ;;
    --ansible)   die "--ansible was replaced by --firstboot (hook from GitHub) and the 'config' command (working tree)" ;;
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
  for c in "$@"; do command -v "$c" >/dev/null || die "Missing command: $c (vm/README.md, Requirements)"; done
}

find_iso() {
  if [[ -z $iso ]]; then
    # shellcheck disable=SC2012  # our own fixed-pattern filenames
    iso=$(ls -1t "$cache"/iso-build/out/arch-autoinstall-*.iso 2>/dev/null | head -n1 || true)
  fi
  [[ -n $iso && -f $iso ]] || die "No ISO found. Build one first: installer/build-usb.sh (or pass --iso)."
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
     -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
     -monitor "unix:$state/monitor.sock,server,nowait")
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
    (( keep_firstboot )) || echo "CONFIG_REPO_URL=''"
  } >> "$test_env"
  chmod 600 "$test_env"
  bash "$ai/install.sh" --check "$test_env" >/dev/null || {
    bash "$ai/install.sh" --check "$test_env" || true
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
  mcopy -i "$stick_img" "$ai/packages.txt" ::/arch-autoinstall/packages.txt
  if (( baked )); then
    info "Using the install.sh baked into the ISO (--baked)"
  else
    mcopy -i "$stick_img" "$ai/install.sh" ::/arch-autoinstall/install.sh
    info "Using the working tree's install.sh (no ISO rebuild needed; --baked to test the ISO's copy)"
  fi
  ok "Test stick image: $stick_img"
}

# Wait until SSH answers.
wait_ssh() {
  local deadline=$1 what=$2
  ssh_opts
  until ssh "${S[@]}" "$vm_user@127.0.0.1" true 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    kill -0 "$qemu_pid" 2>/dev/null || die "The VM exited before SSH came up ($what)."
    sleep 5
  done
}

# Run a command on the VM as root (the test password goes to sudo on stdin).
# Save a PNG of the VM's screen under $state/logs/screens/ (the VM workflow uploads
# logs/). Uses QEMU's monitor; a failure only warns. A Shift press first wakes the
# login screen, which fades to just the clock after a while without input.
vm_screenshot() {
  local out="$state/logs/screens/$1.png"
  mkdir -p "${out%/*}"
  rm -f "$out"
  python3 - "$state/monitor.sock" "$out" <<'PY' 2>/dev/null || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
time.sleep(0.5)
s.recv(65536)
s.sendall(b"sendkey shift\n")
time.sleep(2)
s.sendall(f"screendump {sys.argv[2]} -f png\n".encode())
time.sleep(3)
s.close()
PY
  if [[ -s $out ]]; then info "Screenshot of the screen: $out"; else warn "Could not take a screenshot ($1)."; fi
}

vm_sudo() {
  # shellcheck disable=SC2029  # expanding on the client side is the point
  ssh "${S[@]}" "$vm_user@127.0.0.1" "printf '%s\n' $(printf %q "$test_password") | sudo -S -p '' $*"
}

# Boot the installed disk in the background and wait for SSH.
vm_up() {
  local show=${gui:-0}
  [[ -f $disk && -f $vars ]] || die "No installed VM disk. Run: vm/test-vm.sh install"
  [[ -f $test_env && -f $key ]] || die "No test config (this needs the test SSH key; not available after --stick)."
  need qemu-system-x86_64 ssh
  find_ovmf
  vm_user=$(env_value USER_NAME)
  step "Booting the installed system (headless unless --gui)"
  qemu_base "$disk" "$show"
  "${Q[@]}" &
  qemu_pid=$!
  trap 'kill "$qemu_pid" 2>/dev/null || true' EXIT
  wait_ssh $(( SECONDS + 15 * 60 )) "boot" || die "SSH did not come up within 15 minutes."
  ok "SSH is up"
}

vm_down() {
  step "Powering the VM off"
  vm_sudo systemctl poweroff 2>/dev/null || true
  for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 2; done
  kill "$qemu_pid" 2>/dev/null || true
  trap - EXIT
}

vm_reboot() {
  info "Rebooting the VM..."
  vm_sudo systemctl reboot 2>/dev/null || true
  sleep 30
  wait_ssh $(( SECONDS + 10 * 60 )) "after the reboot" || die "SSH did not come back after the reboot."
}

# With --firstboot, the installed system runs the first-boot hook (and reboots once).
wait_firstboot() {
  local deadline
  [[ -n $(env_value CONFIG_REPO_URL) ]] || return 0
  info "Waiting for the first-boot hook to finish (up to 40 min)..."
  deadline=$(( SECONDS + 40 * 60 ))
  until ssh "${S[@]}" "$vm_user@127.0.0.1" test -e /var/lib/llangvilla/firstboot.done 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      ssh "${S[@]}" "$vm_user@127.0.0.1" journalctl -u llangvilla-firstboot.service -b --no-pager 2>/dev/null | tail -n 40 >&2 || true
      die "The first-boot hook did not finish (journal above)."
    fi
    sleep 10
  done
  ok "First-boot hook finished"
  if [[ $(env_value FIRSTBOOT_REBOOT_AFTER 1) == 1 ]]; then
    info "Waiting for its automatic reboot..."
    sleep 30
    wait_ssh $(( SECONDS + 10 * 60 )) "after the first-boot reboot" || die "SSH did not come back after the reboot."
  fi
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
      die "$stick_dev is mounted. Unmount it first (installer/README.md, Eject)"
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
    info "Look around with: vm/test-vm.sh boot"
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

do_check() {
  local fails=0 remote
  vm_up
  wait_firstboot

  step "Checking the base system"
  # Expected values go in as environment variables; the checks run on the VM.
  printf -v remote 'PW=%q EXP_HOST=%q EXP_USER=%q EXP_REAL=%q EXP_FS=%q EXP_TZ=%q EXP_LOCALE=%q EXP_KERNELS=%q EXP_WIFI=%q EXP_SSH_PW=%q EXP_FIRSTBOOT=%q EXP_LOCK_ROOT=%q bash -s' \
    "$test_password" "$(env_value HOST_NAME)" "$vm_user" "$(env_value REAL_NAME)" \
    "$(env_value ROOT_FS btrfs)" "$(env_value TIMEZONE)" "$(env_value LOCALE)" "$(env_value KERNELS linux)" \
    "$(env_value WIFI_SSID)" "$(env_value SSH_PASSWORD_AUTH 0)" "$(env_value CONFIG_REPO_URL)" "$(env_value LOCK_ROOT 1)"
  # shellcheck disable=SC2029  # expanding on the client side is the point
  ssh "${S[@]}" "$vm_user@127.0.0.1" "$remote" <<'CHECKS' || fails=1
fails=0
pass() { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✖\e[0m %s: %s\n' "$1" "$2"; fails=1; }
# </dev/null: this script arrives on stdin, so no check may read from it.
check() { local name=$1; shift; if out=$("$@" 2>&1 </dev/null); then pass "$name"; else fail "$name" "${out:-failed}"; fi; }
s() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
root_locked()  { s passwd -S root | awk '{exit $2 != "L"}'; }
# On failure, show what sshd decided and which files set it.
sshd_no_pw() {
  s sshd -T | grep -qix 'passwordauthentication no' && return 0   # OpenSSH 10 prints CamelCase
  s sshd -T 2>&1 | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam) '
  s grep -HnEi '^[[:space:]]*(include|passwordauthentication|kbdinteractiveauthentication|usepam|match)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
  return 1
}
wifi_profile() { [[ $(s stat -c %a /etc/NetworkManager/system-connections/autoinstall-wifi.nmconnection) == 600 ]]; }
# Any display manager registers its login screen with logind as a "greeter" session.
greeter_session() {
  local i id
  for i in $(seq 1 30); do
    for id in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
      [[ $(loginctl show-session "$id" -p Class --value) == greeter ]] && return 0
    done
    sleep 2
  done
  echo "no greeter session after 60 s"; return 1
}

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
check "zswap is off (kernel command line)" grep -qw zswap.enabled=0 /proc/cmdline
check "NetworkManager is active"   systemctl is-active NetworkManager
check "sshd is active"             systemctl is-active sshd
check "display manager is active ($(systemctl show -p Id --value display-manager.service 2>/dev/null))" \
  systemctl is-active display-manager.service
check "login screen is up (a logind greeter session)" greeter_session
if [[ $EXP_LOCK_ROOT == 1 ]]; then check "root is locked" root_locked; fi
if [[ $EXP_SSH_PW == 0 ]]; then check "sshd refuses passwords" sshd_no_pw; fi
if [[ -n $EXP_WIFI ]]; then check "Wi-Fi profile, mode 600" wifi_profile; fi
if [[ -n $EXP_FIRSTBOOT ]]; then
  check "first-boot hook done marker" test -e /var/lib/llangvilla/firstboot.done
  check "repo checkout in /opt/llangvilla" test -d /opt/llangvilla/.git
  check "no first-boot failure notice" test ! -e /etc/issue.d/llangvilla-firstboot.issue
fi
exit $fails
CHECKS

  # From the outside: password logins must be refused when key-only is configured.
  if [[ $(env_value SSH_PASSWORD_AUTH 0) == 0 ]]; then
    local said
    said=$(ssh -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
         -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
         "$vm_user@127.0.0.1" true 2>&1 || true)
    if grep -qi 'permission denied (publickey)' <<<"$said"; then
      ok "SSH offers key login only (checked from the host)"
    else
      warn "SSH did not refuse password login as expected. ssh said: ${said:-nothing}"; fails=1
    fi
  fi

  vm_screenshot login-after-install
  vm_down
  (( fails == 0 )) || die "Some checks failed (see above)."
  ok "All base-system checks passed"
}

do_config() {
  local out apply="/home/\$USER/$worktree_dir/config/apply.sh --no-pull" sys_state
  vm_up
  wait_firstboot

  step "Copying the working tree's config/ to the VM (~/$worktree_dir)"
  # shellcheck disable=SC2029  # expanding on the client side is the point
  tar -C "$repo" --exclude='*.retry' -cz config \
    | ssh "${S[@]}" "$vm_user@127.0.0.1" "rm -rf ~/$worktree_dir && mkdir ~/$worktree_dir && tar -xz -C ~/$worktree_dir"
  ok "Copied"

  step "Applying the config (config/apply.sh --no-pull)"
  vm_sudo "$apply" || die "config/apply.sh failed (output above)."
  ok "Config applied"

  ssh "${S[@]}" "$vm_user@127.0.0.1" test -L .local/state/nix/profiles/home-manager \
    || die "home-manager produced no generation for $vm_user."
  ok "home-manager applied the user layer"
  ssh "${S[@]}" "$vm_user@127.0.0.1" 'ls /var/log/llangvilla/apply-*.log' >/dev/null 2>&1 \
    || die "apply.sh wrote no log to /var/log/llangvilla/."
  ok "apply.sh logged to /var/log/llangvilla/"

  step "Applying it again: nothing should change"
  out=$(vm_sudo "$apply" 2>&1) || { printf '%s\n' "$out" >&2; die "The second run of config/apply.sh failed."; }
  if grep -Eq 'changed=[1-9]' <<<"$out"; then
    grep -E '^(changed|TASK)' <<<"$out" | grep -B1 '^changed' >&2 || true
    die "The second run changed things (above), so some task is not idempotent."
  else
    ok "Second run changed nothing"
  fi

  step "Rebooting to check the result comes up"
  vm_reboot
  sys_state=$(ssh "${S[@]}" "$vm_user@127.0.0.1" timeout 300 systemctl is-system-running --wait 2>&1 || true)
  [[ $sys_state == running ]] || {
    ssh "${S[@]}" "$vm_user@127.0.0.1" systemctl --failed --no-pager >&2 || true
    die "After applying the config, systemd is '$sys_state' (failed units above)."
  }
  ok "systemd: running, no failed units"
  ssh "${S[@]}" "$vm_user@127.0.0.1" systemctl is-active --quiet display-manager.service \
    || die "The display manager (login screen) is not active."
  ok "display manager (login screen) is active"
  ssh "${S[@]}" "$vm_user@127.0.0.1" grep -qw zswap.enabled=0 /proc/cmdline \
    || die "zswap.enabled=0 is not on the kernel command line after the reboot (boot role)."
  ok "zswap is off (kernel command line)"
  vm_screenshot login-after-config

  vm_down
  ok "Config applied cleanly. See it with: vm/test-vm.sh boot"
}

do_boot() {
  local show=${gui:-1}
  [[ -f $disk && -f $vars ]] || die "No installed VM disk. Run: vm/test-vm.sh install"
  need qemu-system-x86_64
  find_ovmf
  qemu_base "$disk" "$show"
  step "Booting the installed system"
  info "Log in as $(env_value USER_NAME jack) (password '$test_password' for a test install)"
  info "SSH from another terminal: vm/test-vm.sh ssh"
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
  [[ -f $key ]] || die "No test key yet. Run: vm/test-vm.sh install"
  ssh_opts
  exec ssh "${S[@]}" -o BatchMode=no "$(env_value USER_NAME jack)@127.0.0.1" "${ssh_args[@]}"
}

case $cmd in
  install) do_install ;;
  check)   do_check ;;
  config)  do_config ;;
  all)     do_install
           if [[ -n $stick_dev ]]; then info "Skipping check and config (--stick: the test key is not on that install)"
           else
             # A failed base check still lets the config phase run, so one run reports both.
             base_ok=1
             ( do_check ) || base_ok=0
             do_config
             (( base_ok )) || die "The base-system checks failed (see above); the config phase ran anyway."
           fi ;;
  boot)    do_boot ;;
  live)    do_live ;;
  ssh)     do_ssh ;;
  clean)   rm -f "$disk" "$live_disk" "$vars" "$state/OVMF_VARS.live.fd" "$stick_img" "$key" "$key.pub" "$test_env"
           ok "Removed the VM files in $state (logs kept in $state/logs)" ;;
esac
