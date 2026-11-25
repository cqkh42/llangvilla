# Trying it in a VM (part 3)

`vm/test-vm.sh` runs the whole flow from your **working tree** in a QEMU VM with UEFI firmware: the installer (part 1) onto a blank 60 GB virtual disk from a small virtual USB stick, then the config (part 2) on the result. It needs no real stick, and touches nothing outside `~/.cache/llangvilla/vm/`. Use it to test changes before they reach the real machine, and to see how the result looks and feels.

## What you need

QEMU, UEFI firmware (OVMF) and mtools, plus an ISO from `autoinstall/build-usb.sh`. The install commands are in [`autoinstall/README.md`](../autoinstall/README.md) section 2 (Prepare the build computer), and section 4 builds the ISO. Without `/dev/kvm` access the VM falls back to software emulation, which is very slow (section 2 adds you to the `kvm` group).

## The commands

```bash
vm/test-vm.sh                # = all: install, check, config
```

| Command | What it does |
|---|---|
| `install` | Creates a fresh disk, writes a test `autoinstall.env` (the template with test values: password `test`, a generated SSH key, no countdown, `ON_FAILURE=poweroff`, first-boot hook off), boots the newest ISO, waits for the VM to power off, copies the installer's logs to `~/.cache/llangvilla/vm/logs/`. 10-25 minutes with KVM. Tests part 1 |
| `check` | Boots the installed disk headless and checks the base system over SSH: no failed units, sudo, hostname, full name, btrfs subvolumes and fstab, the ESP, systemd-boot and an entry per kernel, timezone, locale, zram swap, NetworkManager, sshd, SDDM running, root locked, Wi-Fi profile mode 600, and (from the host) that SSH refuses passwords. Tests part 1 |
| `config` | Boots the installed disk, copies the working tree's `config/` into it, runs `config/apply.sh --no-pull`, runs it again (warns if anything changed the second time), reboots, and checks there are no failed units and SDDM is up. Repeatable on the same install. Tests part 2 |
| `boot` | Boots the installed disk in a window: the real SDDM login (user `jack`, password `test`). Changes persist until the next `install` |
| `ssh` | SSH into a VM started with `boot`, from another terminal (port 2222). Extra args run as a command |
| `live` | Boots just the ISO in a window with a scratch disk: a root shell on the live system |
| `clean` | Deletes the VM files (logs are kept) |

By default the working tree's `install.sh` and `packages.txt` go on the test stick, and the installer baked into the ISO hands over to them, so installer changes don't need an ISO rebuild. `--baked` tests the ISO's own copy instead.

## Typical loops

- **Installer change** (`install.sh`, `packages.txt`): `vm/test-vm.sh` (the whole flow).
- **Config change** (anything in `config/`): install once, then iterate with `vm/test-vm.sh config` and look at it with `vm/test-vm.sh boot`. No reinstall needed: it applies on top, just as on the real box. For a clean-slate check, run the whole flow.

## Options

| Option | Effect |
|---|---|
| `--gui` / `--headless` | Show or hide the VM window (default: hidden, except for `boot`/`live`) |
| `--firstboot` | Keep `CONFIG_REPO_URL`, so the installed system runs the real first-boot hook. It clones from **GitHub** (the default branch, or `CONFIG_REPO_BRANCH`), not your working tree; `check` waits for it and its reboot. Use it to test the hook itself, e.g. before a real install |
| `--env FILE` | Use another env as the base, e.g. your real one (test overrides still apply) |
| `--stick /dev/sdX` | Install from the **real** stick, exactly as the OptiPlex would (sudo needed, stick unmounted). Its own env is used, so `check`/`config` can't log in; look with `boot`. A pinned `TARGET_DISK` doesn't exist in the VM, so the installer stops safely: set `TARGET_DISK=auto` while testing this way |
| `--baked` | Use the `install.sh` baked into the ISO |
| `--iso FILE`, `--disk-size GB`, `--timeout MIN` | What they say |

Environment: `OVMF_CODE` / `OVMF_VARS` (found automatically on Arch, Debian/Ubuntu and Fedora), `VM_SSH_PORT` (2222), `VM_MEMORY` (4G), `TEST_PASSWORD` (test).

## In CI

`.github/workflows/vm-test.yml` builds the ISO and runs `vm/test-vm.sh all` on a GitHub runner (which has KVM), on demand only for now (Actions tab, "VM install test", optionally with the real first-boot hook). Installer logs are uploaded as an artifact. A weekly schedule will be restored once it passes reliably (issue #11): because Arch is a rolling release, a scheduled run catches breakage that no commit here caused.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| "left no status" | The installer stopped before finding the test stick, or hung at a prompt. Re-run with `--gui` to watch it. |
| Extremely slow | No KVM (it warns). Join the `kvm` group. |
| `config` fails | The playbook output is printed above the error. `vm/test-vm.sh boot` plus `vm/test-vm.sh ssh` to poke at the VM; the copied tree is in `~/llangvilla-worktree`. |
| "The second run changed things" | A task isn't idempotent (config/README.md, rules). The changed tasks are listed. |
| `--ansible` is rejected | Replaced by `--firstboot` (the hook from GitHub) and the `config` command (your working tree). |
