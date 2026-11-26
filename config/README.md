# config

Personalises an installed machine: apps, fonts, the Colloid theme, the login screen's look, the avatar and system tweaks. It runs once on first boot through the installer's [first-boot hook](../installer/README.md#first-boot-hook), then again whenever the config changes. No USB stick or reinstall is needed.

It is an Ansible playbook behind a single entrypoint, `apply.sh`. Nix home-manager is planned as a second step behind the same entrypoint.

## Quick start

On the machine:

```bash
sudo /opt/llangvilla/config/apply.sh                                 # pull, upgrade, apply
sudo /opt/llangvilla/config/apply.sh --no-upgrade -- --check --diff  # dry run
```

Before pushing a change, from a checkout:

```bash
yamllint . && ansible-lint config/ansible
vm/test-vm.sh config                                    # apply the working tree to the test VM
```

## Usage

```
apply.sh [--no-pull] [--no-upgrade] [-- ANSIBLE-PLAYBOOK-ARGS...]
```

Run as root. `apply.sh` does the following:

1. Unless `--no-pull`: if its directory is in a git checkout, runs `git pull --ff-only` and re-runs the updated `apply.sh`.
2. Unless `--no-upgrade`: upgrades the whole system with `pacman -Syu`. On Arch, installing packages against a stale package database is a partial upgrade, which can break the system, so the playbook always starts from a current one.
3. Installs `ansible` with pacman if `ansible-playbook` is missing.
4. Runs `ansible-playbook site.yml` from `config/ansible/`, passing any arguments after `--`.

| Option | Effect |
|---|---|
| `--no-pull` | Apply the files as they are. Used by the VM test and for local edits |
| `--no-upgrade` | Skip the system upgrade. Use it for dry runs; a real run should upgrade |
| `-- ARGS` | Passed to `ansible-playbook`, e.g. `-- --check --diff`, `-- --tags user_avatar`, `-- -v`. Each role has a tag of its own name |
| `-h`, `--help` | Show usage |

| Exit status | Meaning |
|---|---|
| `0` | Applied successfully |
| non-zero | `git pull`, the system upgrade, the Ansible install or the playbook failed. The output says which |

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
├── assets/                        wallpaper source (SVG) and a 3840×2160 render
└── ansible/
    ├── ansible.cfg                inventory = inventory.ini
    ├── inventory.ini              optiplex, ansible_connection=local
    ├── host_vars/optiplex.yml     per-machine variables
    ├── requirements.yml           collections, for linting only
    ├── site.yml                   checks the user exists, then runs the roles (one tag per role)
    └── roles/
        ├── packages/              apps, tools and fonts
        ├── theme/                 Colloid dark, system-wide, pinned to exact commits
        ├── login_screen/          Plasma Login Manager: wallpaper, colours, icons, cursor, font
        └── user_avatar/           user avatar, through AccountsService
```

## Variables

| Variable | Defined in | Default | Description |
|---|---|---|---|
| `user_name` | `host_vars/optiplex.yml` | `jack` | Login user. Must match `USER_NAME` from the installer; the playbook fails if the user doesn't exist |
| `packages_install` | `roles/packages/defaults/main.yml` | kate, ark, firefox, vim, htop, btop, Inter, JetBrains Mono Nerd Font | Installed with pacman |
| `theme_colloid_*_version` | `roles/theme/defaults/main.yml` | pinned commits | The Colloid KDE, icon and GTK themes. Change a commit to upgrade that theme ([Themes](#themes)) |
| `login_screen_color_scheme`, `_icon_theme`, `_cursor_theme`, `_cursor_size`, `_font` | `roles/login_screen/defaults/main.yml` | Colloid dark, 24 px, Inter 10 | The login screen's look |
| `login_screen_wallpaper_*` | `roles/login_screen/defaults/main.yml` | `assets/seafront-3840x2160.jpg` | Installed as the `Seafront` wallpaper package, used by the login screen (and later the desktop) |
| `login_screen_config_file` | `roles/login_screen/defaults/main.yml` | `/etc/plasmalogin.conf.d/10-llangvilla.conf` | Where the wallpaper setting goes. Use `/etc/plasmalogin.conf` if PLM ignores drop-ins |

## Themes

The `theme` role installs Colloid dark into `/usr/share`, so the login screen, which runs as a system user, can use it as well. Choosing it for your own session is the user layer's job (home-manager, later).

| Part | From | Installed as |
|---|---|---|
| Plasma style, window decorations, colour scheme, look-and-feel | [Colloid-kde](https://github.com/vinceliuice/Colloid-kde) | `Colloid-dark`, `ColloidDark`, `com.github.vinceliuice.Colloid-dark` |
| Icons and cursors | [Colloid-icon-theme](https://github.com/vinceliuice/Colloid-icon-theme) | `Colloid`, `Colloid-Light`, `Colloid-Dark`; `Colloid-cursors`, `Colloid-dark-cursors` |
| GTK 3/4 theme | [Colloid-gtk-theme](https://github.com/vinceliuice/Colloid-gtk-theme) | `Colloid-Dark` (built with `sassc`) |

Each theme is pinned to a commit in `roles/theme/defaults/main.yml`. The role checks it out under `/var/lib/llangvilla/src/` and installs it. The icon and GTK installers run once per commit; a stamp in `/var/lib/llangvilla/stamps/` records it. To upgrade, set a newer commit (a release tag's commit where there is one), run `vm/test-vm.sh config`, then apply.

The look-and-feel package's defaults name Kvantum as the widget style. Kvantum is not used, so apply the look-and-feel's parts individually (home-manager will), not the whole package.

## What goes in the config

| Goes in | Examples | Why |
|---|---|---|
| Base (`installer/packages.txt`) | Plasma, Plasma Login Manager, drivers, audio, Bluetooth, NetworkManager, snapper | Needed to boot to a usable desktop; changes only on reinstall |
| Config (this directory) | Apps, themes, settings, anything you expect to change | Applies to the running machine with `apply.sh` |

The config may rely on the base: a role that themes the login screen checks that Plasma Login Manager is installed instead of installing it. It must not depend on installer settings; machine values such as `user_name` belong in `host_vars`.

## Writing tasks

The first run happens before the login screen starts, and every run is as root. Tasks must:

- **Not restart or start `plasmalogin`/`display-manager`**, including from handlers. At first boot the login screen waits for this run, so it would deadlock until the 30-minute timeout. Write the config file; the display manager reads it on start. Use `systemctl restart --no-block` if something must be triggered.
- **Not reboot.** The hook reboots once after a successful run. A reboot mid-run skips the done marker, so the hook would run again.
- **Not need a desktop session.** No user dconf, user systemd units, `loginctl`, or `kwriteconfig6` against a running session. Writing files under `/etc` or `/home/{{ user_name }}/.config` is fine.
- **Be idempotent.** A second run must report `changed=0`; `vm/test-vm.sh config` warns otherwise.
- **Use `become_user: "{{ user_name }}"`** for user-level tasks.
- **Use `community.general.pacman`** for packages, without `update_cache`: `apply.sh` has already done a full upgrade. Arch package names differ from other distros (`openssh`, `python-*`, `base-devel`). AUR packages need a helper (`paru`, `yay`) run as a normal user, never root.
- **Put Plasma Login Manager settings in `/etc/plasmalogin.conf.d/*.conf`**, not `/etc/plasmalogin.conf`.

## Making a change

1. Edit the role, or add one and list it in `site.yml`.
2. Lint: `yamllint .` and `ansible-lint config/ansible`. CI also runs `ansible-playbook --syntax-check`.
3. Test against the working tree: `vm/test-vm.sh config`, then `vm/test-vm.sh boot` to look at it ([vm](../vm/README.md)).
4. Commit and push, then run `sudo /opt/llangvilla/config/apply.sh` on the machine.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `System upgrade failed` | A pacman problem (mirror, keyring, conflict). Fix it with pacman directly, or apply without upgrading: `--no-upgrade` |
| `git pull failed` | Local changes or a diverged branch in `/opt/llangvilla`. Inspect with `git -C /opt/llangvilla status`, or apply as is with `--no-pull` |
| `Check the login user exists` fails | `user_name` doesn't match the installer's `USER_NAME` |
| `Check Plasma Login Manager is installed` fails | PLM is missing from the base; it comes from `installer/packages.txt` |
| `Look up the login screen's system user` fails | PLM's system user isn't `plasmalogin`. Find it with `getent passwd \| grep -i login` and set `login_screen_greeter_user` |
| The login screen keeps the stock wallpaper | PLM ignored the drop-in: set `login_screen_config_file` to `/etc/plasmalogin.conf` |
| `Check out each Colloid theme` fails | GitHub unreachable, or a pinned commit no longer exists upstream. Pick another commit |
| First boot shows console output for a long time, then the login screen | The first run failed or timed out. Check `journalctl -u llangvilla-firstboot.service -b`, fix, then run `apply.sh` (or reboot to retry) |
| A run hangs | A task restarts the display manager or waits for a desktop session (see [Writing tasks](#writing-tasks)) |
