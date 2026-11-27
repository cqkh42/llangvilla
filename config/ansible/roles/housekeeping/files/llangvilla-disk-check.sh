#!/bin/bash
# Written by config/ansible (housekeeping role). Edit the role, not this file.
# Weekly: are the disks healthy? Looks at SMART (every disk smartctl can see), btrfs's
# error counters on /, and the last monthly scrub. Problems go in the login message
# (and the desktop notice at login); a clean check removes it. Never fails its unit.
set -uo pipefail
notice=/etc/motd.d/llangvilla-disk
problems=()

# SMART: smartctl's exit status is a bit mask; 8 = the disk says it is failing,
# 16/32 = an attribute is (or was) past its failure threshold. Disks without SMART
# (a VM's virtual disk) are not listed by --scan.
while read -r dev _ type _; do
  [[ $dev == /dev/* ]] || continue
  smartctl -H -A "$dev" -d "$type" >/dev/null 2>&1
  rc=$?
  if (( rc & 8 )); then problems+=("$dev: SMART says the disk is FAILING. Back up now and replace it.")
  elif (( rc & 48 )); then problems+=("$dev: SMART attributes past their thresholds (smartctl -a $dev).")
  fi
done < <(smartctl --scan 2>/dev/null)

if [[ $(findmnt -no FSTYPE /) == btrfs ]]; then
  # Non-zero read, write, flush, corruption or generation errors since the install.
  if ! stats=$(btrfs device stats --check / 2>&1); then
    problems+=("btrfs reports errors on /: $(awk '$2 != 0 {printf "%s=%s ", $1, $2}' <<<"$stats")(btrfs device stats /).")
  fi
  # The last scrub (btrfs-scrub@-.timer, monthly) found checksum errors?
  scrub=$(btrfs scrub status / 2>/dev/null || true)
  if grep -q '^Error summary:' <<<"$scrub" && ! grep -q '^Error summary:.*no errors found' <<<"$scrub"; then
    problems+=("The last btrfs scrub of / found errors: $(sed -n 's/^Error summary: *//p' <<<"$scrub") (btrfs scrub status /).")
  fi
fi

if (( ${#problems[@]} )); then
  mkdir -p "${notice%/*}"
  { echo "Disk problems (checked weekly):"; printf '  %s\n' "${problems[@]}"; echo; } > "$notice"
  cat "$notice"
else
  rm -f "$notice"
  echo "No disk problems found."
fi
exit 0
