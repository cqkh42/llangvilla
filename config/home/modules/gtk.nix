# GTK apps follow the desktop: the names in ../theme.json (Colloid dark, Colloid
# icons and cursor, Inter). The themes are installed system-wide by Ansible, so no
# packages here.
let
  theme = builtins.fromJSON (builtins.readFile ../theme.json);
in
{
  gtk = {
    enable = true;
    theme.name = theme.gtkTheme;
    iconTheme.name = theme.iconTheme;
    cursorTheme = {
      inherit (theme.cursor) size;
      name = theme.cursor.theme;
    };
    font = {
      name = theme.font.family;
      inherit (theme.font) size;
    };
  };

  # No dconf writes: they need a D-Bus session during the switch, which first boot
  # (before login) doesn't have. On Plasma, GTK 4 apps get the dark preference from
  # KDE's desktop portal instead.
  dconf.enable = false;
}
