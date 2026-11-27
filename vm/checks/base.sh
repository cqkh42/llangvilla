#!/usr/bin/env bash
# The base-system checks (vm/test-vm.sh check), run ON THE VM as the test user:
# vm/test-vm.sh pipes this file to `bash -s` over SSH, with the expected values as
# environment variables. Prints one line per check; exits 1 if any failed.
# No `set -e`: every check runs, and the failures are counted.
# The helper functions below are called through `check NAME FUNCTION`, which
# ShellCheck can't follow.
# shellcheck disable=SC2329
# No pipefail: checks like `cmd | grep -q` must not fail when grep exits early.
set -u
: "${PW:?}" "${EXP_HOST:?}" "${EXP_USER:?}" "${EXP_REAL:?}" "${EXP_TZ:?}" "${EXP_LOCALE:?}" "${EXP_KERNELS:?}"
: "${EXP_WIFI?}" "${EXP_SSH_PW:?}" "${EXP_FIRSTBOOT?}" "${EXP_LOCK_ROOT:?}"   # WIFI, FIRSTBOOT may be empty
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
  local id
  for _ in $(seq 1 30); do
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
check "root fs is btrfs"           test "$(findmnt -no FSTYPE /)" = btrfs
check "/ is subvolume @"           bash -c 'findmnt -no OPTIONS / | grep -q "subvol=/@\(,\|$\)"'
for m in /home /var/log /var/cache/pacman/pkg /.snapshots; do check "$m is mounted" findmnt -n "$m"; done
check "fstab has no subvolid="     bash -c '! grep -q subvolid= /etc/fstab'
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
