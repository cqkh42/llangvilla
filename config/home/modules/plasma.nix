# The desktop: Colloid dark laid out like macOS (config design doc, "The look").
# The theme files are installed system-wide by Ansible's theme role; this module
# only selects them, by the names in ../theme.json (shared with Ansible's
# login_screen role). overrideConfig: the repo always wins, and changes made in
# System Settings are reset on the next apply (log out and in after applying).
let
  theme = builtins.fromJSON (builtins.readFile ../theme.json);
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
      # Breeze widgets coloured by the Colloid scheme; Colloid's look-and-feel
      # package would switch widgets to Kvantum, which is not used.
      widgetStyle = "Breeze";
      windowDecorations = {
        library = "org.kde.kwin.aurorae";
        theme = theme.windowDecoration;
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

    # UK keyboard in the session itself, not only from /etc/X11/xorg.conf.d (the
    # installer's X11_KEYMAP), which a Wayland session may not read.
    input.keyboard.layouts = [ { layout = "gb"; } ];

    # Spotlight-style search on Meta+Space (Meta alone still opens the launcher).
    krunner.shortcuts.launch = "Meta+Space";

    kscreenlocker.appearance.wallpaper = wallpaper;
  };
}
