#!/bin/bash
# Runs INSIDE an Arch Linux Docker container. Builds the custom ISO.
set -euo pipefail

pacman -Syu --noconfirm archiso

rm -rf /tmp/profile /tmp/work
cp -r /usr/share/archiso/configs/releng /tmp/profile
cd /tmp/profile

# 1. extra packages on the live ISO
echo "jq" >> packages.x86_64

# 2. our installer script
install -Dm755 /work/install.sh airootfs/root/install.sh
sed -i '/^file_permissions=(/a\  ["/root/install.sh"]="0:0:755"' profiledef.sh
grep -q '/root/install.sh' profiledef.sh

# 3. ISO name
sed -i 's/^iso_name=.*/iso_name="arch-autoinstall"/' profiledef.sh

# 4. auto-run the installer when root logs in on tty1
cat >> airootfs/root/.zlogin <<'EOF'

# --- zero-touch install hook ---
if [[ $(tty) == /dev/tty1 && -z ${AUTOINSTALL_STARTED:-} ]]; then
    export AUTOINSTALL_STARTED=1
    /root/install.sh
fi
EOF

# 5. build
mkdir -p /work/out
mkarchiso -v -w /tmp/work -o /work/out /tmp/profile
echo "BUILD OK"
