#!/usr/bin/env bash
# config/apply.sh - personalise this machine from this repo (part 2, config/README.md).
# The one entrypoint for the config: the installer's first-boot hook runs it once,
# and you re-run it whenever the config changes. Safe to run again and again.
#
# Usage (as root):
#   sudo /opt/llangvilla/config/apply.sh             pull the checkout, then apply
#   sudo config/apply.sh --no-pull                   apply the files as they are
#   sudo config/apply.sh -- --check --diff           extra args go to ansible-playbook
#   sudo config/apply.sh -- --tags sddm
#
# Must not reboot or restart the display manager: at first boot it runs before the
# login screen (config/README.md, "Rules for the config").
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")

say()  { printf '\033[1;36m[apply]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[apply] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

pull=1 playbook_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-pull) pull=0 ;;
    --) shift; playbook_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)."

# 1. Update the checkout, then re-run the (possibly new) copy of this script.
if (( pull )); then
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    say "Pulling $repo..."
    git -c safe.directory="$repo" -C "$repo" pull --ff-only \
      || die "git pull failed (local changes or a diverged branch in $repo?). Use --no-pull to apply as is."
    exec bash "$here/apply.sh" --no-pull -- "${playbook_args[@]}"
  fi
  say "$repo is not a git checkout, applying it as it is."
fi

# 2. Tools the config needs. The installer only guarantees git and a base system.
if ! command -v ansible-playbook >/dev/null; then
  say "Installing ansible..."
  pacman -Syu --needed --noconfirm ansible || die "Could not install ansible."
fi

# 3. Apply. (Nix home-manager will slot in here as a second step.)
say "Running the Ansible playbook..."
export ANSIBLE_CONFIG="$here/ansible/ansible.cfg"
cd "$here/ansible"
ansible-playbook site.yml "${playbook_args[@]}"
say "Done."
