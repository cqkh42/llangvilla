# config

Personalises an installed machine: apps, fonts, the Colloid theme, the login screen's look, the avatar and system tweaks. It runs once on first boot through the installer's [first-boot hook](../installer/README.md#first-boot-hook), then again whenever the config changes. No USB stick or reinstall is needed.

It is an Ansible playbook behind a single entrypoint, `apply.sh`. Ansible owns the system; its last role runs Nix home-manager, which owns the user's home: the Plasma layout and settings, GTK, git and the shell. See [User layer](#user-layer).

## Quick start

```bash
sudo /opt/llangvilla/config/apply.sh             # pull, upgrade, apply
sudo /opt/llangvilla/config/apply.sh --dry-run   # what would change
```

To change the config, see [Making a change](#making-a-change).

## Usage

```
apply.sh [--no-pull] [--no-upgrade | --dry-run] [-- ANSIBLE-PLAYBOOK-ARGS...]
```

Run as root. `apply.sh` does the following:

1. Unless `--no-pull`: if its directory is in a git checkout, runs `git pull --ff-only` and re-runs the updated `apply.sh`.
2. Unless `--no-upgrade`: prints the [Arch news](https://archlinux.org/news/) posted since the last upgrade (some posts announce a manual step; at a terminal it waits 20 s so you can stop), takes a [snapshot](#snapshots), then upgrades the whole system with `pacman -Syu`. On Arch, installing packages against a stale package database is a partial upgrade, which can break the system, so the playbook always starts from a current one.
3. Installs `ansible` with pacman if `ansible-playbook` is missing.
4. Runs `ansible-playbook site.yml` from `config/ansible/`, passing any arguments after `--`.
5. After an upgrade, even a failed run, says what still runs old code. It never acts on it itself:
   - **Reboot needed**: the running kernel was upgraded, so its modules are gone (plugging in new hardware can fail until you reboot).
   - **Log out and in**: a desktop or login session still uses replaced libraries (Qt, KDE, Mesa and so on).
   - **Services still using replaced libraries**: restart them with `systemctl restart`, or reboot.
6. After a successful run with an upgrade, records it in `/var/lib/llangvilla/last-upgrade`: the next run's news start from there, and the daily [apply reminder](#housekeeping) counts from it.

Only one run at a time: a second `apply.sh` while one is running exits with `Another apply.sh is already running`.

Every run is also logged to `/var/log/llangvilla/apply-<date>-<time>.log` (the newest 20 are kept). A pacman lock left by a run that was cut off (a power cut, say) is removed when no pacman is running, so the next run can start.

| Option | Effect |
|---|---|
| `--no-pull` | Apply the files as they are. Used by the VM test and for local edits |
| `--no-upgrade` | Skip the system upgrade. A real run should upgrade |
| `--dry-run` | Show what would change and change nothing: no upgrade, no snapshot, the playbook in check mode with `--diff`. The user layer is built, not switched to. Needs a machine that has been applied once (ansible installed) |
| `-- ARGS` | Passed to `ansible-playbook`, e.g. `-- --tags user_avatar`, `-- -v`, `-- --diff`. Each role has a tag of its own name |
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
├── assets/                        the wallpaper (SVG source, 3840×2160 render) and the avatar
├── home/                          the user layer: a Nix flake for home-manager
│   ├── flake.nix, flake.lock      inputs (nixpkgs, home-manager, plasma-manager), pinned by the lock
│   ├── home.nix                   settings every user gets
│   ├── theme.json                 the look: theme names, fonts, wallpaper (read by Nix and Ansible)
│   ├── host.json                  the machine: login user, keyboard layout, mirror countries, weather place (likewise)
│   └── modules/                   plasma.nix (the Mac layout), gtk.nix, apps.nix (☰ menus), git.nix, shell.nix, notices.nix
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
        ├── plasma_widgets/        third-party Plasma widgets built from source (Panel Colorizer)
        ├── login_screen/          Plasma Login Manager: wallpaper, colours, icons, cursor, font
        ├── user_avatar/           user avatar, through AccountsService
        ├── nix/                   Nix from pacman, daemon socket, flakes
        ├── housekeeping/          timers: package cache, Nix cleanup, btrfs scrub; firmware, disk and apply checks
        └── home_manager/          runs home-manager switch as the user (last role)
```

## Variables

| Variable | Defined in | Default | Description |
|---|---|---|---|
| `host` | `site.yml`, from `config/home/host.json` | `jack`, `gb`, `[GB]`, Tur Langton | The machine's facts, shared with the user layer: login user, keyboard layout, mirror countries, and the top bar's weather place (as BBC Weather names it, with its BBC location id: the number in a bbc.co.uk/weather/… link). Change them there |
| `user_name` | `site.yml`, `host.user` | `jack` | Login user. Must match `USER_NAME` from the installer; the playbook fails if the user doesn't exist. The flake's `homeConfigurations` entry is named from the same file |
| `firewall_ssh_port` | `roles/firewall/defaults/main.yml` | `22` | SSH's port, allowed through the firewall with a rate limit (6 new connections in 30 s per address) |
| `packages_install` | `roles/packages/defaults/main.yml` | kate, ark, firefox and its Plasma integration, spectacle, the system monitor, vim, htop, btop, man pages, media codecs, base-devel, Inter, JetBrains Mono Nerd Font | Installed with pacman |
| `packages_remove` | `roles/packages/defaults/main.yml` | `[]` | Removed with pacman, with the dependencies only they needed ([Removing things](#removing-things)) |
| `mirrors_countries`, `mirrors_latest` | `roles/mirrors/defaults/main.yml` | `host.mirrorCountries`, `10` | reflector's mirror choice: the 10 most recently synced HTTPS mirrors in those countries, sorted by speed, written to `/etc/pacman.d/mirrorlist` weekly |
| `theme_colloid_*_version` | `roles/theme/defaults/main.yml` | pinned commits | The Colloid KDE, icon and GTK themes. Change a commit to upgrade that theme ([Themes](#themes)) |
| `plasma_widgets_colorizer_version` | `roles/plasma_widgets/defaults/main.yml` | v8.2.0's commit | Panel Colorizer, built from source ([Themes](#themes)) |
| `look` | `site.yml`, from `config/home/theme.json` | Colloid dark, 24 px cursor, Inter 10, Seafront | The look, shared by the login screen (Ansible) and the desktop and GTK (`config/home`). Change it there, not in a role |
| `login_screen_color_scheme`, `_icon_theme`, `_cursor_theme`, `_cursor_size`, `_font` | `roles/login_screen/defaults/main.yml` | from `look` | The login screen's look |
| `user_avatar_src` | `roles/user_avatar/defaults/main.yml` | `assets/avatar.png` | The login user's picture, on the login screen and in Plasma |
| `login_screen_wallpaper_*` | `roles/login_screen/defaults/main.yml` | `assets/seafront-3840x2160.jpg`; name and size from `look` | Installed as the `Seafront` wallpaper package, used by the login screen, and by the desktop and lock screen (`config/home/modules/plasma.nix`) |
| `housekeeping_apply_max_days` | `roles/housekeeping/defaults/main.yml` | `14` | The apply reminder writes a notice once the last successful upgrade by `apply.sh` is older than this |
| `housekeeping_nix_keep` | `roles/housekeeping/defaults/main.yml` | `30d` | Home-manager generations older than this are deleted weekly, then unused Nix store paths: the user layer can be rolled back this far |
| `home_manager_flake_dir` | `roles/home_manager/defaults/main.yml` | `config/home` next to the playbook | The flake to apply |
| `login_screen_config_file` | `roles/login_screen/defaults/main.yml` | `/etc/plasmalogin.conf.d/10-llangvilla.conf` | Where the wallpaper setting goes |

## User layer

`config/home/` is a Nix flake for [home-manager](https://github.com/nix-community/home-manager), which owns everything in the user's home. The `home_manager` role applies it as the user:

```bash
nix run path:config/home#home-manager -- switch -b backup --flake path:config/home#<user>   # user from host.json
```

- **Pinned.** `flake.lock` fixes nixpkgs, home-manager and plasma-manager. Nothing changes until you run `nix flake update` in `config/home`, test in the VM and commit the new lock.
- **`path:`, not git.** The checkout in `/opt/llangvilla` belongs to root and the VM test copies `config/` without `.git`; a `path:` reference works for both.
- **Existing files are backed up once.** `-b backup` moves a file home-manager would replace to `*.backup` (the stock `~/.bashrc` becomes `~/.bashrc.backup`). A later clash on the same file replaces that backup instead of failing the switch (`HOME_MANAGER_BACKUP_OVERWRITE`), so edit dotfiles in the repo, not on the machine. The three GTK files are overwritten without any backup, since Plasma's GTK sync may rewrite them (`gtk.nix`).
- **First run is slow.** It fetches nixpkgs and downloads from cache.nixos.org, which first boot waits for (it has no time limit). Later runs take seconds.
- **Reported as changed** only when the switch produces a new generation, so the second-run check still works.
- **Plasma in two steps.** [plasma-manager](https://github.com/nix-community/plasma-manager) writes the settings files during the switch (fonts, window buttons, menu bars). The colour scheme, icons, cursor, wallpaper and panels need a running Plasma, so its autostart entry applies them at the next login. The wallpaper and panels go through Plasma desktop scripts, which plasma-manager runs with a bare `qdbus`; Arch only names it `qdbus6`, so the role installs `qt6-tools` and links `/usr/local/bin/qdbus` (without it the desktop keeps Plasma's default panel and wallpaper). A script that failed runs again at each login until it succeeds. With `overrideConfig = true` the repo always wins: changes made in System Settings are reset on the next apply.
- **No dconf.** home-manager's dconf writes need a D-Bus session during the switch, which first boot doesn't have; on Plasma, GTK 4 apps get the dark preference from KDE's portal instead.

| Module | Sets |
|---|---|
| `plasma.nix` | Colloid dark (style, colours, icons, cursor, decorations), Breeze widgets, buttons on the left, Inter / JetBrains Mono, top bar (Arch-logo launcher, tray without Brightness & Color, clock), floating dock that moves out of the way, KRunner on Meta+Space, wallpaper on desktop and lock screen |
| `gtk.nix` | GTK 3/4 theme, icons, cursor and font to match |
| `apps.nix` | Menu bars off in Dolphin, Kate, Ark and Konsole (☰ menus; Ctrl+M brings one back) |
| `git.nix`, `shell.nix` | Git behaviour (no identity yet) and bash |
| `notices.nix` | Shows the config's notices (`/etc/motd.d/llangvilla-*`) as desktop notifications at login ([Housekeeping](#housekeeping)) |

What goes where:

| Comes from | What | Why |
|---|---|---|
| pacman (Ansible) | GUI apps, themes, fonts, anything that plugs into Plasma or Qt | Nix GUI apps need nixGL on Arch; Nix Qt plugins can't load into Arch's Qt; system users (the login screen) can't see the Nix profile |
| Nix (home-manager) | Dotfiles, settings, command-line tools | Declarative, pinned, roll back with `home-manager generations` |

To add something, add a module under `modules/`, import it from `home.nix`, then follow [Making a change](#making-a-change) (`make fmt-nix` formats it).

## Themes

The `theme` role installs Colloid dark and the Papirus icons into `/usr/share`, so the login screen, which runs as a system user, can use it as well. Choosing it for your own session is the user layer's job (`config/home/modules/plasma.nix` and `gtk.nix`).

| Part | From | Installed as |
|---|---|---|
| Plasma style, window decorations, colour scheme | [Colloid-kde](https://github.com/vinceliuice/Colloid-kde) | `Colloid-dark`, `ColloidDark` |
| Icons | [Papirus](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme) (Arch's `papirus-icon-theme`) | `Papirus-Dark` (and `Papirus`, `Papirus-Light`) |
| Cursors | [Colloid-icon-theme](https://github.com/vinceliuice/Colloid-icon-theme) | `Colloid-cursors`, `Colloid-dark-cursors` |
| GTK 3/4 theme | [Colloid-gtk-theme](https://github.com/vinceliuice/Colloid-gtk-theme) | `Colloid-Dark` (built with `sassc`) |
| Global Theme | Ours: the parts above with Breeze widgets, Colloid's previews | `org.llangvilla.colloid-dark` ("Colloid Dark") |

Which installed theme, icons, cursor, fonts and wallpaper are *used* is set in one place, `config/home/theme.json`: the login screen (`login_screen` role) and the desktop and GTK apps (`plasma.nix`, `gtk.nix`) all read it, so they can't drift apart. It lives in `config/home` because the Nix flake can only read files inside its own directory.

Each theme is pinned to a commit in `roles/theme/defaults/main.yml`. The role checks it out under `/var/lib/llangvilla/src/` and installs it. The icon and GTK installers run once per commit; a stamp in `/var/lib/llangvilla/stamps/` records it. To upgrade, set a newer commit (a release tag's commit where there is one), run `vm/test-vm.sh config`, then apply. The weekly upstream check opens an issue with the commit to paste when there's a newer one ([dependency bumps](../docs/maintenance.md#dependency-bumps)).

Colloid's own Global Theme (look-and-feel package) is not installed: its defaults name Kvantum as the widget style, and Kvantum is not used. The role writes a Global Theme of its own instead, from `theme.json` (`roles/theme/templates/look-and-feel-defaults.j2`). `plasma.nix` still selects each part individually, and makes this Global Theme the current one and Plasma's default for both light and dark, so the tray's light/dark switch stays on Colloid. It has no layout, so applying it in System Settings leaves the panels alone.

The Plasma style isn't copied as-is: `roles/theme/files/install-plasma-style.py` removes stale colour stylesheets from Colloid's SVGs, which otherwise keep the panel, dock and tray light whatever the colour scheme. It also leaves out Colloid's style icons (thin line icons that would win over the icon theme), so the tray draws Papirus's. It runs once per pinned commit, like the icon and GTK installers.

The top bar's translucent, blurred look is [Panel Colorizer](https://github.com/luisbocanegra/plasma-panel-colorizer), a widget with a C++ plugin. The `plasma_widgets` role builds both from its pinned release into `/usr`, like Arch's AUR package, and builds again whenever `qt6-base`, `qt6-declarative`, `libplasma` or `layer-shell-qt` change version (their versions are in its stamp): upstream warns a stale plugin can crash Plasma after an upgrade, and `apply.sh` upgrades first. Its settings are in `plasma.nix` (`colorizer`); the widget is hidden on the bar, so change them there, not in the widget's own settings window, which the next apply resets. If Plasma crashes at login after an upgrade, `sudo rm -rf /usr/lib/qt6/qml/org/kde/plasma/panelcolorizer` brings it back without the blur, and the next apply rebuilds it.

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

Timers from the `housekeeping` role; nothing runs during an apply.

| Timer | When | Does |
|---|---|---|
| `paccache.timer` | Weekly | Keeps the last 3 versions of each package in `/var/cache/pacman/pkg/` (enough to downgrade from) |
| `llangvilla-nix-cleanup.timer` | Weekly | Deletes home-manager generations older than `housekeeping_nix_keep`, then runs `nix-collect-garbage` |
| `btrfs-scrub@-.timer` | Monthly | btrfs-progs' own scrub of `/`: reads every block and checks its checksum |
| `llangvilla-firmware-check.timer` | Weekly | Checks LVFS for firmware updates (`fwupd`). Install them with `sudo fwupdmgr update`, then reboot. It never installs anything itself |
| `llangvilla-disk-check.timer` | Weekly | SMART health of every disk `smartctl` can see, btrfs's error counters on `/`, and the last scrub's result |
| `llangvilla-apply-reminder.timer` | Daily | Whether the last successful upgrade by `apply.sh` is older than `housekeeping_apply_max_days` (14) |

The checks never fail their unit. When they find something, they write a **notice**: a file in `/etc/motd.d/llangvilla-*`, which the login message shows over SSH and on the text console. At each desktop login, `config/home/modules/notices.nix` shows every notice as a notification that stays until dismissed (so does the installer's first-boot failure notice). A clean check removes its notice.

Run one now with e.g. `sudo systemctl start llangvilla-disk-check.service`; its output is in `journalctl -u llangvilla-disk-check.service`. The checks are scripts in `roles/housekeeping/files/`, listed in `housekeeping_checks`; add one there to add a check.

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

## Removing things

The config adds and changes things; it doesn't notice what it no longer mentions. Taking a package out of `packages_install`, a file out of a role, or a whole role out of `site.yml` leaves it on the machine. To really remove something:

| What | How |
|---|---|
| A package | Move it from `packages_install` to `packages_remove`. Once the machine has applied it, empty `packages_remove` again |
| A file or directory a role wrote | Add a task to that role with `state: absent` and a comment saying what it retires (the `theme` role's look-and-feel task is one). Delete the task once the machine has applied it |
| A whole role | Replace its tasks with the `state: absent` tasks for what it wrote (disable its services first), apply, then delete the role and its line in `site.yml` |
| A package from the base (`installer/packages.txt`) | Take it out of the list and add it to `packages_remove`: the base never removes anything itself |
| A theme file upstream dropped | Nothing to do: the `theme` role clears the old files whenever a pinned commit changes |

There is one machine, so a retiring task only has to stay until it has applied once; the VM test applies everything from scratch anyway.

## Making a change

1. Edit the role, or add one and list it in `site.yml`.
2. Lint: `make lint-yaml lint-ansible`, and `make lint-nix` for `config/home` ([the make targets](../README.md#development)).
3. Test against the working tree: `make vm-config` on an existing test VM, then `vm/test-vm.sh boot` to look at it ([vm](../vm/README.md)). The PR runs the full VM test.
4. Merge, then run `sudo /opt/llangvilla/config/apply.sh` on the machine (`--dry-run` first to see what it will do).

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
