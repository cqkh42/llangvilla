#!/usr/bin/env bash
# config/apply.sh - personalise this machine from this repo (part 2, config/README.md).
# The one entrypoint for the config: the installer's first-boot hook runs it once,
# and you re-run it whenever the config changes. Safe to run again and again.
#
# Usage (as root):
#   sudo /opt/llangvilla/config/apply.sh             pull, upgrade the system, then apply
#   sudo config/apply.sh --no-pull                   apply the files as they are
#   sudo config/apply.sh --no-upgrade -- --check --diff
#                                                    dry run; extra args go to ansible-playbook
#   sudo config/apply.sh -- --tags user_avatar       run one role (each role has its own tag)
#
# Every run does a full `pacman -Syu` first, unless --no-upgrade: on Arch, installing
# packages against a stale database is a partial upgrade (config/README.md).
# Afterwards it says if a reboot, a re-login or service restarts are needed.
#
# Must not reboot or restart the display manager: at first boot it runs before the
# login screen (config/README.md, "Writing tasks").
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")

say()  { printf '\033[1;36m[apply]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[apply] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

pull=1 upgrade=1 playbook_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-pull) pull=0 ;;
    --no-upgrade) upgrade=0 ;;
    --) shift; playbook_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)."

# One run at a time (first boot and a manual run must not overlap). The lock is on
# fd 9, which the re-run after `git pull` inherits, so it only takes the lock once.
if [[ ${LLANGVILLA_APPLY_LOCKED:-} != 1 ]]; then
  exec 9>/run/llangvilla-apply.lock
  flock -n 9 || die "Another apply.sh is already running."
  export LLANGVILLA_APPLY_LOCKED=1

  # Everything from here on also goes to a log file (the re-run inherits it). Keeps
  # the newest 20.
  log_dir=/var/log/llangvilla
  mkdir -p "$log_dir"
  log="$log_dir/apply-$(date +%Y%m%d-%H%M%S).log"
  : > "$log"   # exists before the cleanup below counts the files
  exec > >(exec 9>&-; tee -a "$log") 2>&1   # tee must not hold the lock
  say "Logging to $log"
  # shellcheck disable=SC2012  # our own fixed-pattern filenames
  ls -1t "$log_dir"/apply-*.log | tail -n +21 | xargs -r rm -f
fi

# After an upgrade, say what still runs old code. Never reboots or restarts anything
# itself (see "Writing tasks" in config/README.md).
report_restarts() {
  local maps pid cg unit own_cg session=0
  local -A units=()
  if [[ ! -d /usr/lib/modules/$(uname -r) ]]; then
    say "Reboot needed: the running kernel ($(uname -r)) was upgraded and its modules are gone."
    return 0   # a reboot covers everything below
  fi
  own_cg=$(cat /proc/self/cgroup 2>/dev/null || true)
  for maps in /proc/[0-9]*/maps; do
    pid=${maps#/proc/}; pid=${pid%/maps}
    # A file under /usr shown as "(deleted)" was replaced by the upgrade.
    grep -qE ' /usr/[^ ]+ \(deleted\)$' "$maps" 2>/dev/null || continue
    cg=$(cat "/proc/$pid/cgroup" 2>/dev/null) || continue
    [[ $cg == "$own_cg" ]] && continue   # this run's own shell
    case $cg in
      */user.slice/*) session=1 ;;
      */system.slice/*.service*) unit=${cg#*/system.slice/}; units[${unit%%/*}]=1 ;;
    esac
  done
  if (( session )); then
    say "Log out and in: a desktop or login session still uses replaced libraries."
  fi
  if (( ${#units[@]} )); then
    say "Services still using replaced libraries: ${!units[*]}"
    say "  Restart them with 'systemctl restart UNIT', or reboot (simplest)."
  fi
}

# 1. Update the checkout, then re-run the (possibly new) copy of this script.
if (( pull )); then
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    say "Pulling $repo..."
    git -c safe.directory="$repo" -C "$repo" pull --ff-only \
      || die "git pull failed (local changes or a diverged branch in $repo?). Use --no-pull to apply as is."
    rerun=(--no-pull)
    (( upgrade )) || rerun+=(--no-upgrade)
    exec bash "$here/apply.sh" "${rerun[@]}" -- "${playbook_args[@]}"
  fi
  say "$repo is not a git checkout, applying it as it is."
fi

# 2. Bring the system up to date, so the playbook installs against a current package
# database. Then the tools the config needs: the installer only guarantees git and a base.
# A run killed mid-transaction (power cut) leaves pacman's lock behind, and every
# later run would fail on it. Safe to remove when no pacman is running; this run
# holds the apply lock, so no other apply.sh is about to start one.
if [[ -e /var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null; then
  say "Removing a stale pacman lock (no pacman is running)."
  rm -f /var/lib/pacman/db.lck
fi
if (( upgrade )); then
  trap report_restarts EXIT   # also after a failed playbook: the upgrade happened
  say "Upgrading the system (pacman -Syu)..."
  pacman -Syu --noconfirm || die "System upgrade failed. Fix it, or use --no-upgrade to apply without one."
fi
if ! command -v ansible-playbook >/dev/null; then
  say "Installing ansible..."
  if (( upgrade )); then
    pacman -S --needed --noconfirm ansible || die "Could not install ansible."
  else
    pacman -Syu --needed --noconfirm ansible || die "Could not install ansible."
  fi
fi

# 3. Apply. The playbook ends with home-manager, the user layer (config/home).
say "Running the Ansible playbook..."
export ANSIBLE_CONFIG="$here/ansible/ansible.cfg"
cd "$here/ansible"
ansible-playbook site.yml "${playbook_args[@]}"
say "Done."
