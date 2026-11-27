# llangvilla

Home-network config, currently focused on one machine: the Dell OptiPlex (inventory name `optiplex`, user `jack`). It runs **Arch Linux** with KDE Plasma; Arch is the only target. There is no app code or test suite; changes are shell scripts, YAML and docs.

## Layout

Three separate parts, kept apart on purpose (root `README.md` has the flow):

- `installer/` – **part 1, clean slate.** Zero-touch Arch installer. `README.md` is the full guide.
  - `build-usb.sh` – host-side: builds the ISO in an `archlinux` Docker container, downloads Ventoy (pinned SHA-256), installs and populates the stick. Uses the sibling scripts when run from a checkout, GitHub `main` otherwise.
  - `build.sh` – runs inside the container, builds the ISO with archiso and bakes in `install.sh`.
  - `install.sh` – runs on the live ISO: validates config, partitions, `pacstrap`s and configures the system (user, Wi-Fi, SSH keys, systemd-boot, first-boot hook), powers off. `install.sh --check FILE` validates an env file anywhere (safe).
  - `packages.txt` – the clean-slate base package list; copied onto the stick, not baked into the ISO. Apps go in the config instead.
  - `autoinstall.env.example` – template for the stick's `autoinstall.env`, with double-underscore placeholders.
- `config/` – **part 2, personalisation.** Live: re-applied on the box as it changes. `README.md` is the guide.
  - `apply.sh` – the one entrypoint (first boot, re-runs, VM test): `git pull`, full `pacman -Syu` (skip with `--no-upgrade`), install Ansible if missing, run the playbook (which ends with home-manager).
  - `assets/` – wallpaper source (`seafront.svg`) and a 3840×2160 render.
  - `home/` – the user layer: a Nix flake for home-manager and plasma-manager (`flake.nix`, committed `flake.lock`, `home.nix`, `theme.json` (the look: theme names, fonts, wallpaper; also read by Ansible's `login_screen` role), `modules/`: the Mac-style Plasma layout, GTK, menus, git, shell). Applied by the `home_manager` role with a `path:` flake reference.
  - `ansible/` – `site.yml` with roles `packages`, `boot` (kernel command line), `theme` (Colloid, pinned commits), `login_screen` (PLM's look), `user_avatar`, `nix`, `housekeeping` (weekly timers), `home_manager` (last), each tagged with its own name; `host_vars/optiplex.yml` (`user_name`); own `ansible.cfg` and `inventory.ini` (`ansible_connection=local`).
- `vm/` – **part 3, try it.** `test-vm.sh` installs into a QEMU/OVMF VM from a generated test stick, checks the base over SSH, then applies the working tree's `config/` and checks again; `config` alone iterates on config changes; `boot`/`live`/`ssh` for poking around. Uses the working tree's `install.sh`, `packages.txt` and `config/` (no ISO rebuild). `README.md` is the guide.
- `.github/workflows/lint.yml` – shellcheck on all scripts, `install.sh --check` on the template, yamllint, ansible-lint, a playbook syntax check, and for `config/home`: `nix flake check`, nixfmt and a build of the home configuration.
- The to-do list is GitHub issues (no `TODO.md`).
- `.github/workflows/vm-test.yml` – builds the ISO and runs `vm/test-vm.sh all` with KVM (weekly, Mondays, and manual).

The only link between parts 1 and 2 is the first-boot hook: the installer clones the repo to `/opt/llangvilla` and runs `CONFIG_ENTRYPOINT` (`config/apply.sh`). Keep it that way: the installer must not know about Ansible, and the config must not assume installer settings.

## Working here

- Lint before pushing: `shellcheck installer/*.sh config/*.sh vm/*.sh`, `yamllint .` and `ansible-lint config/ansible` (CI runs all three). For `config/home`, Nix is preinstalled in the cloud container: `nix flake check path:$PWD/config/home` and build `path:$PWD/config/home#homeConfigurations.jack.activationPackage` (use `path:` there, since new files aren't tracked by git yet). None are preinstalled in the cloud container (`pip install shellcheck-py ansible ansible-lint yamllint`; the full `ansible` package provides `community.general`, since Galaxy may be unreachable).
- Don't run the playbook or `config/apply.sh` (`--syntax-check` is fine), `build-usb.sh` against a disk, or `install.sh` (except `--check`) here. They modify the host, and the installer wipes disks. `vm/test-vm.sh` only touches `~/.cache/llangvilla/vm`, but a real install needs KVM and Arch mirrors, which the cloud container lacks; use the VM workflow.
- Test installer or base package changes with `vm/test-vm.sh`, config changes with `vm/test-vm.sh config` (`vm/README.md`).
- Never commit real Wi-Fi credentials, password hashes or a filled-in `autoinstall.env`. Keep the placeholders.
- The config's first run is before login: never restart the display manager (`plasmalogin`) or reboot from it (see `config/README.md`, Writing tasks).
- Scripts use `set -euo pipefail` (`install.sh` uses `-uo`, deliberately, so failures drop to a shell). Keep that style.
