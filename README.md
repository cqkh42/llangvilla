# llangvilla

Configuration for the home network. Currently one machine: a Dell OptiPlex desktop (`optiplex`) running Arch Linux with KDE Plasma.

## Overview

The repository has three independent parts:

| Part | Directory | Purpose | Runs |
|---|---|---|---|
| Installer | [`installer/`](installer/README.md) | Ventoy USB stick that wipes the machine and installs a clean base system | On a reinstall |
| Config | [`config/`](config/README.md) | Personalises the installed system: apps, theming, settings. Ansible for the system, then Nix home-manager for the user's home | On first boot, then whenever the config changes |
| VM | [`vm/`](vm/README.md) | Runs the installer and the config from the working tree in a QEMU VM | Before changes reach the real machine |

```mermaid
flowchart LR
    subgraph installer["installer/"]
        A[build-usb.sh] --> B[USB stick] --> C[install.sh] --> D[base system]
    end
    subgraph config["config/"]
        E[apply.sh] --> F[Ansible playbook] --> I[home-manager]
    end
    D -- "first-boot hook<br/>(clone + run once)" --> E
    G([manual re-run]) --> E
    subgraph vm["vm/"]
        H[test-vm.sh] -.-> C
        H -.-> E
    end
```

## Quick start

Reinstall the machine from scratch:

```bash
eval "$(installer/build-usb.sh /dev/sdX)"                   # build the stick
nano "$V/arch-autoinstall/autoinstall.env"                  # fill in Wi-Fi and password hash
installer/install.sh --check "$V/arch-autoinstall/autoinstall.env"
# boot the machine from the stick; it installs and powers off
```

Apply a config change to the running machine:

```bash
sudo /opt/llangvilla/config/apply.sh
```

Try a change in a VM first:

```bash
vm/test-vm.sh            # full install + config from the working tree
vm/test-vm.sh config     # re-apply config/ to an existing test install
vm/test-vm.sh boot       # open the VM in a window
```

## Repository layout

```
.
├── installer/        part 1: ISO build, USB stick, install.sh, base package list
├── config/           part 2: apply.sh, the Ansible playbook, the home-manager flake
├── vm/               part 3: the VM test
├── docs/             maintenance.md (routine tasks), decisions.md (what was decided, and why)
├── Makefile          every check: make lint, make vm
└── .github/          CI (lint on every push, VM test weekly), Dependabot, upstream check
```

Each part's README has its own layout: [installer](installer/README.md#how-it-works), [config](config/README.md#layout), [vm](vm/README.md).

## How the parts connect

The installer and the config share one interface, the **first-boot hook**:

1. The installer writes a systemd unit, `llangvilla-firstboot.service`, into the new system.
2. On first boot the unit clones this repository to `/opt/llangvilla` and runs `config/apply.sh` once, before the login screen starts.
3. After that the installer is out of the picture. The checkout stays at `/opt/llangvilla`, and `apply.sh` is re-run by hand.

Rules that keep the parts independent:

- The installer knows the repository URL and the entrypoint path, nothing about Ansible.
- The config relies on the base system from `installer/packages.txt`, not on installer settings. Values such as the user name live in the config's own variables.
- A package goes in the base only if the machine needs it to boot to a usable desktop. Everything else goes in the config. See [`config/README.md`](config/README.md#what-goes-in-the-config).

## Development

All checks are `make` targets, used by CI too (`.github/workflows/lint.yml`):

| Target | Checks |
|---|---|
| `make lint` | Everything below that needs no VM |
| `make lint-shell` | ShellCheck on every script |
| `make lint-env` | The `autoinstall.env` template passes `install.sh --check` once filled in, and is rejected as it is |
| `make lint-yaml`, `make lint-ansible` | yamllint; ansible-lint and a playbook syntax check |
| `make lint-nix` | `nix flake check` (which builds the home configuration) and nixfmt (`make fmt-nix` formats) |
| `make lint-docs` | Relative links and `#section` anchors in the Markdown files |
| `make vm`, `make vm-config` | The VM test: everything, or re-apply `config/` to the existing test VM ([vm](vm/README.md)). CI runs it weekly and on demand |

Install the linters, at the versions CI uses, with `pip install -r .github/lint/requirements.txt`. Dependencies are bumped by Dependabot and a weekly upstream check ([maintenance: dependency bumps](docs/maintenance.md#dependency-bumps)).

Never commit real Wi-Fi credentials, password hashes or a filled-in `autoinstall.env`. They live only on the USB stick (see [Security](installer/README.md#security)).
