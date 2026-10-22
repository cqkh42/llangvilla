# OptiPlex autoinstall: from repo to running box

How to turn `autoinstall/user-data` into a Ventoy USB stick, install Ubuntu Desktop
unattended on the OptiPlex, and end up with a machine that configures itself from this repo.

**The flow:** repo template → copy onto Ventoy stick → edit the placeholders on the stick →
boot the OptiPlex → unattended install → first-boot `ansible-pull` → running box.

> **Warning:** the install wipes the whole disk (`storage: layout: name: direct`).
> Back up anything on the OptiPlex you want to keep before booting the stick.

---

## 0. What you need

- A Linux machine to build on, with `git` and `whois` (for `mkpasswd`)
- A USB stick, 8 GB or more (it will be wiped)
- An **Ubuntu Desktop ISO, 24.04 or newer** (older desktop installers don't support autoinstall)
- [Ventoy](https://github.com/ventoy/Ventoy/releases) (Linux tarball)
- Your Wi-Fi SSID and password
- An Ubuntu Pro token (optional): <https://ubuntu.com/pro/dashboard>, starts with `C`

## 1. What's in the repo

| File | Purpose |
|---|---|
| `autoinstall/user-data` | The template. Contains four placeholders, never commit real values |
| `ansible/site.yml` | The playbook the first-boot `ansible-pull` runs. Must be a valid playbook |

Placeholders in `user-data`:

| Placeholder | Value |
|---|---|
| `__WIFI_SSID__` | Wi-Fi network name |
| `__WIFI_PASSWORD__` | Wi-Fi password |
| `__PASSWORD_HASH__` | SHA-512 hash of the `jack` login password (desktop, sudo, SSH) |
| `__UBUNTU_PRO_TOKEN__` | Ubuntu Pro token (delete the whole `ubuntu-pro:` block to skip Pro) |

Check the playbook before building anything. A broken `site.yml` means the first-boot service
retries forever:

```bash
git clone https://github.com/cqkh42/llangvilla.git && cd llangvilla
ansible-playbook --syntax-check ansible/site.yml
```

## 2. Check the ISO matches the template

`user-data` uses `source: id: ubuntu-desktop-minimal`. That ID must exist in the ISO:

```bash
sha256sum ubuntu-*-desktop-amd64.iso          # compare with the checksum on ubuntu.com
7z x -so ubuntu-*-desktop-amd64.iso casper/install-sources.yaml | grep -n 'id:'
```

If `ubuntu-desktop-minimal` isn't listed, change the `id:` in the template to one that is
(for example `ubuntu-desktop`).

## 3. Install Ventoy on the stick

Find the stick's device name **carefully**. Ventoy erases it.

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT      # the stick shows TRAN=usb, e.g. /dev/sdb
tar xzf ventoy-*-linux.tar.gz && cd ventoy-*/
sudo sh Ventoy2Disk.sh -i /dev/sdX            # replace sdX; use -I to force a reinstall
```

Unplug and replug the stick. Two partitions appear, `Ventoy` (big, exFAT) and `VTOYEFI`.
Everything below goes on the big one. Set `V` to its mount point:

```bash
V=/media/$USER/Ventoy        # adjust to wherever it mounted
```

## 4. Copy the ISO, Ventoy config and raw user-data onto the stick

Run this from the repo root:

```bash
mkdir -p "$V/ISO" "$V/ventoy/script"
cp ubuntu-*-desktop-amd64.iso "$V/ISO/ubuntu-desktop.iso"
cp autoinstall/user-data "$V/ventoy/script/user-data"

cat > "$V/ventoy/ventoy.json" <<'EOF'
{
  "auto_install": [
    {
      "image": "/ISO/ubuntu-desktop.iso",
      "template": "/ventoy/script/user-data"
    }
  ]
}
EOF
```

## 5. Edit the placeholders on the stick

Open the copy **on the stick** (not the one in the repo) in an editor:

```bash
nano "$V/ventoy/script/user-data"
```

Replace each placeholder, keeping the surrounding double quotes:

| Find | Replace with |
|---|---|
| `"__WIFI_SSID__":` | your Wi-Fi name, e.g. `"MyHomeWifi":` |
| `"__WIFI_PASSWORD__"` | your Wi-Fi password |
| `"__PASSWORD_HASH__"` | the hash from `mkpasswd -m sha-512` (run it in another terminal; it prompts for the `jack` password and prints the hash. Paste it as is, including the `$` signs) |
| `"__UBUNTU_PRO_TOKEN__"` | your Pro token, or delete the whole `ubuntu-pro:` block (and its two comment lines above it) |

Gotchas:

- Inside the double quotes, a `"` or `\` in your Wi-Fi name or password must be written as
  `\"` or `\\`. Anything else is fine as is.
- Keep the indentation exactly as it was. YAML is whitespace-sensitive.

Check that nothing was missed:

```bash
grep -n '__' "$V/ventoy/script/user-data"     # must print nothing
```

Then `sync` and unmount the stick.

## 6. Install on the OptiPlex

1. **Plug the stick in, power on, and press F12** for the one-time boot menu. Pick the USB stick.
2. **Secure Boot:** the first time you boot Ventoy with Secure Boot on, a blue MokManager
   screen appears. Choose *Enroll key from disk*, select the `ENROLL_THIS_KEY_IN_MOKMANAGER.cer`
   file from the `VTOYEFI` partition, then reboot and boot the stick again. (Alternative: turn
   Secure Boot off in the BIOS.)
3. Choose the Ubuntu ISO in the Ventoy menu. If Ventoy offers a choice of boot modes, pick the
   auto-install template entry, and let it run. It may ask one confirmation prompt
   ("Continue with autoinstall?"), which is normal. The install takes a while: it installs from
   the ISO, attaches Pro, and downloads `ansible` and `git`, so the box needs its Wi-Fi (or an
   Ethernet cable) to work.
4. When it reboots, **remove the stick** so it doesn't boot the installer again.

**If the installer reports no disk found:** in the BIOS, set *SATA Operation* to **AHCI**
(Dell machines sometimes default to RAID/Intel RST, which hides the NVMe drive from Linux).

## 7. Verify the first boot

The first-boot service waits for the network and retries every 60 seconds until `ansible-pull`
succeeds. Log in as `jack` with the password you hashed, then:

```bash
systemctl status ansible-pull-firstboot        # "active (exited)" when done
journalctl -u ansible-pull-firstboot -b        # full ansible output
ls /var/lib/ansible-pull-firstboot.done        # exists once the first pull succeeded
groups jack                                     # includes kvm once the playbook has run
pro status                                      # Ubuntu Pro attached (if you gave a token)
```

To re-run the first-boot pull from scratch:

```bash
sudo rm /var/lib/ansible-pull-firstboot.done
sudo systemctl start ansible-pull-firstboot
```

## 8. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Installer is interactive (asks for language, disk, user) | Ventoy didn't pass the template to the installer. Check the `auto_install` entry in `ventoy/ventoy.json` and that the image path matches the ISO filename |
| Installer errors on a config section | A placeholder was left in, or a value broke the YAML (unescaped `"` or `\`, changed indentation). Re-check section 5 |
| "Source not found" or similar | `source: id:` isn't in the ISO. See section 2 |
| No Wi-Fi after install | Wrong SSID/password, or no Wi-Fi card detected. Plug in Ethernet |
| `ansible-pull-firstboot` keeps restarting | Read `journalctl -u ansible-pull-firstboot`. Usually no network yet, or a broken `site.yml` |
| Pro not attached | Bad or expired token, or no network during install. Run `sudo pro attach <token>` |
| Installer logs | `/var/log/installer/` on the installed system. These contain the filled-in values, so don't share them |

## 9. Housekeeping

- The stick now holds your Wi-Fi password, password hash and Pro token in plain text. Re-format
  it (re-run `Ventoy2Disk.sh -I`) or delete `ventoy/script/user-data` once the install works.
- Only `autoinstall/user-data` (placeholders intact) lives in git. Never commit an edited copy.
