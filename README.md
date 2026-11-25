# llangvilla
Llangvilla and the home network. 

## Optiplex

Runs Arch Linux (KDE Plasma). The repo has three separate parts:

| Part | What | Lives in | When it runs |
|---|---|---|---|
| 1. Clean slate | A USB stick that wipes the box and installs a clean base system (user, network, SSH, desktop, bootloader) | [`autoinstall/`](autoinstall/README.md) | Rarely: a reinstall |
| 2. Config | Personalises the box: apps, theming, settings. Ansible today, Nix home-manager later | [`config/`](config/README.md) | Often, on the live box: `sudo /opt/llangvilla/config/apply.sh` |
| 3. VM | Runs 1 and 2 from the working tree in a VM, to test them and see how it looks and feels | [`vm/`](vm/README.md) | Before either reaches the real box |

```
 build-usb.sh ──► stick ──► install.sh ──► clean base ──first boot──► config/apply.sh ◄── re-run any time
   (part 1)                  (part 1)        system        hook           (part 2)
                                                         (the only link)

 vm/test-vm.sh: install ──► check base ──► apply config/ ──► check again ──► boot to look around   (part 3)
```

The boundary between 1 and 2: the installer builds the base and, on first boot, clones this repo and runs `config/apply.sh` once. It knows nothing else about the config. The config relies on the base (`autoinstall/packages.txt`) but not on installer settings. Which package list something belongs in is in [`config/README.md`](config/README.md#what-belongs-here-vs-in-the-installer).

### To script

#### Auto install

1. move more things to stand alone scripts
2. anything we can break out into ansible
3. actually do it
4. documentation
5. move the builder to an arch base

#### sddm
1. use conf.d instead
2. wayland greeter
3. remember last user & remember last session
4. cursor theme~/.face.icon

#### Misc

1. catpuccin kde
2. headshot
3. kvantum + catpuccin
4. papirus icons
5. catpuccin cursors
6. add konsole/ wezterm
7. firefox
