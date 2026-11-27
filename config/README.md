# config

Personalises an installed machine: apps, fonts, the Colloid theme, the login screen's look, the avatar and system tweaks. It runs once on first boot through the installer's [first-boot hook](../installer/README.md#first-boot-hook), then again whenever the config changes. No USB stick or reinstall is needed.

It is an Ansible playbook behind a single entrypoint, `apply.sh`. Ansible owns the system; its last role runs Nix home-manager, which owns the user's home: the Plasma layout and settings, GTK, git and the shell. See [User layer](#user-layer).

## Quick start

On the machine:

```bash
sudo /opt/llangvilla/config/apply.sh                                 # pull, upgrade, apply
sudo /opt/llangvilla/config/apply.sh --no-upgrade -- --check --diff  # dry run
```

Before pushing a change, from a checkout:

```bash
make lint-yaml lint-ansible lint-nix                    # the checks CI runs on config/
make vm-config                                          # apply the working tree to the test VM
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
5. After an upgrade, even a failed run, says what still runs old code. It never acts on it itself:
   - **Reboot needed**: the running kernel was upgraded, so its modules are gone (plugging in new hardware can fail until you reboot).
   - **Log out and in**: a desktop or login session still uses replaced libraries (Qt, KDE, Mesa and so on).
   - **Services still using replaced libraries**: restart them with `systemctl restart`, or reboot.

Only one run at a time: a second `apply.sh` while one is running exits with `Another apply.sh is already running`.

Every run is also logged to `/var/log/llangvilla/apply-<date>-<time>.log` (the newest 20 are kept). A pacman lock left by a run that was cut off (a power cut, say) is removed when no pacman is running, so the next run can start.

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
| VM test | the first-boot hook, then `vm/test-vm.sh` (with `--no-pull`) | `/opt/llangvilla`, cloned from a snapshot of the working tree; `vm/test-vm.sh config` uses `~/llangvilla-worktree` |

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
├── home/                          the user layer: a Nix flake for home-manager
│   ├── flake.nix, flake.lock      inputs (nixpkgs, home-manager, plasma-manager), pinned by the lock
│   ├── home.nix                   settings every user gets
│   ├── theme.json                 the look: theme names, fonts, wallpaper (read by Nix and Ansible)
│   ├── host.json                  the machine: login user, keyboard layout, mirror countries (likewise)
│   └── modules/                   plasma.nix (the Mac layout), gtk.nix, apps.nix (☰ menus), git.nix, shell.nix
└── ansible/
    ├── ansible.cfg                inventory = inventory.ini
    ├── inventory.ini              optiplex, ansible_connection=local
    ├── requirements.yml           collections, for linting only
    ├── site.yml                   checks the user exists, then runs the roles (one tag per role)
    └── roles/
        ├── packages/              apps, tools and fonts
        ├── mirrors/               reflector: UK HTTPS mirrors, refreshed weekly
        ├── boot/                  kernel command line of every boot entry (zswap off)
        ├── firewall/              ufw: incoming blocked, outgoing allowed, SSH rate-limited
        ├── theme/                 Colloid dark, system-wide, pinned to exact commits
        ├── login_screen/          Plasma Login Manager: wallpaper, colours, icons, cursor, font
        ├── user_avatar/           user avatar, through AccountsService
        ├── nix/                   Nix from pacman, daemon socket, flakes
        ├── housekeeping/          weekly: package cache, Nix cleanup, firmware update check
        └── home_manager/          runs home-manager switch as the user (last role)
```

## Variables

| Variable | Defined in | Default | Description |
|---|---|---|---|
| `host` | `site.yml`, from `config/home/host.json` | `jack`, `gb`, `[GB]` | The machine's facts, shared with the user layer: login user, keyboard layout, mirror countries. Change them there |
| `user_name` | `site.yml`, `host.user` | `jack` | Login user. Must match `USER_NAME` from the installer; the playbook fails if the user doesn't exist. The flake's `homeConfigurations` entry is named from the same file |
| `firewall_ssh_port` | `roles/firewall/defaults/main.yml` | `22` | SSH's port, allowed through the firewall with a rate limit (6 new connections in 30 s per address) |
| `packages_install` | `roles/packages/defaults/main.yml` | kate, ark, firefox, vim, htop, btop, man-db, man-pages, base-devel, Inter, JetBrains Mono Nerd Font | Installed with pacman |
| `mirrors_countries`, `mirrors_latest` | `roles/mirrors/defaults/main.yml` | `host.mirrorCountries`, `10` | reflector's mirror choice: the 10 most recently synced HTTPS mirrors in those countries, sorted by speed, written to `/etc/pacman.d/mirrorlist` weekly |
| `theme_colloid_*_version` | `roles/theme/defaults/main.yml` | pinned commits | The Colloid KDE, icon and GTK themes. Change a commit to upgrade that theme ([Themes](#themes)) |
| `look` | `site.yml`, from `config/home/theme.json` | Colloid dark, 24 px cursor, Inter 10, Seafront | The look, shared by the login screen (Ansible) and the desktop and GTK (`config/home`). Change it there, not in a role |
| `login_screen_color_scheme`, `_icon_theme`, `_cursor_theme`, `_cursor_size`, `_font` | `roles/login_screen/defaults/main.yml` | from `look` | The login screen's look |
| `login_screen_wallpaper_*` | `roles/login_screen/defaults/main.yml` | `assets/seafront-3840x2160.jpg`; name and size from `look` | Installed as the `Seafront` wallpaper package, used by the login screen, and by the desktop and lock screen (`config/home/modules/plasma.nix`) |
| `housekeeping_nix_keep` | `roles/housekeeping/defaults/main.yml` | `30d` | Home-manager generations older than this are deleted weekly, then unused Nix store paths: the user layer can be rolled back this far |
| `home_manager_flake_dir` | `roles/home_manager/defaults/main.yml` | `config/home` next to the playbook | The flake to apply |
| `login_screen_config_file` | `roles/login_screen/defaults/main.yml` | `/etc/plasmalogin.conf.d/10-llangvilla.conf` | Where the wallpaper setting goes |

## User layer

`config/home/` is a Nix flake for [home-manager](https://github.com/nix-community/home-manager), which owns everything in the user's home. The `home_manager` role applies it as the user:

```bash
nix run path:config/home#home-manager -- switch -b backup --flake path:config/home#jack
```

- **Pinned.** `flake.lock` fixes nixpkgs, home-manager and plasma-manager. Nothing changes until you run `nix flake update` in `config/home`, test in the VM and commit the new lock.
- **`path:`, not git.** The checkout in `/opt/llangvilla` belongs to root and the VM test copies `config/` without `.git`; a `path:` reference works for both.
- **Existing files are backed up once.** `-b backup` moves a file home-manager would replace to `*.backup` (the stock `~/.bashrc` becomes `~/.bashrc.backup`). A later clash on the same file replaces that backup instead of failing the switch (`HOME_MANAGER_BACKUP_OVERWRITE`), so edit dotfiles in the repo, not on the machine. The three GTK files are overwritten without any backup, since Plasma's GTK sync may rewrite them (`gtk.nix`).
- **First run is slow.** It fetches nixpkgs and downloads from cache.nixos.org, which first boot waits for (it has no time limit). Later runs take seconds.
- **Reported as changed** only when the switch produces a new generation, so the second-run check still works.
- **Plasma in two steps.** [plasma-manager](https://github.com/nix-community/plasma-manager) writes the settings files during the switch (fonts, window buttons, menu bars). The colour scheme, icons, cursor, wallpaper and panels need a running Plasma, so its autostart entry applies them at the next login. With `overrideConfig = true` the repo always wins: changes made in System Settings are reset on the next apply.
- **No dconf.** home-manager's dconf writes need a D-Bus session during the switch, which first boot doesn't have; on Plasma, GTK 4 apps get the dark preference from KDE's portal instead.

| Module | Sets |
|---|---|
| `plasma.nix` | Colloid dark (style, colours, icons, cursor, decorations), Breeze widgets, buttons on the left, Inter / JetBrains Mono, top bar (launcher, tray, clock), floating dock that moves out of the way, KRunner on Meta+Space, wallpaper on desktop and lock screen |
| `gtk.nix` | GTK 3/4 theme, icons, cursor and font to match |
| `apps.nix` | Menu bars off in Dolphin, Kate, Ark and Konsole (☰ menus; Ctrl+M brings one back) |
| `git.nix`, `shell.nix` | Git behaviour (no identity yet) and bash |

What goes where:

| Comes from | What | Why |
|---|---|---|
| pacman (Ansible) | GUI apps, themes, fonts, anything that plugs into Plasma or Qt | Nix GUI apps need nixGL on Arch; Nix Qt plugins can't load into Arch's Qt; system users (the login screen) can't see the Nix profile |
| Nix (home-manager) | Dotfiles, settings, command-line tools | Declarative, pinned, roll back with `home-manager generations` |

To add something, add a module under `modules/` and import it from `home.nix`. Check it with `make lint-nix` (flake check, nixfmt, build; CI runs the same), format it with `make fmt-nix`, then `make vm-config`.

## Themes

The `theme` role installs Colloid dark into `/usr/share`, so the login screen, which runs as a system user, can use it as well. Choosing it for your own session is the user layer's job (`config/home/modules/plasma.nix` and `gtk.nix`).

| Part | From | Installed as |
|---|---|---|
| Plasma style, window decorations, colour scheme | [Colloid-kde](https://github.com/vinceliuice/Colloid-kde) | `Colloid-dark`, `ColloidDark` |
| Icons and cursors | [Colloid-icon-theme](https://github.com/vinceliuice/Colloid-icon-theme) | `Colloid`, `Colloid-Light`, `Colloid-Dark`; `Colloid-cursors`, `Colloid-dark-cursors` |
| GTK 3/4 theme | [Colloid-gtk-theme](https://github.com/vinceliuice/Colloid-gtk-theme) | `Colloid-Dark` (built with `sassc`) |

Which installed theme, icons, cursor, fonts and wallpaper are *used* is set in one place, `config/home/theme.json`: the login screen (`login_screen` role) and the desktop and GTK apps (`plasma.nix`, `gtk.nix`) all read it, so they can't drift apart. It lives in `config/home` because the Nix flake can only read files inside its own directory.

Each theme is pinned to a commit in `roles/theme/defaults/main.yml`. The role checks it out under `/var/lib/llangvilla/src/` and installs it. The icon and GTK installers run once per commit; a stamp in `/var/lib/llangvilla/stamps/` records it. To upgrade, set a newer commit (a release tag's commit where there is one), run `vm/test-vm.sh config`, then apply. The weekly upstream check opens an issue with the commit to paste when there's a newer one ([dependency bumps](../docs/maintenance.md#dependency-bumps)).

Colloid's look-and-feel package is not installed: its defaults name Kvantum as the widget style, and Kvantum is not used. `plasma.nix` selects the parts individually instead.

## Snapshots

Before every upgrade, including first boot's, `apply.sh` takes a read-only btrfs snapshot of `/` as `/.snapshots/before-upgrade-<date>-<time>` and keeps the newest 3. They are the undo for a bad Arch upgrade: re-applying the config, or reinstalling, would install the same broken packages again.

- **Covered:** `/` (the system, `/etc`, `/usr`, `/var` apart from the next item).
- **Not covered:** `/home`, `/var/log` and `/var/cache/pacman/pkg` (separate subvolumes), and `/boot` (FAT, see the kernel step below). Nor a `pacman -Syu` you run by hand, or a run with `--no-upgrade`: upgrade with `apply.sh`.
- **Skipped** with a note if `/` isn't btrfs or `/.snapshots` isn't a subvolume (a machine not set up by the installer).
- **If an upgrade broke something, roll back soon.** Each `apply.sh` run takes a new snapshot and drops the oldest, so after three more runs the good one is gone.

List them with `sudo ls /.snapshots/`. To see what changed, compare a directory, e.g. `sudo diff -rq /.snapshots/before-upgrade-<…>/etc /etc`.

### Undo one file or one package

```bash
sudo cp -a /.snapshots/before-upgrade-<…>/etc/some.conf /etc/some.conf      # a file
sudo pacman -U /var/cache/pacman/pkg/<name>-<old version>-*.pkg.tar.zst     # a package (the cache keeps old versions)
```

### Roll the whole system back

From the running system (or the live stick, mounting the root partition instead):

```bash
sudo mount -o subvolid=5 "$(findmnt -nvo SOURCE /)" /mnt            # the btrfs top level
sudo mv /mnt/@ /mnt/@broken                                         # keep the broken system for now
sudo btrfs subvolume snapshot /mnt/@.snapshots/before-upgrade-<…> /mnt/@   # a writable copy becomes /
sudo umount /mnt
sudo reboot
```

The boot entry names the root subvolume (`rootflags=subvol=@`), so the new `@` is used from the next boot. Tools that switch btrfs's *default* subvolume, like `snapper rollback`, have no effect with this layout.

**Then fix the kernel.** `/boot` isn't in the snapshot, so it still holds the newer kernel while `/usr/lib/modules` is back to the old one: hardware that needs a module not yet loaded may not work. Reinstall the snapshot's kernel versions from the package cache, then reboot again:

```bash
sudo pacman -S linux linux-lts
sudo reboot
```

Once everything works, delete the broken system: mount the top level as above, `sudo btrfs subvolume delete /mnt/@broken`, unmount.

## Housekeeping

Weekly timers from the `housekeeping` role; nothing runs during an apply.

| Timer | Does |
|---|---|
| `paccache.timer` | Keeps the last 3 versions of each package in `/var/cache/pacman/pkg/` (enough to downgrade from) |
| `llangvilla-nix-cleanup.timer` | Deletes home-manager generations older than `housekeeping_nix_keep`, then runs `nix-collect-garbage` |
| `llangvilla-firmware-check.timer` | Checks LVFS for firmware updates (`fwupd`). If there are any, the login message says so; install them with `sudo fwupdmgr update`, then reboot. It never installs anything itself |

Run one now with e.g. `sudo systemctl start llangvilla-firmware-check.service`; its output is in `journalctl -u llangvilla-firmware-check.service`.

## What goes in the config

| Goes in | Examples | Why |
|---|---|---|
| Base (`installer/packages.txt`) | Plasma, Plasma Login Manager, drivers, audio, Bluetooth, NetworkManager | Needed to boot to a usable desktop; changes only on reinstall |
| Config (this directory) | Apps, themes, settings, anything you expect to change | Applies to the running machine with `apply.sh` |

The config may rely on the base: a role that themes the login screen checks that Plasma Login Manager is installed instead of installing it. It must not depend on installer settings; machine values such as the user name belong in `config/home/host.json`.

## Writing tasks

The first run happens before the login screen starts, and every run is as root. Tasks must:

- **Not restart or start `plasmalogin`/`display-manager`**, including from handlers. At first boot the login screen waits for this run, so first boot would hang for good (it has no time limit). Write the config file; the display manager reads it on start. Use `systemctl restart --no-block` if something must be triggered.
- **Not reboot.** The hook reboots once after a successful run. A reboot mid-run skips the done marker, so the hook would run again.
- **Not need a desktop session.** No user dconf, user systemd units, `loginctl`, or `kwriteconfig6` against a running session. Writing files under `/etc` or `/home/{{ user_name }}/.config` is fine.
- **Be idempotent.** A second run must report `changed=0`; `vm/test-vm.sh config` fails otherwise.
- **Put user-level settings in `config/home`** (home-manager), not in Ansible. For the rare user-level Ansible task, use `become: true` and `become_user: "{{ user_name }}"`.
- **Open a port in the role that adds the service**, with `community.general.ufw`. The firewall role blocks everything else incoming.
- **Use `community.general.pacman`** for packages, without `update_cache`: `apply.sh` has already done a full upgrade. Arch package names differ from other distros (`openssh`, `python-*`, `base-devel`). AUR packages need a helper (`paru`, `yay`) run as a normal user, never root.
- **Put Plasma Login Manager settings in `/etc/plasmalogin.conf.d/*.conf`**, not `/etc/plasmalogin.conf`.

## Making a change

1. Edit the role, or add one and list it in `site.yml`.
2. Lint: `make lint-yaml lint-ansible` (and `make lint-nix` for `config/home`), as CI does.
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
| `Apply the user layer` fails | Read the home-manager error in the output. A file it won't replace: move it aside and re-run. A Nix permission error: check `nix-daemon.socket` is running and `allowed-users` in `/etc/nix/nix.conf` (Arch's default lets every local user in) |
| `Check out each Colloid theme` fails | GitHub unreachable, or a pinned commit no longer exists upstream. Pick another commit |
| `First-boot configuration FAILED` on the console or at SSH login | The first run failed. Read the newest log in `/var/log/llangvilla/` (or `journalctl -u llangvilla-firstboot.service -b`), fix, then reboot to retry |
| `Another apply.sh is already running` | Another run (the first-boot hook, or another terminal) holds the lock in `/run/llangvilla-apply.lock`. Wait for it, or check with `pgrep -af apply.sh` |
| SSH times out for a while after many quick connections | The firewall's rate limit (6 new connections in 30 s from one address). Wait half a minute, and reuse connections in scripts: `ControlMaster`/`ControlPersist` in `~/.ssh/config` |
| A service on the machine isn't reachable from the network | The firewall blocks incoming traffic. Open its port in the role that adds the service (`community.general.ufw`), not by hand |
| A run hangs | A task restarts the display manager or waits for a desktop session (see [Writing tasks](#writing-tasks)) |
