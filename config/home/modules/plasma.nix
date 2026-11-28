# The desktop: Colloid dark laid out like macOS (docs/design.md, "The look").
# The theme files are installed system-wide by Ansible's theme role; this module
# only selects them, by the names in ../theme.json (shared with Ansible's
# login_screen role). overrideConfig: the repo always wins, and changes made in
# System Settings are reset on the next apply (log out and in after applying).
let
  theme = builtins.fromJSON (builtins.readFile ../theme.json);
  host = builtins.fromJSON (builtins.readFile ../host.json);
  # Installed by Ansible's login_screen role as a Plasma wallpaper package.
  wallpaper = "/usr/share/wallpapers/${theme.wallpaper.name}/contents/images/${theme.wallpaper.size}.jpg";
in
{
  programs.plasma = {
    enable = true;
    overrideConfig = true;

    workspace = {
      theme = theme.plasmaTheme;
      inherit (theme) colorScheme iconTheme;
      cursor = { inherit (theme.cursor) theme size; };
      # Breeze widgets coloured by the Colloid scheme; Colloid's own Global Theme
      # would switch widgets to Kvantum, which is not used.
      widgetStyle = "Breeze";
      windowDecorations = {
        library = "org.kde.kwin.aurorae";
        theme = theme.windowDecoration;
      };
      inherit wallpaper;
      # No splash between login and the desktop (writes ksplashrc: Engine=none).
      splashScreen.theme = "None";
    };

    # Close, minimise and maximise on the left, like macOS.
    kwin.titlebarButtons = {
      left = [
        "close"
        "minimize"
        "maximize"
      ];
      right = [ ];
    };

    fonts =
      let
        ui = size: {
          inherit (theme.font) family;
          pointSize = size;
        };
      in
      {
        general = ui theme.font.size;
        menu = ui theme.font.size;
        toolbar = ui theme.font.size;
        windowTitle = ui theme.font.size;
        small = ui theme.font.smallSize;
        fixedWidth = {
          inherit (theme.monoFont) family;
          pointSize = theme.monoFont.size;
        };
      };

    panels = [
      # Top bar: launcher on the left; tray and clock on the right. No menus
      # (apps use their ☰ menus, see apps.nix).
      {
        location = "top";
        height = 28;
        widgets = [
          # The Arch logo (from the filesystem package), not Colloid's Apple one:
          # its Plasma style draws start-here-kde as an Apple.
          { kickoff.icon = "/usr/share/pixmaps/archlinux-logo.svg"; }
          "org.kde.plasma.panelspacer"
          {
            # Plasma 6.8's default tray items, minus Brightness & Color: its light/dark
            # switch has nothing to switch (one Global Theme for both) and can't be
            # hidden on its own. Brightness and Night Light stay in System Settings.
            # Listing it as known but not extra keeps Plasma from adding it back.
            # The raw widget form: plasma-manager's systemTray can't set knownItems
            # (its `settings` lands beside `config`, not in it).
            name = "org.kde.plasma.systemtray";
            config.General =
              let
                items = [
                  "org.kde.plasma.cameraindicator"
                  "org.kde.plasma.clipboard"
                  "org.kde.plasma.devicenotifier"
                  "org.kde.plasma.manage-inputmethod"
                  "org.kde.plasma.mediacontroller"
                  "org.kde.plasma.notifications"
                  "org.kde.plasma.battery"
                  "org.kde.plasma.dwellclicker"
                  "org.kde.plasma.keyboardlayout"
                  "org.kde.kscreen"
                  "org.kde.plasma.networkmanagement"
                  "org.kde.plasma.volume"
                  "org.kde.plasma.bluetooth"
                  "org.kde.plasma.keyboardindicator"
                  "org.kde.plasma.weather"
                ];
              in
              {
                extraItems = items;
                knownItems = items ++ [ "org.kde.plasma.brightness" ];
              };
          }
          "org.kde.plasma.digitalclock"
        ];
      }
      # Dock: floating, centred, sized to its icons, moves out of the way of windows.
      {
        location = "bottom";
        alignment = "center";
        lengthMode = "fit";
        height = 56;
        floating = true;
        hiding = "dodgewindows";
        widgets = [
          {
            iconTasks.launchers = [
              "applications:org.kde.dolphin.desktop"
              "applications:firefox.desktop"
              "applications:org.kde.konsole.desktop"
              "applications:org.kde.kate.desktop"
              "applications:systemsettings.desktop"
            ];
          }
        ];
      }
    ];

    # The keyboard layout (host.json) in the session itself, not only from
    # /etc/X11/xorg.conf.d (the installer's X11_KEYMAP), which Wayland may not read.
    input.keyboard.layouts = [ { layout = host.keyboardLayout; } ];

    # Spotlight-style search on Meta+Space (Meta alone still opens the launcher).
    krunner.shortcuts.launch = "Meta+Space";

    kscreenlocker.appearance.wallpaper = wallpaper;

    # The Global Theme (installed by Ansible's theme role, the parts above with
    # Breeze widgets): the current one, and the one Plasma's light/dark switch
    # (tray, System Settings) uses for both, so switching never leaves Colloid.
    # Set as keys, not workspace.lookAndFeel: that runs plasma-apply-lookandfeel at
    # every login, and the parts are already applied one by one above.
    configFile.kdeglobals.KDE = {
      LookAndFeelPackage = theme.lookAndFeel;
      DefaultLightLookAndFeel = theme.lookAndFeel;
      DefaultDarkLookAndFeel = theme.lookAndFeel;
    };
  };
}
