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

  # The tray's items (decision 30). Shown: what's used from the bar, each still only
  # when relevant (media while something plays). Hidden: behind the arrow. Off: the
  # rest of Plasma 6.8's defaults, which do nothing on this desktop. Brightness &
  # Color is off because its light/dark switch has nothing to switch (one Global
  # Theme for both, decision 29); brightness and Night Light are in System Settings.
  # Weather is a panel widget of its own, beside the clock.
  trayItems = {
    shown = [
      "org.kde.plasma.notifications"
      "org.kde.plasma.mediacontroller"
      "org.kde.plasma.volume"
      "org.kde.plasma.networkmanagement"
    ];
    hidden = [
      "org.kde.plasma.clipboard"
      "org.kde.plasma.devicenotifier"
      "org.kde.plasma.bluetooth"
      "org.kde.plasma.keyboardlayout"
      "org.kde.plasma.battery" # wireless mice and keyboards report theirs here
    ];
    off = [
      "org.kde.plasma.brightness"
      "org.kde.plasma.cameraindicator"
      "org.kde.plasma.manage-inputmethod"
      "org.kde.plasma.dwellclicker"
      "org.kde.plasma.keyboardindicator"
      "org.kde.kscreen"
      "org.kde.plasma.weather"
    ];
  };

  # Panel Colorizer's settings (its globalSettings, as JSON): only what differs from
  # its defaults, which it merges in. The bar: Colloid's background made invisible,
  # and the window colour at 45% over a blur in its place. Every icon and label,
  # tray ones too: a soft dark shadow; on hover, a rounded tint of the accent colour.
  # A state that is enabled replaces the normal one, so hover repeats the shadow.
  colorizer =
    let
      shadow.foreground = {
        enabled = true;
        size = 4;
        yOffset = 1;
        color = {
          sourceType = 0; # a custom colour
          custom = "#000000";
          alpha = 0.6;
        };
      };
      normal = {
        enabled = true;
        inherit shadow;
      };
      hovered = normal // {
        backgroundColor = {
          enabled = true;
          sourceType = 1; # a colour from the colour scheme
          systemColor = "highlightColor";
          systemColorSet = "View";
          alpha = 0.25;
        };
        radius = {
          enabled = true;
          corner = {
            topLeft = 6;
            topRight = 6;
            bottomRight = 6;
            bottomLeft = 6;
          };
        };
      };
    in
    {
      nativePanel.background = {
        enabled = true;
        opacity = 0;
        shadow = false;
      };
      panel.normal = {
        enabled = true;
        blurBehind = true; # needs its C++ plugin, which the plasma_widgets role builds
        backgroundColor = {
          enabled = true;
          sourceType = 1;
          systemColor = "backgroundColor";
          systemColorSet = "Window";
          alpha = 0.45;
        };
      };
      widgets = { inherit normal hovered; };
      trayWidgets = { inherit normal hovered; };
    };
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
      # Top bar: launcher on the left; tray, weather and clock on the right. No menus
      # (apps use their ☰ menus, see apps.nix). Translucent and blurred, with a soft
      # shadow under the icons, by Panel Colorizer (decision 30).
      {
        location = "top";
        height = 28;
        widgets = [
          # The Arch logo (from the filesystem package), not Colloid's Apple one:
          # its Plasma style draws start-here-kde as an Apple.
          { kickoff.icon = "/usr/share/pixmaps/archlinux-logo.svg"; }
          "org.kde.plasma.panelspacer"
          {
            # The raw widget form: plasma-manager's systemTray can't set knownItems
            # (its `settings` lands beside `config`, not in it).
            name = "org.kde.plasma.systemtray";
            config.General = {
              extraItems = trayItems.shown ++ trayItems.hidden;
              # Behind the tray's arrow; they still pop out when they need attention
              # (a USB stick plugged in).
              hiddenItems = trayItems.hidden;
              # Every item Plasma 6.8 knows of: an item that is known but not extra
              # stays off, instead of Plasma adding it back.
              knownItems = trayItems.shown ++ trayItems.hidden ++ trayItems.off;
            };
          }
          # Beside the clock, not in the tray: plasma-manager can't configure a tray
          # item (the tray is a containment of its own). The place is in host.json.
          {
            name = "org.kde.plasma.weather";
            config = {
              WeatherStation = {
                provider = "bbcukmet";
                placeInfo = "${host.weather.place}|${host.weather.bbcId}";
                placeDisplayName = host.weather.place;
              };
              Appearance.showTemperatureInCompactMode = true;
            };
          }
          {
            # Bank holidays (England and Wales, configFile below), moon phases and
            # seasons in the calendar, with week numbers.
            digitalClock.calendar = {
              plugins = [
                "holidaysevents"
                "astronomicalevents"
              ];
              showWeekNumbers = true;
            };
          }
          # Styles the panel it sits on; hidden, so it takes no space. The raw form:
          # plasma-manager's panelColorizer module writes an older version's settings.
          {
            name = "luisbocanegra.panel.colorizer";
            config.General = {
              hideWidget = true;
              globalSettings = builtins.toJSON colorizer;
            };
          }
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

    # The Mac genie when minimising, and blur behind translucent windows and panels
    # (on by default; set so the repo says so).
    kwin.effects = {
      minimization.animation = "magiclamp";
      blur.enable = true;
    };

    # Clipboard history: 100 entries, not 20.
    configFile.klipperrc.General.MaxClipItems = 100;

    # The clock calendar's bank holidays: England and Wales (KHolidays' region code).
    configFile.plasma_calendar_holiday_regions.General.selectedRegions = "gb-eaw_en-gb";

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
