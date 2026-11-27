# Menus (docs/design.md, "Menus"): no menu bars; KDE apps use their ☰ button.
# Ctrl+M brings an app's menu bar back if it is ever needed.
{
  programs.plasma.configFile = {
    dolphinrc.MainWindow.MenuBar = "Disabled";
    katerc.MainWindow.MenuBar = "Disabled";
    arkrc.MainWindow.MenuBar = "Disabled";
    konsolerc.KonsoleWindow.ShowMenuBarByDefault = false;
  };
}
