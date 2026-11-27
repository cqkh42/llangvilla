# vm

Runs the installer and the config from the working tree in a QEMU VM with UEFI firmware. It needs no USB stick or spare hardware, and only writes to `~/.cache/llangvilla/vm/`. Use it to test changes before they reach the real machine, and to see what the result looks like.

## Quick start

```bash
eval "$(installer/build-usb.sh)"       # build the ISO once
vm/test-vm.sh                          # install, check the base, apply the config
vm/test-vm.sh boot                     # open the result in a window (user jack, password test)
```

## Requirements

- QEMU, OVMF (UEFI firmware), mtools, dosfstools, OpenSSH and OpenSSL. Package names are in [installer: Requirements](../installer/README.md#requirements).
- An ISO from `installer/build-usb.sh`. The newest one in the cache is used by default.
- Write access to `/dev/kvm`: run `sudo usermod -aG kvm "$USER"`, then log in again. Without it QEMU falls back to software emulation, and an install takes hours.

## Usage

```
vm/test-vm.sh [COMMAND] [OPTIONS]
```

### Commands

| Command | Description |
|---|---|
| `all` | Default. `install`, then `check`, then `config` |
| `install` | Fresh disk and test stick, boot the ISO, wait for the installer to power off, collect its logs |
| `check` | Boot the installed disk headless and verify the base system over SSH |
| `config` | Boot the installed disk, apply the working tree's `config/`, verify, power off. Repeatable |
| `boot` | Boot the installed disk in a window. Changes persist until the next `install` |
| `ssh [ARGS]` | SSH into a VM started with `boot`; extra arguments run as a command |
| `live` | Boot the ISO alone with a scratch disk; the installer stops at a root shell |
| `clean` | Delete the VM disk, firmware variables, stick image and test key. Logs are kept |

### Options

| Option | Default | Description |
|---|---|---|
| `--iso FILE` | `$ISO`, else newest cached | ISO to boot |
| `--env FILE` | `installer/autoinstall.env.example` | Base env for the test stick; placeholders are filled and test overrides appended |
| `--no-firstboot` | off | Install a plain base (`CONFIG_REPO_URL=''`). By default the installed system's first boot runs the real hook against a snapshot of the working tree ([below](#first-boot-from-the-working-tree)) |
| `--baked` | off | Use the `install.sh` baked into the ISO instead of the working tree's |
| `--stick DEV` | — | Install from a real USB stick with its own env (needs sudo). `check` and `config` can't log in afterwards; use `boot` |
| `--gui`, `--headless` | headless, except `boot`/`live` | Show or hide the VM window |
| `--disk-size GB` | `60` | Size of the virtual target disk |
| `--timeout MIN` | `90` | Give up on `install` after this long |

### Environment

| Variable | Default | Description |
|---|---|---|
| `OVMF_CODE`, `OVMF_VARS` | auto-detected | Firmware files (found on Arch, Debian/Ubuntu and Fedora) |
| `VM_SSH_PORT` | `2222` | Host port forwarded to the VM's SSH |
| `VM_GIT_PORT` | `8418` | Host port (loopback) serving the working-tree snapshot to the first-boot hook |
| `VM_MEMORY` | `4G` | VM memory |
| `TEST_PASSWORD` | `test` | Password of the test user |

## What gets tested

### Test stick (`install`)

The test `autoinstall.env` is the template with these overrides:

- `TARGET_DISK=auto` and `CONFIRM_SECONDS=0`;
- `ON_FAILURE=poweroff`, so a failure ends the VM instead of waiting at a shell;
- the test password hash and a generated SSH key;
- `CONFIG_REPO_URL` pointing at a snapshot of the working tree, served to the VM (`CONFIG_REPO_URL=''` with `--no-firstboot`).

The working tree's `install.sh` and `packages.txt` go on the stick, and the ISO's installer hands over to that `install.sh`, so installer changes need no ISO rebuild.

### Base system (`check`)

- systemd reports `running` with no failed units
- sudo works for the test user
- hostname, full name, timezone and locale match the env
- btrfs root on `@`; `/home`, `/var/log`, `/var/cache/pacman/pkg` and `/.snapshots` are mounted; fstab has no `subvolid=`
- `/boot` is the vfat ESP; systemd-boot is installed with an entry and a kernel for each of `KERNELS`
- zram swap is active, and zswap is off on the kernel command line
- NetworkManager, sshd and the display manager are active, and the login screen is up (a logind greeter session)
- root is locked
- the Wi-Fi profile has mode 600
- SSH refuses passwords (checked from the host)
- the first-boot hook ran (unless `--no-firstboot`): its done marker and `/opt/llangvilla` exist, and there is no failure notice. `check` waits for the hook, and stops early with its journal and the newest `apply.sh` log if it fails

If a base check fails, `all` still runs the config phase and fails at the end, so one run reports both.

It also saves a screenshot of the login screen to `~/.cache/llangvilla/vm/logs/screens/` (QEMU's `screendump`, needs `python3`). The VM workflow uploads it with the installer logs.

### First boot from the working tree

`install` commits a snapshot of the working tree (uncommitted and untracked files included, ignored ones not) into a throwaway repo, `~/.cache/llangvilla/vm/worktree-git/`. While the VM runs, the test serves it over plain HTTP on the host's loopback (port `VM_GIT_PORT`, default 8418), which the VM reaches as `10.0.2.2`. The test env points `CONFIG_REPO_URL` there, so the installed system runs the **real** hand-over on your changes: clone to `/opt/llangvilla`, `config/apply.sh` (with its `git pull`), the restart report, the failure notice, the reboot. Nothing needs pushing first.

### Config (`config`)

In `all`, the first-boot hook has already applied the config, so the config phase starts at step 3 and re-applies `/opt/llangvilla`. Run on its own (`vm/test-vm.sh config`, the quick loop on an existing install), it starts at step 1:

1. Copies the working tree's `config/` to `~/llangvilla-worktree` in the VM.
2. Runs `config/apply.sh --no-pull` as root. It fails if the playbook fails, if no log appears in `/var/log/llangvilla/`, or if `reflector.timer`, `base-devel`, `man-db` or `man-pages` are missing.
3. Runs it again and fails if any task reports a change. Before this run it adds three fake old snapshots, and afterwards checks that only the newest 3 `before-upgrade-*` snapshots are left, all read-only. Then checks the housekeeping timers are enabled, and runs the Nix cleanup and the firmware check once (the VM has no updatable firmware, so the check must report none).
4. Reboots and checks that systemd reports `running`, everything the config sets is in place (below), the display manager is active, `zswap.enabled=0` is on the kernel command line and the firewall is on (incoming blocked, SSH rate-limited), then saves a screenshot of the login screen.
5. Logs in through a **test-only autologin** (a drop-in in `/etc/plasmalogin.conf.d/` written by the test, never part of `config/`), waits for Plasma, saves a screenshot of the desktop and checks the colour scheme from `config/home/theme.json` was applied at login. It reports whether Plasma replaced home-manager's GTK files, then re-applies with the session running and fails if home-manager clashes or the GTK files aren't its own again. The autologin is removed at the end.

The result checks read their expected values from `config/home/theme.json` and the roles' defaults: the login screen's wallpaper drop-in, colour scheme, icons, font and cursor; the wallpaper package; the Colloid parts in `/usr/share`; the avatar; zswap in every boot entry; the Nix daemon and flakes; and the user layer (a home-manager generation, `gb` keyboard, window buttons and decoration, fonts, menu bars off, the GTK settings). Settings Plasma applies only at login are checked in step 5.

The test shares one SSH connection for all its commands (`ControlMaster`), because the firewall rate-limits new SSH connections.

## Workflows

| Change | Run |
|---|---|
| `install.sh` or `installer/packages.txt` | `vm/test-vm.sh` |
| `config/` | `vm/test-vm.sh config` on an existing install, then `vm/test-vm.sh boot`. Run the full `vm/test-vm.sh` before merging |
| The first-boot hook | `vm/test-vm.sh` (the hook runs on the working tree by default) |
| A real stick, before using it | `vm/test-vm.sh install --stick /dev/sdX` with `TARGET_DISK=auto` on the stick, then `vm/test-vm.sh boot` |

## Files

All under `~/.cache/llangvilla/vm/`:

| Path | Contents |
|---|---|
| `disk.qcow2`, `OVMF_VARS.fd` | Installed VM disk and its UEFI variables |
| `stick.img`, `autoinstall.env` | Test stick image and its env (mode 600) |
| `id_ed25519`, `id_ed25519.pub` | Test SSH key |
| `live-disk.qcow2`, `OVMF_VARS.live.fd` | Scratch disk for `live` |
| `logs/<timestamp>/` | Installer logs copied from the test stick |

## CI

`.github/workflows/vm-test.yml` builds the ISO and runs `vm/test-vm.sh all` on a GitHub runner with KVM. It runs every Monday, to catch breakage from Arch's rolling updates, and on demand: Actions tab → **VM install test**. Every run includes the real first-boot hook on the branch being tested. Installer logs are uploaded as an artifact.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `The installer left no status` | It stopped before finding the test stick, or is waiting at a prompt. Re-run with `--gui` |
| Very slow, `/dev/kvm is not usable` warning | Join the `kvm` group (see [Requirements](#requirements)) |
| `No ISO found` | Build one with `installer/build-usb.sh`, or pass `--iso` |
| `config/apply.sh failed` | The playbook output is shown above. Inspect with `vm/test-vm.sh boot` and `vm/test-vm.sh ssh` |
| `The second run changed things` | A task isn't idempotent; the changed tasks are listed ([writing tasks](../config/README.md#writing-tasks)) |
| `Could not serve the snapshot on port 8418` | Something else uses the port: set `VM_GIT_PORT` |
| `An SSH command timed out after N s: …` | A command on the VM hung (or a step needs a longer limit: `ssh_limit=SECONDS` before the call in `vm/test-vm.sh`). Each SSH command has a limit, 5 minutes unless set longer (applies: 40), so a hang fails its step in minutes. Look around with `vm/test-vm.sh boot` |
| `The first-boot hook did not finish within 25 minutes` | It's still running or stuck; its journal and the newest `apply.sh` log are shown above |
| `The first-boot hook failed` | Its journal and the newest `apply.sh` log are shown above. Look around with `vm/test-vm.sh boot` |
