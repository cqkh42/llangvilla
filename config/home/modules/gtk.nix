# GTK apps follow the desktop: the names in ../theme.json (Colloid dark, Papirus
# icons, Colloid cursor, Inter). The themes are installed system-wide by Ansible, so no
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

  # Plasma's GTK sync (kde-gtk-config) may rewrite these files. Overwrite them on
  # every apply, without a backup, so the repo wins and a second clash can't fail
  # the switch (the same rule as overrideConfig in plasma.nix).
  gtk.gtk2.force = true;
  xdg.configFile."gtk-3.0/settings.ini".force = true;
  xdg.configFile."gtk-4.0/settings.ini".force = true;

  # No dconf writes: they need a D-Bus session during the switch, which first boot
  # (before login) doesn't have. On Plasma, GTK 4 apps get the dark preference from
  # KDE's desktop portal instead.
  dconf.enable = false;
}
