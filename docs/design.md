# Design

What the machine is meant to be, and the choices about its look. Brought into the repo from the original target design (November 2026), keeping only what still holds; how each part works is in the part READMEs, and why things are done this way is in [decisions](decisions.md).

## The end state

An OptiPlex that installs itself from a USB stick and boots to a Mac-like KDE Plasma desktop. Every setting and dotfile comes from this repo, and one command, `sudo /opt/llangvilla/config/apply.sh`, re-applies it.

| Layer | Owns | Where |
|---|---|---|
| Base (installer) | Arch Linux, systemd-boot, btrfs, KDE Plasma on Wayland, Plasma Login Manager | [`installer/`](../installer/README.md) |
| System (Ansible) | Apps, the system-wide Colloid theme, fonts, the login screen's look, the avatar, Nix, housekeeping | [`config/ansible`](../config/README.md) |
| User (home-manager + plasma-manager) | The Mac-like layout, theme selection, shortcuts, dotfiles; pinned by `flake.lock` | [`config/home`](../config/README.md#user-layer) |

The VM test is the proof: it installs, applies the config twice (the second run must change nothing), logs in and checks what you would see ([vm](../vm/README.md)).

## The look

The Mac feel comes mostly from the layout, which plasma-manager sets in `config/home/modules/plasma.nix`. Colloid dark supplies the rounded shapes and colours, and Inter is the interface font. The names live in `config/home/theme.json`, shared by the desktop and the login screen.

```
┌──────────────────────────────────────────────────────────────┐
│ Arch launcher                                  tray   clock  │  top bar, 28 px
│                                                              │
│   ● ● ●  window title         (buttons on the left)          │
│                                                              │
│                                                              │
│                 ┌──────────────────────────┐                 │
│                 │  dock: files, Firefox,   │                 │  floating, centred,
│                 │  Konsole, Kate, Settings │                 │  moves out of the way
│                 └──────────────────────────┘                 │
└──────────────────────────────────────────────────────────────┘
```

| Part | Uses | Installed by | Selected by |
|---|---|---|---|
| Global Theme | "Colloid Dark", ours: the parts below with Breeze widgets; current, and the default for light and dark | `theme` (Ansible) | `plasma.nix` |
| Plasma style and window decorations | Colloid dark | `theme` | `plasma.nix` |
| Colour scheme | Colloid's own dark scheme, blue accent | `theme` | `plasma.nix`; the login screen by `login_screen` |
| Qt widgets | Breeze, coloured by the scheme (not Kvantum) | the base | `plasma.nix` |
| GTK 3 and 4 | Colloid-gtk, dark | `theme` | `gtk.nix` |
| Icons | Papirus-Dark (flat, made for dark backgrounds; Colloid's app icons sit on white tiles) | `theme` | `plasma.nix`, `gtk.nix`; the login screen by `login_screen` |
| Cursor | Colloid dark, 24 px, one theme everywhere | `theme` | `plasma.nix`, `gtk.nix`; the login screen by `login_screen` |
| Fonts | Inter (interface), JetBrains Mono Nerd Font (monospace) | `packages` | `plasma.nix`, `gtk.nix` |
| Wallpaper | A lofi seafront at dusk (pier, moored boats, a cat), drawn as an SVG (`config/assets/seafront.svg`) and rendered at 3840×2160 | `login_screen` | `plasma.nix`: desktop and lock screen; `login_screen`: login screen |

- **Window buttons** on the left. Colloid's decorations already draw them as red, yellow and green circles, so no recolouring.
- **KRunner** on Meta+Space acts as a Spotlight-style launcher.
- **Login screen**: Plasma Login Manager, one user, no autologin: it opens on that user with the password field ready.
- **Login splash**: none; Plasma goes straight from the password to the desktop (`plasma.nix`).
- **Boot**: systemd-boot, no boot theme for now.

## Menus: no menu bars

Of the options considered (a global menu in the top bar; menu bars as they are; app menus only where an app has none of its own; no menu bars at all), the choice was **no menu bars**: KDE apps get their menu bar switched off in each app's config and use their ☰ button, and the top bar shows no menus. `Ctrl+M` brings an app's menu bar back. Set in `config/home/modules/apps.nix`; every new GUI app gets its ☰ or compact-menu setting turned on where it has one.

## Still open

- Shell, prompt and editor, and which configs to edit in place rather than re-apply ([#15](https://github.com/cqkh42/llangvilla/issues/15)).
- Boot menu hidden or visible.
- Deferred: Catppuccin colours, Kvantum, another terminal, Flatpak, a Plymouth splash ([#16](https://github.com/cqkh42/llangvilla/issues/16)); light mode via Plasma's light/dark switching; a second machine with its own `host.json`.
