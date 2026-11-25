# llangvilla

Home-network config, currently focused on one machine: the Dell OptiPlex (inventory name `optiplex`, user `jack`). It runs **Arch Linux** with KDE Plasma; Arch is the only target. There is no app code or test suite; changes are shell scripts, YAML and docs.

## Layout

- `ansible/` – `site.yml` applies roles `sddm` and `setup_user` plus a few pacman tasks (`community.general.pacman`). Inventory is `ansible/inventory.ini` (`ansible_connection=local`), wired up via the root `ansible.cfg`. Runs via first-boot `ansible-pull` as root, before SDDM starts.
- `autoinstall/` – zero-touch Arch installer. `README.md` is the full guide.
  - `build-usb.sh` – host-side: builds the ISO in an `archlinux` Docker container, downloads Ventoy (pinned SHA-256), installs and populates the stick. Uses the sibling scripts when run from a checkout, GitHub `main` otherwise.
  - `build.sh` – runs inside the container, builds the ISO with archiso and bakes in `install.sh`.
  - `install.sh` – runs on the live ISO: validates config, partitions, `pacstrap`s and configures the system (user, Wi-Fi, SSH keys, systemd-boot, ansible-pull unit), powers off. `install.sh --check FILE` validates an env file anywhere (safe).
  - `packages.txt` – package list for the installed system; copied onto the stick, not baked into the ISO.
  - `autoinstall.env.example` – template for the stick's `autoinstall.env`, with double-underscore placeholders.
  - `test-vm.sh` – installs into a QEMU/OVMF VM from a generated test stick and checks the result over SSH; `boot`/`live`/`ssh` subcommands for poking around. Uses the working tree's `install.sh` and `packages.txt` (no ISO rebuild).
- `.github/workflows/lint-autoinstall.yml` – shellcheck on `autoinstall/*.sh`, plus `install.sh --check` on the template.
- `.github/workflows/vm-test.yml` – builds the ISO and runs `test-vm.sh all` with KVM (manual only for now; weekly schedule to return, issue #11).

## Working here

- Lint before pushing: `shellcheck autoinstall/*.sh` (CI runs this), plus `ansible-lint ansible/` and `yamllint .`. None are preinstalled in the cloud container (`pip install shellcheck-py ansible-lint yamllint`).
- Don't run the playbook, `build-usb.sh` against a disk, or `install.sh` (except `--check`) here. They modify the host, and the installer wipes disks. `test-vm.sh` only touches `~/.cache/llangvilla/vm`, but a real install needs KVM and Arch mirrors, which the cloud container lacks; use the VM workflow.
- Test installer or package changes with `autoinstall/test-vm.sh` (README section 7).
- Never commit real Wi-Fi credentials, password hashes or a filled-in `autoinstall.env`. Keep the placeholders.
- Playbook tasks run before login: never restart SDDM or reboot from the playbook (see `autoinstall/README.md` section 13).
- Scripts use `set -euo pipefail` (`install.sh` uses `-uo`, deliberately, so failures drop to a shell). Keep that style.
