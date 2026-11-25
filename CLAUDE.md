# llangvilla

Home-network config, currently focused on one machine: the Dell OptiPlex (inventory name `optiplex`, user `jack`). There is no app code or test suite; changes are shell scripts, YAML and docs.

## Layout

- `ansible/` – `site.yml` applies roles `sddm` and `setup_user` plus a few pacman tasks. The target is Arch (`community.general.pacman`). Inventory is `ansible/inventory.ini` (`ansible_connection=local`), wired up via the root `ansible.cfg`.
- `autoinstall/user-data` – Ubuntu autoinstall config (being deprecated). Contains `__PLACEHOLDERS__` that are filled in on the USB stick, never in the repo. See `autoinstall/README.md`.
- `autoinstall/arch/` – Arch zero-touch installer: `build.sh` (runs inside an Arch Docker container to build the ISO with archiso) and `install.sh` (runs on the live ISO). `autoinstall/build-usb.sh` builds the Ventoy stick. See `docs/arch-setup.MD`.
- `.github/workflows/validate-autoinstall.yml` – validates `autoinstall/user-data` against Subiquity on pushes to `main`.

## Direction (from README)

Deprecate Ubuntu, move the builder to an Arch base, move more into standalone scripts and Ansible, and keep the docs up to date.

## Working here

- Lint before pushing: `ansible-lint ansible/` and `yamllint .`. Use `shellcheck` on the `.sh` files if it is installed. None of these are preinstalled in the cloud container (`pip install ansible-lint yamllint`).
- Don't run the playbook, `build-usb.sh` or `install.sh` here. They modify the host, and the installer wipes disks.
- Never commit real Wi-Fi credentials, password hashes or Ubuntu Pro tokens. Keep the placeholders.
- Scripts use `set -euo pipefail` (`install.sh` uses `-uo`, deliberately, so failures drop to a shell). Keep that style.
