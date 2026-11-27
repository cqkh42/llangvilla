# llangvilla

Home-network config for one machine: a Dell OptiPlex (inventory name `optiplex`) running **Arch Linux** with KDE Plasma; Arch is the only target. No app code or test suite: changes are shell scripts, YAML, Nix and docs.

## Where things are

The root `README.md` has the overview, the layout and the `make` targets; each part's README is its full guide. Don't repeat them here.

- `installer/` – part 1: the zero-touch installer (`build-usb.sh`, `build.sh`, `install.sh`, `packages.txt`, `autoinstall.env.example`).
- `config/` – part 2: `apply.sh`, the Ansible playbook (`config/ansible`), the home-manager flake (`config/home`, with `theme.json` for the look and `host.json` for the machine's facts, both read by Nix and Ansible).
- `vm/` – part 3: `test-vm.sh`, the QEMU test of both.
- `docs/` – `design.md` (what the machine should be), `decisions.md` (what was decided and why), `maintenance.md` (routine tasks, dependency bumps, recovery).
- `.github/` – CI (lint on every push; the VM test on PRs that touch `installer/`, `config/` or `vm/`, weekly and on demand), Dependabot, the upstream check.
- The to-do list is GitHub issues (no `TODO.md`).

The only link between parts 1 and 2 is the first-boot hook: the installer clones the repo to `/opt/llangvilla` and runs `CONFIG_ENTRYPOINT` (`config/apply.sh`). Keep it that way: the installer must not know about Ansible, and the config must not assume installer settings.

## Working here

- Lint before pushing: `make lint` (or one target; the `Makefile` is the one copy of the commands, and CI calls the same targets). Install the linters at CI's versions with `pip install -r .github/lint/requirements.txt` (the full `ansible` package provides `community.general`, since Galaxy may be unreachable). Nix is preinstalled in the cloud container; `make lint-nix` uses a `path:` flake reference, so new, untracked files count.
- Don't run the playbook or `config/apply.sh` (`--syntax-check` is fine), `build-usb.sh` against a disk, or `install.sh` (except `--check`) here. They modify the host, and the installer wipes disks. `vm/test-vm.sh` only touches `~/.cache/llangvilla/vm`, but a real install needs KVM and Arch mirrors, which the cloud container lacks: push and let the VM workflow run on the PR.
- Never commit real Wi-Fi credentials, password hashes or a filled-in `autoinstall.env`. Keep the placeholders.
- The config's first run is before login: never restart the display manager (`plasmalogin`) or reboot from it, and don't need a desktop session (`config/README.md`, Writing tasks).
- Removing something takes an explicit `state: absent` or `packages_remove` (`config/README.md`, Removing things).
- Scripts use `set -euo pipefail` (`install.sh` uses `-uo`, deliberately, so failures drop to a shell). Keep that style.
- Add an entry to `docs/decisions.md` when a decision changes how the repo works; open questions go in issues.
