# The desktop: Colloid dark laid out like macOS (config design doc, "The look").
# The theme files are installed system-wide by Ansible's theme role; this module
# only selects them. overrideConfig: the repo always wins, and changes made in
# System Settings are reset on the next apply (log out and in after applying).
let
  wallpaper = "/usr/share/wallpapers/Seafront/contents/images/3840x2160.jpg";
in
{
  programs.plasma = {
    enable = true;
    overrideConfig = true;

    workspace = {
      theme = "Colloid-dark";
      colorScheme = "ColloidDark";
      iconTheme = "Colloid-Dark";
      cursor = {
        theme = "Colloid-dark-cursors";
        size = 24;
      };
      # Breeze widgets coloured by the Colloid scheme; Colloid's look-and-feel
      # package would switch widgets to Kvantum, which is not used.
      widgetStyle = "Breeze";
      windowDecorations = {
        library = "org.kde.kwin.aurorae";
        theme = "__aurorae__svg__Colloid-dark";
      };
      inherit wallpaper;
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
        inter = size: {
          family = "Inter";
          pointSize = size;
        };
      in
      {
        general = inter 10;
        menu = inter 10;
        toolbar = inter 10;
        windowTitle = inter 10;
        small = inter 8;
        fixedWidth = {
          family = "JetBrainsMono Nerd Font";
          pointSize = 10;
        };
      };

    panels = [
      # Top bar: launcher on the left; tray and clock on the right. No menus
      # (apps use their ☰ menus, see apps.nix).
      {
        location = "top";
        height = 28;
        widgets = [
          "org.kde.plasma.kickoff"
          "org.kde.plasma.panelspacer"
          "org.kde.plasma.systemtray"
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

    # Spotlight-style search on Meta+Space (Meta alone still opens the launcher).
    krunner.shortcuts.launch = "Meta+Space";

    kscreenlocker.appearance.wallpaper = wallpaper;
  };
}
