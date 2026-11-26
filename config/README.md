# config

Personalises an installed machine: apps, login screen theme, avatar and system tweaks. It runs once on first boot through the installer's [first-boot hook](../installer/README.md#first-boot-hook), then again whenever the config changes. No USB stick or reinstall is needed.

It is an Ansible playbook behind a single entrypoint, `apply.sh`. Nix home-manager is planned as a second step behind the same entrypoint.

## Quick start

On the machine:

```bash
sudo /opt/llangvilla/config/apply.sh                    # pull and apply
sudo /opt/llangvilla/config/apply.sh -- --check --diff  # dry run
```

Before pushing a change, from a checkout:

```bash
yamllint . && ansible-lint config/ansible
vm/test-vm.sh config                                    # apply the working tree to the test VM
```

## Usage

```
apply.sh [--no-pull] [-- ANSIBLE-PLAYBOOK-ARGS...]
```

Run as root. Without `--no-pull`, `apply.sh` does the following:

1. If its directory is in a git checkout, runs `git pull --ff-only` and re-runs the updated `apply.sh`.
2. Installs `ansible` with pacman if `ansible-playbook` is missing.
3. Runs `ansible-playbook site.yml` from `config/ansible/`, passing any arguments after `--`.

| Option | Effect |
|---|---|
| `--no-pull` | Apply the files as they are. Used by the VM test and for local edits |
| `-- ARGS` | Passed to `ansible-playbook`, e.g. `-- --check --diff`, `-- --tags sddm`, `-- -v` |
| `-h`, `--help` | Show usage |

| Exit status | Meaning |
|---|---|
| `0` | Applied successfully |
| non-zero | `git pull`, the Ansible install or the playbook failed. The output says which |

### Where it runs

| Context | Invoked by | Checkout |
|---|---|---|
| First boot | `llangvilla-firstboot.service` (once, before the login screen) | `/opt/llangvilla`, cloned by the hook |
| Later updates | You: `sudo /opt/llangvilla/config/apply.sh` | `/opt/llangvilla` |
| VM test | `vm/test-vm.sh config` (with `--no-pull`) | `~/llangvilla-worktree` in the VM |

A machine installed before `config/` existed has no `/opt/llangvilla`. Create it once, as root:

```bash
git clone https://github.com/cqkh42/llangvilla.git /opt/llangvilla
/opt/llangvilla/config/apply.sh
```

## Layout

```
config/
├── apply.sh                       entrypoint
└── ansible/
    ├── ansible.cfg                inventory = inventory.ini
    ├── inventory.ini              optiplex, ansible_connection=local
    ├── host_vars/optiplex.yml     per-machine variables
    ├── requirements.yml           collections, for linting only
    ├── site.yml                   checks the user exists, then runs the roles
    └── roles/
        ├── packages/              apps and tools; packages to remove
        ├── sddm/                  Catppuccin theme and SDDM drop-in config
        └── setup_user/            user avatar for SDDM and AccountsService
```

## Variables

| Variable | Defined in | Default | Description |
|---|---|---|---|
| `user_name` | `host_vars/optiplex.yml` | `jack` | Login user. Must match `USER_NAME` from the installer; the playbook fails if the user doesn't exist |
| `packages_install` | `roles/packages/defaults/main.yml` | kate, ark, firefox, vim, htop, btop | Installed with pacman |
| `packages_remove` | `roles/packages/defaults/main.yml` | plasma-welcome | Removed, and added to `IgnorePkg` in `/etc/pacman.conf` |
| `sddm_flavor`, `sddm_accent` | `roles/sddm/vars/main.yml` | `mocha`, `mauve` | Catppuccin variant |
| `sddm_catppuccin_version`, `sddm_theme_sha256` | `roles/sddm/vars/main.yml` | `v1.1.2`, pinned | Theme release and its checksum; update both together |

## What goes in the config

| Goes in | Examples | Why |
|---|---|---|
| Base (`installer/packages.txt`) | Plasma, SDDM, drivers, audio, Bluetooth, NetworkManager, snapper | Needed to boot to a usable desktop; changes only on reinstall |
| Config (this directory) | Apps, themes, settings, anything you expect to change | Applies to the running machine with `apply.sh` |

The config may rely on the base: the `sddm` role checks that SDDM is installed instead of installing it. It must not depend on installer settings; machine values such as `user_name` belong in `host_vars`.

## Writing tasks

The first run happens before the login screen starts, and every run is as root. Tasks must:

- **Not restart or start `sddm`/`display-manager`**, including from handlers. At first boot SDDM waits for this run, so it would deadlock until the 30-minute timeout. Write the config file; SDDM reads it on start. Use `systemctl restart --no-block` if something must be triggered.
- **Not reboot.** The hook reboots once after a successful run. A reboot mid-run skips the done marker, so the hook would run again.
- **Not need a desktop session.** No user dconf, user systemd units, `loginctl`, or `kwriteconfig6` against a running session. Writing files under `/etc` or `/home/{{ user_name }}/.config` is fine.
- **Be idempotent.** A second run must report `changed=0`; `vm/test-vm.sh config` warns otherwise.
- **Use `become_user: "{{ user_name }}"`** for user-level tasks.
- **Use `community.general.pacman`** for packages. Arch package names differ from other distros (`openssh`, `python-*`, `base-devel`). AUR packages need a helper (`paru`, `yay`) run as a normal user, never root.
- **Put SDDM settings in `/etc/sddm.conf.d/*.conf`**, not `/etc/sddm.conf`.

## Making a change

1. Edit the role, or add one and list it in `site.yml`.
2. Lint: `yamllint .` and `ansible-lint config/ansible`. CI also runs `ansible-playbook --syntax-check`.
3. Test against the working tree: `vm/test-vm.sh config`, then `vm/test-vm.sh boot` to look at it ([vm](../vm/README.md)).
4. Commit and push, then run `sudo /opt/llangvilla/config/apply.sh` on the machine.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `git pull failed` | Local changes or a diverged branch in `/opt/llangvilla`. Inspect with `git -C /opt/llangvilla status`, or apply as is with `--no-pull` |
| `Check the login user exists` fails | `user_name` doesn't match the installer's `USER_NAME` |
| `Check SDDM is installed` fails | SDDM is missing from the base; it comes from `installer/packages.txt` |
| First boot shows console output for a long time, then the login screen | The first run failed or timed out. Check `journalctl -u llangvilla-firstboot.service -b`, fix, then run `apply.sh` (or reboot to retry) |
| A run hangs | A task restarts SDDM or waits for a desktop session (see [Writing tasks](#writing-tasks)) |
