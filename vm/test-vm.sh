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
#             reboots, checks the login screen comes up, logs in (test-only
#             autologin) to check the desktop, re-applies, powers off. Repeatable on
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
#   --no-firstboot   install a plain base (CONFIG_REPO_URL=''). By default the
#                    installed system runs the real first-boot hook against a
#                    snapshot of the working tree, served to the VM over HTTP (clone,
#                    config/apply.sh, reboot), and `check` waits for it
#   --baked          use the install.sh baked into the ISO. By default the working
#                    tree's install.sh goes on the test stick and replaces it, so
#                    installer changes can be tested without rebuilding the ISO
#   --stick DEV      install from a REAL stick (e.g. /dev/sdb) instead of the ISO +
#                    test stick, exactly as the real machine would (needs sudo). Its
#                    own autoinstall.env is used, so `check` cannot log in; use `boot`.
#   --gui / --headless   show or hide the VM window (default: shown for boot/live only)
#   --disk-size GB   size of the virtual target disk (default 60)
#   --timeout MIN    give up on the install after this long (default 90). Every SSH
#                    command after it has a time limit too (5 min; longer for applies)
#
# Environment: OVMF_CODE / OVMF_VARS (firmware files, found automatically on Arch,
# Debian/Ubuntu and Fedora), VM_SSH_PORT (2222), VM_GIT_PORT (8418, the working-tree
# snapshot for the first-boot hook), VM_MEMORY (4G), TEST_PASSWORD (test).
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
git_port="${VM_GIT_PORT:-8418}"
git_srv="$state/worktree-git"        # the snapshot the first-boot hook clones
git_url="http://10.0.2.2:${git_port}/llangvilla.git"   # 10.0.2.2: the host, from the VM

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
iso="${ISO:-}" base_env="$ai/autoinstall.env.example" firstboot=1 baked=0 stick_dev=""
gui="" disk_size=60 timeout_min=90 ssh_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)       iso=$2; shift ;;
    --env)       base_env=$2; shift ;;
    --no-firstboot) firstboot=0 ;;
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

# One shared connection for all of the test's commands (ControlMaster): faster, and
# the config's firewall rate-limits SSH (6 new connections in 30 s per address).
# Keepalives notice a dead connection after a reboot; ssh_close ends it on purpose.
ssh_opts() {
  S=(-i "$key" -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR
     -o ControlMaster=auto -o "ControlPath=$state/ssh-%C" -o ControlPersist=60
     -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
}
ssh_close() { ssh "${S[@]}" -O exit "${vm_user:-x}@127.0.0.1" 2>/dev/null || true; }

# Every SSH command the test runs is time-limited, so a command that hangs on the VM
# fails its step in minutes instead of stalling the run until CI's own job limit
# (issue #27). The default suits checks; steps that take longer set their own:
#   ssh_limit=2400 vm_sudo "$apply"
# (`exec ssh`, the interactive `ssh` command, has no limit.)
ssh_limit_default=300
ssh() {
  local limit=${ssh_limit:-$ssh_limit_default} rc=0 what=${*: -1}
  # The binary, not this function (and not `command`: timeout runs programs only).
  timeout --foreground "$limit" "$(type -P ssh)" "$@" || rc=$?
  if (( rc == 124 )); then
    (( ${#what} > 100 )) && what="${what:0:100}..."
    warn "An SSH command timed out after ${limit} s: $what"
  fi
  return "$rc"
}

# Values the test env sets, read in a subshell so they cannot clobber ours.
# shellcheck source=/dev/null
env_value() { (set +u; source "$test_env" >/dev/null 2>&1; printf '%s' "${!1:-${2:-}}"); }

# A snapshot of the working tree, uncommitted and untracked (not ignored) files
# included, as a bare repo the VM can clone over git's "dumb HTTP" (plain files).
snapshot_worktree() {
  local idx tree commit out
  need git python3
  idx=$(mktemp)
  GIT_INDEX_FILE=$idx git -C "$repo" read-tree HEAD
  GIT_INDEX_FILE=$idx git -C "$repo" add -A
  tree=$(GIT_INDEX_FILE=$idx git -C "$repo" write-tree)
  rm -f "$idx"
  commit=$(GIT_AUTHOR_NAME=test-vm GIT_AUTHOR_EMAIL=test-vm@localhost GIT_COMMITTER_NAME=test-vm \
           GIT_COMMITTER_EMAIL=test-vm@localhost git -C "$repo" commit-tree -m "vm test snapshot" "$tree")   # no parent: CI checkouts are shallow
  rm -rf "$git_srv"
  git init -q --bare "$git_srv/llangvilla.git"
  # A shallow checkout (CI's) prints push-negotiation noise; show it only on failure.
  out=$(git -C "$repo" push -q "$git_srv/llangvilla.git" "$commit:refs/heads/main" 2>&1) \
    || { printf '%s\n' "$out" >&2; die "Could not store the working-tree snapshot."; }
  git -C "$git_srv/llangvilla.git" symbolic-ref HEAD refs/heads/main
  git -C "$git_srv/llangvilla.git" update-server-info
  ok "Working-tree snapshot for the first-boot hook: ${commit:0:12}"
}

# Serve the snapshot while the VM runs (its first boot clones from it). Host loopback
# only: QEMU's user networking maps the VM's 10.0.2.2 to it.
git_server_pid=""
serve_worktree() {
  [[ $(env_value CONFIG_REPO_URL) == "$git_url" ]] || return 0
  [[ -d $git_srv/llangvilla.git ]] || die "No working-tree snapshot in $git_srv. Run: vm/test-vm.sh install"
  python3 -m http.server --bind 127.0.0.1 --directory "$git_srv" "$git_port" >/dev/null 2>&1 &
  git_server_pid=$!
  sleep 1
  kill -0 "$git_server_pid" 2>/dev/null || die "Could not serve the snapshot on port $git_port (in use? set VM_GIT_PORT)."
}

# Stop what vm_up started (on exit, or from vm_down).
# (`kill … || true`: under set -e a failing kill would end the script, and QEMU has
# usually exited by itself after a poweroff.)
cleanup() {
  if [[ -n ${qemu_pid:-} ]]; then kill "$qemu_pid" 2>/dev/null || true; fi
  if [[ -n $git_server_pid ]]; then kill "$git_server_pid" 2>/dev/null || true; fi
}

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
    if (( firstboot )); then
      echo "CONFIG_REPO_URL='$git_url'"
      echo "CONFIG_REPO_BRANCH=main"
    else
      echo "CONFIG_REPO_URL=''"
    fi
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
    sleep 10   # every 5 s would trip the firewall's SSH rate limit (6 in 30 s)
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

# Run a script, given on stdin, as root on the VM (stdin of vm_sudo is the password).
vm_root_sh() {
  local f="/tmp/vm-test-$$-$RANDOM.sh"
  # shellcheck disable=SC2029  # expanding on the client side is the point
  ssh "${S[@]}" "$vm_user@127.0.0.1" "cat > $f" || return 1
  vm_sudo bash "$f"
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
  serve_worktree
  "${Q[@]}" &
  qemu_pid=$!
  trap cleanup EXIT
  wait_ssh $(( SECONDS + 15 * 60 )) "boot" || die "SSH did not come up within 15 minutes."
  ok "SSH is up"
}

vm_down() {
  step "Powering the VM off"
  vm_sudo systemctl poweroff 2>/dev/null || true
  ssh_close
  for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 2; done
  cleanup
  trap - EXIT
}

vm_reboot() {
  info "Rebooting the VM..."
  vm_sudo systemctl reboot 2>/dev/null || true
  ssh_close
  sleep 30
  wait_ssh $(( SECONDS + 10 * 60 )) "after the reboot" || die "SSH did not come back after the reboot."
}

# Unless --no-firstboot, the installed system runs the first-boot hook (and reboots once).
# On failure: the hook's journal and the newest apply.sh log, then stop.
firstboot_failed() {
  ssh "${S[@]}" "$vm_user@127.0.0.1" journalctl -u llangvilla-firstboot.service -b --no-pager 2>/dev/null | tail -n 40 >&2 || true
  # shellcheck disable=SC2016  # $ expands on the VM
  vm_sudo 'bash -c "f=\$(ls -1t /var/log/llangvilla/apply-*.log 2>/dev/null | head -n1); [ -n \"\$f\" ] && { echo \"--- \$f\"; tail -n 60 \"\$f\"; }"' >&2 || true
  die "$1 (journal and apply log above)."
}

wait_firstboot() {
  local deadline waited=0
  [[ -n $(env_value CONFIG_REPO_URL) ]] || return 0
  info "Waiting for the first-boot hook to finish (up to 25 min)..."
  deadline=$(( SECONDS + 25 * 60 ))
  until ssh "${S[@]}" "$vm_user@127.0.0.1" test -e /var/lib/llangvilla/firstboot.done 2>/dev/null; do
    waited=1
    if ssh "${S[@]}" "$vm_user@127.0.0.1" systemctl is-failed --quiet llangvilla-firstboot.service 2>/dev/null; then
      firstboot_failed "The first-boot hook failed"
    fi
    (( SECONDS < deadline )) || firstboot_failed "The first-boot hook did not finish within 25 minutes"
    sleep 10
  done
  ok "First-boot hook finished"
  # Its reboot happened already if the marker was there when we looked.
  if (( waited )) && [[ $(env_value FIRSTBOOT_REBOOT_AFTER 1) == 1 ]]; then
    info "Waiting for its automatic reboot..."
    ssh_close
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
    if (( firstboot )); then snapshot_worktree; fi
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
  printf -v remote 'PW=%q EXP_HOST=%q EXP_USER=%q EXP_REAL=%q EXP_TZ=%q EXP_LOCALE=%q EXP_KERNELS=%q EXP_WIFI=%q EXP_SSH_PW=%q EXP_FIRSTBOOT=%q EXP_LOCK_ROOT=%q bash -s' \
    "$test_password" "$(env_value HOST_NAME)" "$vm_user" "$(env_value REAL_NAME)" \
    "$(env_value TIMEZONE)" "$(env_value LOCALE)" "$(env_value KERNELS linux)" \
    "$(env_value WIFI_SSID)" "$(env_value SSH_PASSWORD_AUTH 0)" "$(env_value CONFIG_REPO_URL)" "$(env_value LOCK_ROOT 1)"
  # shellcheck disable=SC2029  # expanding on the client side is the point
  # Up to 5 minutes for systemd to settle, 1 for the login screen.
  ssh_limit=600 ssh "${S[@]}" "$vm_user@127.0.0.1" "$remote" < "$repo/vm/checks/base.sh" || fails=1

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

# With from_firstboot=1 (`all`), the first-boot hook has already applied the
# working-tree snapshot it cloned to /opt/llangvilla: re-apply that checkout. Otherwise
# (`config`, the quick loop) copy the working tree's config/ and apply it first.
do_config() {
  local from_firstboot=${1:-0} out apply="/home/\$USER/$worktree_dir/config/apply.sh --no-pull" sys_state
  vm_up
  wait_firstboot
  clear_desktop_test

  if (( from_firstboot )); then
    apply="/opt/llangvilla/config/apply.sh --no-pull"
    ok "The first-boot hook applied the working tree (its checkout: /opt/llangvilla)"
  else
    step "Copying the working tree's config/ to the VM (~/$worktree_dir)"
    # shellcheck disable=SC2029  # expanding on the client side is the point
    tar -C "$repo" --exclude='*.retry' -cz config \
      | ssh "${S[@]}" "$vm_user@127.0.0.1" "rm -rf ~/$worktree_dir && mkdir ~/$worktree_dir && tar -xz -C ~/$worktree_dir"
    ok "Copied"

    step "Applying the config (config/apply.sh --no-pull)"
    ssh_limit=2400 vm_sudo "$apply" || die "config/apply.sh failed (output above)."
    ok "Config applied"
  fi
  # shellcheck disable=SC2016  # $ expands on the VM
  ssh "${S[@]}" "$vm_user@127.0.0.1" 'systemctl is-enabled --quiet reflector.timer && pacman -Q base-devel man-db man-pages >/dev/null' \
    || die "The mirrors or packages role is incomplete (reflector.timer, base-devel, man-db, man-pages)."
  ok "Mirror refresh scheduled; build tools and man pages installed"

  ssh "${S[@]}" "$vm_user@127.0.0.1" test -L .local/state/nix/profiles/home-manager \
    || die "home-manager produced no generation for $vm_user."
  ok "home-manager applied the user layer"
  ssh "${S[@]}" "$vm_user@127.0.0.1" 'ls /var/log/llangvilla/apply-*.log' >/dev/null 2>&1 \
    || die "apply.sh wrote no log to /var/log/llangvilla/."
  ok "apply.sh logged to /var/log/llangvilla/"

  # Three fake old snapshots, so the second run's pruning (newest 3 kept) has work to do.
  # How many real ones exist already depends on the mode (first boot, then maybe a
  # test apply) and on earlier runs on a reused VM, so record the list for the check.
  vm_root_sh <<'SH' || die "Could not add fake old snapshots to /.snapshots."
set -e
for i in 1 2 3; do btrfs subvolume snapshot -r / "/.snapshots/before-upgrade-20000101-00000$i" >/dev/null; done
printf '%s\n' /.snapshots/before-upgrade-* >/run/llangvilla-test-snapshots
SH

  step "Applying it again: nothing should change"
  # --diff: a task that changes something shows exactly what.
  out=$(ssh_limit=2400 vm_sudo "$apply -- --diff" 2>&1) || { printf '%s\n' "$out" >&2; die "The second run of config/apply.sh failed."; }
  if grep -Eq 'changed=[1-9]' <<<"$out"; then
    # Each changed task with its diff: from its TASK line to the next task.
    awk '/^TASK /{block=$0; keep=0; next} {block=block "\n" $0} /^changed:/{keep=1} keep && /^$/{print block; keep=0}' <<<"$out" >&2 || true
    die "The second run changed things (above), so some task is not idempotent."
  else
    ok "Second run changed nothing"
  fi

  step "A dry run: changes nothing, and still builds the user layer"
  out=$(ssh_limit=1200 vm_sudo "$apply --dry-run" 2>&1) || { printf '%s\n' "$out" >&2; die "apply.sh --dry-run failed."; }
  grep -q 'Build the user layer without switching' <<<"$out" || { printf '%s\n' "$out" >&2; die "The dry run didn't build the user layer."; }
  if grep -Eq 'changed=[1-9]' <<<"$out"; then printf '%s\n' "$out" >&2; die "The dry run reports changes right after a clean run."; fi
  ok "Dry run: no changes, user layer built"

  # The second run took one more snapshot (the dry run takes none), then pruned: of the
  # snapshots before it plus that one, exactly the newest 3 must be left.
  vm_root_sh <<'SH' || die "Snapshots before upgrades are wrong (above)."
snaps=(/.snapshots/before-upgrade-*)
printf '  %s\n' "${snaps[@]}"
mapfile -t before </run/llangvilla-test-snapshots
[[ ${#snaps[@]} == 3 ]] || { echo "expected the newest 3 snapshots, found ${#snaps[@]}"; exit 1; }
[[ " ${before[*]} " != *" ${snaps[2]} "* ]] || { echo "the second run took no new snapshot"; exit 1; }
mapfile -t want < <(printf '%s\n' "${before[@]}" "${snaps[2]}" | sort | tail -n 3)
[[ ${snaps[*]} == "${want[*]}" ]] || { echo "the oldest snapshots were not the ones deleted (expected: ${want[*]})"; exit 1; }
for s in "${snaps[@]}"; do
  [[ $(btrfs property get -ts "$s" ro) == ro=true ]] || { echo "$s is not read-only"; exit 1; }
done
SH
  ok "Snapshots before upgrades: the newest 3 kept, read-only"

  # packages_remove (empty in the repo): install a small package by hand, then apply
  # only the packages role with it in the list. It must be gone afterwards.
  step "Removing a package with packages_remove"
  ssh_limit=600 vm_sudo pacman -S --needed --noconfirm cowsay >/dev/null || die "Could not install the test package (cowsay)."
  out=$(ssh_limit=900 vm_sudo "$apply --no-upgrade -- --tags packages -e '{\"packages_remove\": [\"cowsay\"]}'" 2>&1) \
    || { printf '%s\n' "$out" >&2; die "apply.sh with packages_remove failed."; }
  if ssh "${S[@]}" "$vm_user@127.0.0.1" pacman -Q cowsay >/dev/null 2>&1; then
    printf '%s\n' "$out" >&2; die "packages_remove left cowsay installed."
  fi
  ok "packages_remove removed the package"

  step "Checking the housekeeping timers and services"
  local timer timers=""
  for timer in paccache btrfs-scrub@- llangvilla-nix-cleanup llangvilla-firmware-check \
               llangvilla-disk-check llangvilla-apply-reminder; do timers+="$timer.timer "; done
  vm_sudo systemctl is-enabled --quiet "$timers" || die "A housekeeping timer is not enabled (one of: $timers)."
  ssh_limit=900 vm_sudo systemctl start llangvilla-nix-cleanup.service \
    || { vm_sudo journalctl -u llangvilla-nix-cleanup.service -b --no-pager -o cat >&2 || true; die "The Nix cleanup failed (journal above)."; }
  ok "Nix cleanup ran"
  # The VM has no updatable firmware, so the check must say so (it never fails its unit).
  ssh_limit=600 vm_sudo systemctl start llangvilla-firmware-check.service || die "The firmware check service failed."
  out=$(vm_sudo journalctl -u llangvilla-firmware-check.service -b --no-pager -o cat 2>&1 || true)
  grep -q '^No firmware updates\.$' <<<"$out" \
    || { printf '%s\n' "$out" >&2; die "The firmware check didn't run cleanly (journal above)."; }
  ok "Firmware check ran (no updates, as expected in a VM)"
  # The VM's virtio disk has no SMART and a fresh btrfs has no errors.
  ssh_limit=600 vm_sudo systemctl start llangvilla-disk-check.service || die "The disk check service failed."
  out=$(vm_sudo journalctl -u llangvilla-disk-check.service -b --no-pager -o cat 2>&1 || true)
  grep -q '^No disk problems found\.$' <<<"$out" \
    || { printf '%s\n' "$out" >&2; die "The disk check didn't run cleanly (journal above)."; }
  ok "Disk check ran (no problems)"
  # apply.sh has just upgraded, so the reminder must count 0 days and leave no notice.
  vm_sudo systemctl start llangvilla-apply-reminder.service || die "The apply reminder service failed."
  out=$(vm_sudo journalctl -u llangvilla-apply-reminder.service -b --no-pager -o cat 2>&1 || true)
  grep -q '^Last apply: 0 days ago' <<<"$out" \
    || { printf '%s\n' "$out" >&2; die "The apply reminder didn't see the last upgrade (journal above)."; }
  ok "Apply reminder ran (last upgrade: today)"

  step "Rebooting to check the result comes up"
  vm_reboot
  sys_state=$(ssh_limit=420 ssh "${S[@]}" "$vm_user@127.0.0.1" timeout 300 systemctl is-system-running --wait 2>&1 || true)
  [[ $sys_state == running ]] || {
    ssh "${S[@]}" "$vm_user@127.0.0.1" systemctl --failed --no-pager >&2 || true
    die "After applying the config, systemd is '$sys_state' (failed units above)."
  }
  ok "systemd: running, no failed units"
  check_config_results
  ssh "${S[@]}" "$vm_user@127.0.0.1" systemctl is-active --quiet display-manager.service \
    || die "The display manager (login screen) is not active."
  ok "display manager (login screen) is active"
  ssh "${S[@]}" "$vm_user@127.0.0.1" grep -qw zswap.enabled=0 /proc/cmdline \
    || die "zswap.enabled=0 is not on the kernel command line after the reboot (boot role)."
  ok "zswap is off (kernel command line)"
  out=$(vm_sudo ufw status verbose 2>&1) || { printf '%s\n' "$out" >&2; die "ufw status failed."; }
  if ! { grep -q '^Status: active' <<<"$out" &&
         grep -q '^Default: deny (incoming), allow (outgoing)' <<<"$out" &&
         grep -Eq '^22/tcp +LIMIT IN' <<<"$out"; }; then
    printf '%s\n' "$out" >&2
    die "The firewall is not as the firewall role sets it (ufw status above)."
  fi
  ok "Firewall: incoming blocked, SSH rate-limited (and still reachable)"
  vm_screenshot login-after-config

  check_desktop "$apply"

  vm_down
  ok "Config applied cleanly. See it with: vm/test-vm.sh boot"
}

# What the config produces, file by file, after it has been applied. Expected values
# come from config/home/theme.json (the look) and the roles' defaults; settings that
# Plasma applies only at login are not checked here.
check_config_results() {
  local remote fails=0
  step "Checking what the config produced"
  remote=$(python3 - "$repo/config/home/theme.json" "$test_password" "$repo/config/home/host.json" <<'PY'
import json, shlex, sys
t = json.load(open(sys.argv[1]))
h = json.load(open(sys.argv[3]))
v = {
    "PW": sys.argv[2], "KEYBOARD": h["keyboardLayout"], "LNF": t["lookAndFeel"],
    "SCHEME": t["colorScheme"], "ICONS": t["iconTheme"], "GTK": t["gtkTheme"],
    "PLASMA": t["plasmaTheme"], "DECO": t["windowDecoration"].removeprefix("__aurorae__svg__"),
    "CURSOR": t["cursor"]["theme"], "CURSOR_SIZE": str(t["cursor"]["size"]),
    "FONT": t["font"]["family"], "FONT_SIZE": str(t["font"]["size"]),
    "WP_NAME": t["wallpaper"]["name"], "WP_SIZE": t["wallpaper"]["size"],
}
print(" ".join(f"{k}={shlex.quote(x)}" for k, x in v.items()) + " bash -s")
PY
)
  # shellcheck disable=SC2029  # expanding on the client side is the point
  ssh "${S[@]}" "$vm_user@127.0.0.1" "$remote" < "$repo/vm/checks/config.sh" || fails=1
  (( fails == 0 )) || die "The config didn't produce everything it should (see above)."
  ok "Everything the config sets is in place"
}

# check_desktop's test autologin and notice. A run that stopped part-way through it
# leaves them on the disk, which `config` reuses: clear them before checking anything.
desktop_test_dropin=/etc/plasmalogin.conf.d/99-vm-test-autologin.conf
desktop_test_notice=/etc/motd.d/llangvilla-vmtest
clear_desktop_test() {
  vm_sudo rm -f "$desktop_test_dropin" "$desktop_test_notice" \
    || die "Could not remove an earlier run's test autologin ($desktop_test_dropin) and notice."
}

# Log in through a test-only autologin (never part of config/), check what Plasma
# applies at login, then re-apply ($1: the config phase's apply command) with the
# session running: Plasma's GTK sync may
# have replaced home-manager's GTK files, and that must not fail the switch.
check_desktop() {
  local apply=$1 scheme gtk_files=(.gtkrc-2.0 .config/gtk-3.0/settings.ini .config/gtk-4.0/settings.ini) f replaced=()
  local dropin=$desktop_test_dropin
  scheme=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["colorScheme"])' "$repo/config/home/theme.json")

  step "Logging in (test-only autologin) to check the desktop"
  # The keys are SDDM's (PLM is its fork). The man page's autologin part is printed for
  # the log, in case this PLM build names them differently. (Not the binary: it has no
  # --example-config and starts the login manager instead.)
  vm_root_sh <<SH || die "Could not set up the test autologin."
set -e
echo "  PLM's documented autologin settings (man plasmalogin.conf):"
timeout 10 man -P cat plasmalogin.conf 2>/dev/null </dev/null | grep -i -A3 -E 'autologin|^ *(User|Session|Relogin)=' | head -n 30 | sed 's/^/    /' || echo "    (no man page)"
test -f /usr/share/wayland-sessions/plasma.desktop
mkdir -p ${dropin%/*}
printf '[Autologin]\nUser=%s\nSession=plasma\n' "$vm_user" > $dropin
# A notice, for notices.nix to show at login. /etc/motd.d only exists once a check
# has written one (they mkdir it themselves), so make it here too.
mkdir -p /etc/motd.d
printf 'VM test notice: shown at desktop login.\n' > $desktop_test_notice
SH
  vm_reboot
  ssh "${S[@]}" "$vm_user@127.0.0.1" \
    'for i in $(seq 1 90); do pgrep -u "$USER" -x plasmashell >/dev/null && exit 0; sleep 2; done; exit 1' \
    || die "No Plasma session for $vm_user within 3 minutes of the reboot (autologin keys wrong? see above)."
  ok "Plasma session running for $vm_user"
  info "Giving plasma-manager's login script time to apply..."
  sleep 45
  vm_screenshot desktop-after-login

  # plasma-manager's apply_themes login script runs plasma-apply-colorscheme, which
  # copies the colours into kdeglobals and may record only ColorSchemeHash (the SHA-1
  # of the scheme file), not ColorScheme, as on the login screen (vm/checks/config.sh).
  # shellcheck disable=SC2029  # expanding on the client side is the point
  if ! ssh "${S[@]}" "$vm_user@127.0.0.1" \
    "h=\$(sha1sum /usr/share/color-schemes/$scheme.colors | cut -d' ' -f1) && grep -qx -e 'ColorScheme=$scheme' -e \"ColorSchemeHash=\$h\" .config/kdeglobals"; then
    # shellcheck disable=SC2016  # expands in the VM
    ssh "${S[@]}" "$vm_user@127.0.0.1" \
      'echo "  kdeglobals [General]:"; sed -n "/^\[General\]/,/^\[/p" .config/kdeglobals | sed "s/^/    /"
       f=.local/share/plasma-manager/last_run_script_apply_themes
       if [ -f "$f" ]; then echo "  apply_themes login script: succeeded"; else echo "  apply_themes login script: did not succeed (no $f)"; fi' >&2 || true
    die "The colour scheme in ~/.config/kdeglobals is not $scheme after login (plasma-manager; details above)."
  fi
  ok "Colour scheme $scheme applied at login"

  # plasma-manager records each login script that succeeded; the panels (top bar and
  # dock) and the wallpaper are desktop scripts, which fail silently without qdbus.
  for f in desktop_script_panels desktop_script_wallpaper_picture; do
    ssh "${S[@]}" "$vm_user@127.0.0.1" test -f ".local/share/plasma-manager/last_run_$f" \
      || die "plasma-manager's $f did not succeed at login (panels or wallpaper not applied; qdbus missing?)."
  done
  ok "Panels and wallpaper applied at login (plasma-manager's desktop scripts)"

  # notices.nix logs each notice its notification service accepted.
  out=$(vm_sudo journalctl -b -t llangvilla-notices --no-pager -o cat 2>&1 || true)
  grep -qx 'shown llangvilla-vmtest' <<<"$out" \
    || { printf '%s\n' "${out:-nothing logged}" >&2; die "The test notice was not shown at login (notices.nix; journal above)."; }
  ok "The pending notice was shown as a desktop notification (screenshot: desktop-after-login)"

  for f in "${gtk_files[@]}"; do
    ssh "${S[@]}" "$vm_user@127.0.0.1" test -L "$f" || replaced+=("$f")
  done
  if (( ${#replaced[@]} )); then
    info "Plasma replaced home-manager's GTK files at login: ${replaced[*]}"
  else
    info "Plasma left home-manager's GTK files alone at login"
  fi

  step "Re-applying with the session running (GTK files must not clash)"
  ssh_limit=2400 vm_sudo "$apply" \
    || die "Re-applying after a login failed (output above): a home-manager clash?"
  for f in "${gtk_files[@]}"; do
    ssh "${S[@]}" "$vm_user@127.0.0.1" test -L "$f" || die "$f (in the home directory) is not home-manager's file after re-applying."
  done
  ok "Re-applied cleanly; the GTK files are home-manager's again"

  clear_desktop_test
}

do_boot() {
  local show=${gui:-1}
  [[ -f $disk && -f $vars ]] || die "No installed VM disk. Run: vm/test-vm.sh install"
  need qemu-system-x86_64
  find_ovmf
  qemu_base "$disk" "$show"
  step "Booting the installed system"
  info "Log in as $(env_value USER_NAME) (password '$test_password' for a test install)"
  info "SSH from another terminal: vm/test-vm.sh ssh"
  info "Changes persist on $disk until the next install"
  # Not exec: the first boot after an install clones from the served snapshot.
  serve_worktree
  trap cleanup EXIT
  "${Q[@]}"
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
  exec ssh "${S[@]}" -o BatchMode=no "$(env_value USER_NAME)@127.0.0.1" "${ssh_args[@]}"
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
             do_config "$firstboot"
             (( base_ok )) || die "The base-system checks failed (see above); the config phase ran anyway."
           fi ;;
  boot)    do_boot ;;
  live)    do_live ;;
  ssh)     do_ssh ;;
  clean)   rm -f "$disk" "$live_disk" "$vars" "$state/OVMF_VARS.live.fd" "$stick_img" "$key" "$key.pub" "$test_env"
           rm -rf "$git_srv"
           ok "Removed the VM files in $state (logs kept in $state/logs)" ;;
esac
