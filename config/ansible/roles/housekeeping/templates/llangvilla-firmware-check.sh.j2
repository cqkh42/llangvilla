#!/bin/bash
# Written by config/ansible (housekeeping role). Edit the role, not this file.
# Checks LVFS for firmware updates and says so in the login message. Never installs:
# that is `sudo fwupdmgr update`, then a reboot. A failed check (offline, say) leaves
# the notice as it was and doesn't fail the unit.
set -uo pipefail
notice=/etc/motd.d/llangvilla-firmware

fwupdmgr refresh --force --assume-yes >/dev/null 2>&1 \
  || echo "Could not refresh the firmware metadata (offline?); checking with what is there."
fwupdmgr get-updates --no-unreported-check --assume-yes >/dev/null 2>&1
rc=$?
case $rc in
  0) mkdir -p "${notice%/*}"
     printf '%s\n' \
       "Firmware updates are available (fwupd). See them: fwupdmgr get-updates" \
       "Install: sudo fwupdmgr update, then reboot." "" > "$notice"
     echo "Firmware updates are available." ;;
  2) rm -f "$notice"   # fwupd's "nothing to do": no updates, or no updatable devices
     echo "No firmware updates." ;;
  *) echo "The firmware check failed (fwupdmgr exit $rc); the notice is unchanged." ;;
esac
exit 0
