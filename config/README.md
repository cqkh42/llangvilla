# Config: personalising the box (part 2)

Turns the clean base system from the installer (part 1, [`autoinstall/`](../autoinstall/README.md)) into *your* machine: apps, login screen theme, avatar, tweaks. It is live: you change it here and re-apply it on the running box as often as you like, with no stick and no reinstall.

Today it is an Ansible playbook. Nix home-manager will join it as a second step behind the same entrypoint.

## Layout

| Path | Purpose |
|---|---|
| `apply.sh` | **The entrypoint.** Pulls the checkout, installs Ansible if needed, runs the playbook. Everything (first boot, re-runs, the VM test) goes through it |
| `ansible/site.yml` | The playbook: roles `packages`, `sddm`, `setup_user` |
| `ansible/host_vars/optiplex.yml` | Per-machine values, e.g. `user_name` (must match `USER_NAME` from the installer) |
| `ansible/inventory.ini`, `ansible/ansible.cfg` | One host, `optiplex`, local connection |
| `ansible/roles/packages` | Apps and tools on top of the base, plus packages to remove (`plasma-welcome`) |
| `ansible/roles/sddm` | Catppuccin theme and SDDM drop-in config |
| `ansible/roles/setup_user` | The user's avatar for SDDM / AccountsService |
| `ansible/requirements.yml` | Collections, for linting only (Arch's `ansible` package ships them) |

## Running it

On the box, as root:

```bash
sudo /opt/llangvilla/config/apply.sh                    # git pull, then apply
sudo /opt/llangvilla/config/apply.sh -- --check --diff  # dry run: what would change
sudo /opt/llangvilla/config/apply.sh -- --tags sddm     # extra args go to ansible-playbook
sudo /opt/llangvilla/config/apply.sh --no-pull          # apply local edits without pulling
```

`/opt/llangvilla` is the checkout the first boot made. Any other checkout works too (`sudo ./config/apply.sh` from your own clone); without a `.git` it just applies the files as they are. A changed `apply.sh` takes effect in the same run, because it re-runs itself after pulling.

**A box installed before `config/` existed** (it ran `ansible-pull` on first boot) has no `/opt/llangvilla`. Once, as root: `git clone https://github.com/cqkh42/llangvilla.git /opt/llangvilla && /opt/llangvilla/config/apply.sh`.

**First boot:** the installer's first-boot hook clones the repo and runs `config/apply.sh` once, before the login screen appears (`autoinstall/README.md` section 10b). That is the only thing the installer knows about this part. Its log: `journalctl -u llangvilla-firstboot.service -b`.

## What belongs here vs. in the installer

The installer's `autoinstall/packages.txt` holds the **clean slate**: what the box needs to boot to a usable desktop on this hardware (Plasma, SDDM, drivers, audio, Bluetooth, networking, snapshot tooling). The installer also enables `sddm` and `bluetooth`.

Everything else lives here: apps, themes, settings, and anything you expect to change on the live machine. A change here applies with `apply.sh`; a change to `packages.txt` only applies at the next reinstall.

The config can rely on the base (the `sddm` role checks SDDM is there rather than installing it) but must not assume installer settings: values like the user name come from `host_vars`, and the playbook checks the user exists.

## Rules for the config

Because the first run happens before anyone logs in, and every run is as root:

- **Don't restart or start `sddm` / `display-manager`** (for example in a handler). At first boot SDDM is waiting for the config to finish, so this deadlocks until the 30-minute timeout. Write the config; SDDM reads it when it starts. If you must trigger something, use `systemctl restart --no-block`.
- **Don't reboot.** The first-boot hook reboots once by itself after a successful run. A reboot from inside the playbook ends the run before the hook's done marker is written, so it would run again.
- **No tasks that need a logged-in desktop session** (user dconf, user systemd units, `loginctl`, `kwriteconfig6` against a running session). Writing files into `/etc` or `/home/{{ user_name }}/.config` is fine.
- **Runs as root.** Use `become_user: "{{ user_name }}"` for user-level tasks.
- **Stay idempotent.** A second run must change nothing; the VM test checks this.
- **Arch specifics:** use `community.general.pacman`; package names differ from other distros (`openssh`, `python-*`, `base-devel`). AUR packages need a helper (`paru`, `yay`) built and run as a normal user, never root.
- **SDDM config goes in `/etc/sddm.conf.d/*.conf`**, not `/etc/sddm.conf`.

## Testing a change

1. Lint: `yamllint .` and `ansible-lint config/ansible` (CI runs both, plus a syntax check).
2. Try it in the VM against your **working tree**: `vm/test-vm.sh config` applies `config/` to the installed VM, applies it again to check nothing changes, and reboots to check the login screen comes up. Then `vm/test-vm.sh boot` to see it. See [`vm/README.md`](../vm/README.md).
3. Commit and push, then `sudo /opt/llangvilla/config/apply.sh` on the box.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `git pull failed` | Local edits or a diverged branch in `/opt/llangvilla`. Look with `git -C /opt/llangvilla status`; `--no-pull` applies as is. |
| `Check the login user exists` fails | `user_name` in `host_vars/optiplex.yml` doesn't match `USER_NAME` the installer used. |
| `Check SDDM is installed` fails | The base is missing SDDM: it comes from `autoinstall/packages.txt`. |
| First boot sits on console text for ages, then SDDM appears | The first run failed or hit the 30-minute timeout. `journalctl -u llangvilla-firstboot.service -b`, then fix and run `apply.sh` by hand (or reboot to retry). |
| A run hangs | Usually a task restarting SDDM or waiting for a desktop session. See the rules above. |
