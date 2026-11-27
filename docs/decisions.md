# Decisions

What was decided about how this repo works, and why. Newest last. When a decision changes, add an entry that says which one it replaces; don't rewrite history. The details live in the linked PRs and issues; the docs say how things work today.

Entries 1–19 come from the holistic review of November 2026; 20–26 from its follow-up.

## 1. One repository, three parts

**Decision:** keep the installer, the config and the VM test in one repo, as three separate parts. The only link between installer and config is the first-boot hook (a repo URL and an entrypoint path).

**Why:** one owner, one machine, one VM test that covers both parts. A split would mean pull requests across two repos and a VM test that fetches both, for no gain. The hook is already the seam, so a split later costs one `CONFIG_REPO_URL` change.

**Would change if:** the config needs to be private, the installer gets other users, or a second kind of machine arrives with a different lifecycle (see 2).

## 2. The repo stays public

**Decision:** public. The full name and avatar stay in the repo, by choice. Nothing secret or private goes in: dotfiles use GitHub's noreply address, and tokens or private settings stay in untracked files that the managed config includes (#15).

**Why:** first boot clones over HTTPS without credentials. A private repo would need a deploy key on the stick, a credential in the most fragile step.

## 3. Ansible for the system, Nix home-manager for the user

**Decision:** Ansible owns everything outside `$HOME` and runs as root. Its last role applies a home-manager flake (`config/home`) as the user. GUI apps, themes and anything Plasma or Qt loads come from pacman; dotfiles, settings and command-line tools come from Nix.

**Why:** declarative, pinned user settings that can roll back. Nix GUI apps need nixGL on Arch, Nix Qt plugins can't load into Arch's Qt, and system users (the login screen) can't see the Nix profile.

## 4. The base holds only what boots to a usable desktop

**Decision:** `installer/packages.txt` is Plasma, the login manager, drivers, audio, Bluetooth, networking, and `nano` as a rescue editor. Everything else, including build tools, man pages, reflector and the firewall's settings page, is in the config. Discover, `print-manager` and `plasma-vault` were dropped (#25).

**Why:** the config applies to the running machine; the base only changes on a reinstall. Discover did almost nothing on Arch without PackageKit, and would be a second upgrade path with it.

## 5. Every apply upgrades the whole system, and only reports what needs a restart

**Decision:** `apply.sh` runs `pacman -Syu` first, every time. Afterwards it reports a needed reboot (kernel upgraded), re-login (a session on replaced libraries) or service restarts. It never reboots or restarts anything itself (#17).

**Why:** on Arch, installing against a stale package database is a partial upgrade. Rebooting or restarting unasked would break first boot, which runs before the login screen.

## 6. First boot: everything before the login screen, no time limit

**Decision:** the whole config runs at first boot, before the login screen, with no time limit. The clone retries for about 5 minutes; a failure leaves a notice on the console and in SSH logins; every run is logged in `/var/log/llangvilla/`; a stale pacman lock is removed when no pacman runs (#17).

**Why:** killing the run mid `pacman -Syu`, as the old 30-minute limit could, may break the system. The machine isn't in use yet, and SSH and `Ctrl+Alt+F2` work meanwhile.

## 7. zswap off

**Decision:** `zswap.enabled=0` on the kernel command line, from the installer for new installs and the `boot` role for existing ones (#17).

**Why:** swap is zram; zswap in front of it only adds overhead (Arch wiki).

## 8. One file for the look

**Decision:** theme names, cursor, fonts and wallpaper live in `config/home/theme.json`, read by Nix and by the `login_screen` role (#17).

**Why:** they were spelled out in three places that had to agree. The file is in `config/home` because the flake can only read files inside its own directory.

## 9. home-manager overwrites its backups; the GTK files are forced

**Decision:** a second clash on a file replaces its `.backup` instead of failing the switch. The three GTK settings files are overwritten on every apply, without a backup (#23).

**Why:** with plain `-b backup`, a second clash fails the whole apply. The VM test saw Plasma replace `~/.gtkrc-2.0` at login. Rule: edit dotfiles in the repo, not on the machine.

## 10. A snapshot before every upgrade, the newest 3 kept; no snapper

**Decision:** `apply.sh` takes a read-only btrfs snapshot of `/` before each upgrade and keeps the newest 3. snapper and snap-pac are gone (#23).

**Why:** the config is idempotent but doesn't pin package versions, so a bad Arch upgrade comes back on every re-apply and reinstall; a snapshot is the undo. One snapshot would be replaced by the next run after a bad upgrade, so 3. snapper was installed but never configured, and its `snapper rollback` doesn't work with a layout whose boot entry names `subvol=@`.

## 11. A firewall: ufw

**Decision:** incoming traffic blocked, outgoing allowed, SSH allowed and rate-limited. A role that adds a listening service opens its own port (#24).

**Why:** cheap defence in depth: a new listening service has to be a decision. ufw is simple and backs Plasma's firewall settings page; firewalld's zones matter for laptops, not a desktop that doesn't move.

## 12. Weekly housekeeping

**Decision:** weekly timers keep the last 3 versions of each package, delete home-manager generations older than 30 days and collect Nix garbage, and check for firmware updates. The firmware check only notifies, through the login message; installing stays manual (#30).

**Why:** the package cache and the Nix store only grow otherwise. BIOS updates need a reboot, so they're a deliberate act.

## 13. The VM test runs the real first boot on the working tree

**Decision:** the test serves a snapshot of the working tree to the VM, whose first boot runs the real hook on it. The config phase then checks what the config produced, file by file, logs in through a test-only autologin, and re-applies (#26).

**Why:** the hand-over is the most fragile path, and it used to be tested only against `main`. The result checks catch changes that "succeed" without landing. On its first run this found a real bug: the login screen's colour scheme was rewritten on every apply after a reboot.

## 14. Every SSH command in the VM test has a time limit

**Decision:** 5 minutes by default, longer per step (applies 40). The job limit is a backstop at 75 minutes (#35).

**Why:** a hung command stalled a run for 41 minutes with its log hidden, and could have gone on to 150.

## 15. Dependency bumps: Dependabot wherever it can, an upstream check for the rest

**Decision:** Dependabot bumps GitHub Actions, the pinned linters and `flake.lock` weekly. Actions and linter bumps merge themselves once lint passes; Nix bumps get the VM test started and are merged by a person. A weekly upstream check opens issues for Colloid and Ventoy (#31).

**Why:** as little hand-work as possible, with a person's review where a bump changes what the machine runs. Colloid could go to Dependabot only as git submodules, which track branch heads rather than release tags and change how first boot fetches the repo.

## 16. One copy of every check: the Makefile

**Decision:** the checks are `make` targets, which CI and the docs both use. A link check covers the docs' relative links and anchors.

**Why:** the lint commands were written out in four places.

## 17. Backups: parked

**Decision:** backups of `/home` are needed but not designed yet (#20: destination and tool open).

**Why:** the design is "wipe and rebuild from the repo", and `/home` isn't in the repo, so today a reinstall loses it.

## 18. mDNS: backlog

**Decision:** not now (#29). First check whether the router already gives the machine a name.

## 19. Open: upgrading Ventoy on an existing stick

**Not decided yet.** Today `build-usb.sh` keeps whatever Ventoy a stick already has, so a newer pinned Ventoy only reaches new sticks, or ones rebuilt with `--force` (which wipes them). Ventoy's own non-destructive update (`Ventoy2Disk.sh -u`) could become an `--update-ventoy` option.

## 20. The VM test runs on pull requests

**Decision:** `vm-test.yml` runs on every PR that touches `installer/`, `config/` or `vm/`, Dependabot's Nix bumps included, as well as weekly and on demand ([#38](https://github.com/cqkh42/llangvilla/issues/38)). Replaces the "start it on the branch" step of 15 for Nix bumps.

**Why:** lint was the only automatic check, and every VM run had been started by hand. Twenty minutes on a free runner is cheap next to a broken first boot.

## 21. One installer path: btrfs, first boot before the login screen

**Decision:** `ROOT_FS=ext4` and `FIRSTBOOT_BEFORE_LOGIN=0` are gone ([#44](https://github.com/cqkh42/llangvilla/issues/44)).

**Why:** neither was ever tested. Snapshots before upgrades (10) need btrfs, and a background first boot combined with its reboot could restart the machine mid-session. One tested path beats two untested options.

## 22. One file for the machine's facts

**Decision:** the login user, keyboard layout and mirror countries live in `config/home/host.json`, read by Nix and Ansible, beside `theme.json` (8). `host_vars` is gone ([#40](https://github.com/cqkh42/llangvilla/issues/40)). The installer's `autoinstall.env` keeps its own copy (1).

**Why:** the user name alone was in five places that had to agree.

## 23. Removing things is explicit

**Decision:** `packages_remove` for packages; a `state: absent` task, kept until the machine has applied it, for a role's files. The theme role clears old files when a pin changes. App-like packages moved from the base to the config, where they can be removed ([#43](https://github.com/cqkh42/llangvilla/issues/43)).

**Why:** Ansible only converges on what it mentions; a package taken out of a list stayed installed for good, and anything in the base stayed until a reinstall.

## 24. Notices: in the login message and on the desktop

**Decision:** checks that find something write `/etc/motd.d/llangvilla-*`; an autostart entry from home-manager shows each one as a notification at desktop login. New checks: disk health weekly (SMART, btrfs errors, the monthly scrub) and an apply reminder after 14 days. `apply.sh` prints the Arch news since the last upgrade before upgrading ([#41](https://github.com/cqkh42/llangvilla/issues/41), [#42](https://github.com/cqkh42/llangvilla/issues/42)).

**Why:** the login message only shows over SSH and on the console, so on a desktop the firmware notice went unseen. With no backups yet (17), a failing disk needs saying early; and upgrades happen only when `apply.sh` is run, so it needs a nudge and the news that may need a manual step.

## 25. Docs: one home per fact; open questions are issues

**Decision:** each fact is described in one place and linked from the others; `CLAUDE.md` holds only what an agent needs beyond the READMEs; the design lives in `docs/design.md`, not on claude.ai. This log holds decisions only: open questions and parked work are issues. Entries 17–19 are tracked as [#20](https://github.com/cqkh42/llangvilla/issues/20), [#29](https://github.com/cqkh42/llangvilla/issues/29) and [#46](https://github.com/cqkh42/llangvilla/issues/46) ([#45](https://github.com/cqkh42/llangvilla/issues/45)).

**Why:** the role list, the `make` targets and the first-boot hook were each written out in three or four places that drifted; the design doc was outside the repo, so code comments pointed at nothing a reader could open.

## 26. A dry run is an apply.sh option

**Decision:** `apply.sh --dry-run` runs the playbook in check mode with `--diff`, with no upgrade and no snapshot; the user layer is built, not switched to. It replaces `--no-upgrade -- --check --diff`, and `apply.sh` no longer looks inside ansible's arguments. The VM test runs it after a clean apply and expects no changes.

**Why:** spotting a dry run by matching `--check` in the arguments missed combined flags like `-CD`, and a dry run that skipped the user layer said nothing about it. One option is easier to remember than three flags.
