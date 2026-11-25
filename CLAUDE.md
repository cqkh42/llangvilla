# llangvilla

Home-network config, currently focused on one machine: the Dell OptiPlex (inventory name `optiplex`, user `jack`). It runs **Arch Linux** with KDE Plasma; Arch is the only target. There is no app code or test suite; changes are shell scripts, YAML and docs.

## Layout

- `ansible/` – `site.yml` applies roles `sddm` and `setup_user` plus a few pacman tasks (`community.general.pacman`). Inventory is `ansible/inventory.ini` (`ansible_connection=local`), wired up via the root `ansible.cfg`. Runs via first-boot `ansible-pull` as root, before SDDM starts.
- `autoinstall/` – zero-touch Arch installer. `README.md` is the full guide.
  - `build-usb.sh` – host-side: builds the ISO in an `archlinux` Docker container, downloads Ventoy (pinned SHA-256), installs and populates the stick. Uses the sibling scripts when run from a checkout, GitHub `main` otherwise.
  - `build.sh` – runs inside the container, builds the ISO with archiso and bakes in `install.sh`.
  - `install.sh` – runs on the live ISO: partitions, runs `archinstall --silent`, adds Wi-Fi/SSH/ansible-pull, powers off.
  - `autoinstall.env.example` – template for the stick's `autoinstall.env`, with `__PLACEHOLDERS__`.
- `.github/workflows/lint-autoinstall.yml` – shellcheck on `autoinstall/*.sh`.

## Working here

- Lint before pushing: `shellcheck autoinstall/*.sh` (CI runs this), plus `ansible-lint ansible/` and `yamllint .`. None are preinstalled in the cloud container (`pip install shellcheck-py ansible-lint yamllint`).
- Don't run the playbook, `build-usb.sh` against a disk, or `install.sh` here. They modify the host, and the installer wipes disks.
- Never commit real Wi-Fi credentials, password hashes, `autoinstall.env` or archinstall JSON. Keep the placeholders.
- Playbook tasks run before login: never restart SDDM or reboot from the playbook (see `autoinstall/README.md` section 14).
- Scripts use `set -euo pipefail` (`install.sh` uses `-uo`, deliberately, so failures drop to a shell). Keep that style.
