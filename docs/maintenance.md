# Maintenance

What looking after the machine and the repo involves, and where the details are. This page links rather than repeats: the part READMEs say how each thing works.

## Routine

| Task | When | What to do | Details |
|---|---|---|---|
| Apply the config | After pushing a change, and every week or two for updates (a notice says so after 14 days) | `sudo /opt/llangvilla/config/apply.sh`: pulls, shows the Arch news since the last upgrade, upgrades the whole system (snapshot first), applies. If a news post asks for a manual step, stop it (Ctrl+C in the 20 s pause) and do that first | [config: Usage](../config/README.md#usage) |
| Reboot, log out, or restart a service | When `apply.sh` says so at the end | `Reboot needed` (kernel upgraded): reboot soon, before plugging in new hardware. `Log out and in`: when convenient. `Services still using replaced libraries`: `sudo systemctl restart UNIT`, or reboot | [config: Usage](../config/README.md#usage) |
| Install firmware updates | When a notice says firmware updates are available (checked weekly) | `fwupdmgr get-updates` to see them, `sudo fwupdmgr update`, then reboot | [config: Housekeeping](../config/README.md#housekeeping) |
| Act on a disk notice | When a notice reports disk problems (checked weekly) | **Back up first** ([#20](https://github.com/cqkh42/llangvilla/issues/20)). SMART failing: replace the disk, then [reinstall](#reinstalling). btrfs errors: `sudo btrfs device stats /` and `sudo btrfs scrub status /`; errors that keep growing mean the disk is going | [config: Housekeeping](../config/README.md#housekeeping) |
| Undo a bad upgrade | When something broke after an `apply.sh` | Roll back soon: every run takes a new snapshot and only the newest 3 are kept | [config: Snapshots](../config/README.md#snapshots) |
| Look at a failed first boot | `First-boot configuration FAILED` on the console or at SSH login | The newest log in `/var/log/llangvilla/`, fix, reboot to retry | [installer: Troubleshooting](../installer/README.md#after-the-install) |

Notices are notifications at desktop login, and the login message over SSH and on the console; a clean check removes its own. Cleaning up is automatic: the package cache, old home-manager generations and the Nix store are pruned weekly, and `/` is scrubbed monthly ([config: Housekeeping](../config/README.md#housekeeping)).

## Dependency bumps

| Dependency | Bumped by | Merged |
|---|---|---|
| GitHub Actions | Dependabot, weekly (Sundays) | Automatically, once lint passes |
| The linters (`.github/lint/requirements.txt`) | Dependabot, weekly | Automatically, once lint passes |
| nixpkgs, home-manager, plasma-manager (`config/home/flake.lock`) | Dependabot, weekly; the VM test runs on the PR | **By you**, once the VM test is green |
| Colloid themes (`config/ansible/roles/theme/defaults/main.yml`) | The upstream check opens an issue with the new commit, weekly | **By hand**: paste the commit, run the VM test, open a PR |
| Ventoy (`installer/build-usb.sh`) | The upstream check opens an issue with the new version and its checked SHA-256, weekly | **By hand**: paste both, open a PR. A stick that already has Ventoy keeps its old version ([#46](https://github.com/cqkh42/llangvilla/issues/46)) |
| Arch packages, the ISO's `archlinux` image | Not pinned (rolling) | The weekly VM test catches breakage; snapshots are the undo |

Dependabot is configured in `.github/dependabot.yml`, the merging in `.github/workflows/dependabot-automerge.yml`, the upstream check in `.github/workflows/upstream-check.yml` (run it by hand from the Actions tab). The reasons are [decision 15](decisions.md#15-dependency-bumps-dependabot-wherever-it-can-an-upstream-check-for-the-rest).

## When CI goes red

| What | Likely cause | What to do |
|---|---|---|
| The weekly VM test fails on `main` | Arch changed something (a renamed package, a new default), since nothing here changed | Read the run's log, or the installer logs it uploads; reproduce with `make vm`. If an Arch package is at fault, waiting a few days often fixes it |
| Lint fails on a Dependabot linter bump | A new linter version has new rules | Fix the findings on the PR's branch, or hold the bump back in `.github/lint/requirements.txt` |
| A Nix bump's VM test fails | A change in nixpkgs, home-manager or plasma-manager | Read the failing step; fix in `config/home` on the PR's branch, or close the PR and wait for the next one |
| A step says `An SSH command timed out` | A command on the VM hung | [vm: Troubleshooting](../vm/README.md#troubleshooting) |

## Every few months

| Task | What to do | Details |
|---|---|---|
| Refresh the installer ISO | `installer/build-usb.sh --rebuild /dev/sdX` (it warns once the cached ISO is 90 days old), for a newer live kernel and firmware on the stick | [installer: Maintenance](../installer/README.md#maintenance) |
| Check the stick still works | `vm/test-vm.sh install --stick /dev/sdX`, then `vm/test-vm.sh boot` | [vm: Workflows](../vm/README.md#workflows) |
| Delete merged branches | Automatic once *Automatically delete head branches* is on (Settings → General; [#39](https://github.com/cqkh42/llangvilla/issues/39)). Until then, on the Branches page | — |

## Reinstalling

Planned, after a dead disk, or because a reinstall is the quickest fix. Everything but `/home` comes back from the repo; `/home` comes back only from a backup ([#20](https://github.com/cqkh42/llangvilla/issues/20): none are automatic yet, so **before a planned reinstall, back up `/home` by hand**: the installer wipes the disk).

1. **Replace the disk** if it failed. The new one can be any size from 40 GB; `TARGET_DISK=auto` picks the largest internal disk, or pin the new one by ID ([installer: Configure](../installer/README.md#3-configure)).
2. **Get a stick.** Re-run `installer/build-usb.sh /dev/sdX` on the old one to refresh it, then check its settings: `installer/install.sh --check "$V/arch-autoinstall/autoinstall.env"`. If it's gone, any Linux machine with Docker can build a new one; fill in `autoinstall.env` again (Wi-Fi, `openssl passwd -6` for the password hash). Nothing else is needed from the old machine.
3. **Install**: boot the stick ([installer: Installing](../installer/README.md#installing)). About 20 minutes, then it powers off. First boot applies the config before the login screen (with a fresh Nix download, a while longer) and reboots once.
4. **Restore `/home`** from the backup, if there is one, as the user, without the cache (`~/.cache`).
5. **Re-apply**: `sudo /opt/llangvilla/config/apply.sh`, so home-manager takes its own files back after the restore.
6. **Check**: no notice at login, `systemctl --failed` is empty, SSH works with your key. Re-add anything that lived only on the machine (SSH keys generated there, browser logins).
