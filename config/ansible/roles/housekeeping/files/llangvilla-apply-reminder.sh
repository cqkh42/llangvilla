#!/bin/bash
# Written by config/ansible (housekeeping role). Edit the role, not this file.
# Daily: has config/apply.sh (which upgrades the system) run lately? If the last
# successful run is older than the limit, say so in the login message (and the
# desktop notice at login). apply.sh removes the notice when it succeeds.
set -uo pipefail
stamp=/var/lib/llangvilla/last-upgrade   # touched by apply.sh after a successful run with an upgrade
notice=/etc/motd.d/llangvilla-apply
max_days=${1:-14}

if [[ ! -e $stamp ]]; then
  echo "No successful apply.sh run recorded yet; nothing to check."
  exit 0
fi
days=$(( ($(date +%s) - $(stat -c %Y "$stamp")) / 86400 ))
if (( days > max_days )); then
  mkdir -p "${notice%/*}"
  printf '%s\n' "The system was last upgraded $days days ago." \
    "Upgrade and re-apply the config: sudo /opt/llangvilla/config/apply.sh" "" > "$notice"
  cat "$notice"
else
  rm -f "$notice"
  echo "Last apply: $days days ago (limit $max_days)."
fi
exit 0
