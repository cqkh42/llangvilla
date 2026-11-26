# GTK apps follow the desktop: Colloid dark, Colloid icons and cursor, Inter.
# The themes are installed system-wide by Ansible, so no packages here.
{
  gtk = {
    enable = true;
    theme.name = "Colloid-Dark";
    iconTheme.name = "Colloid-Dark";
    cursorTheme = {
      name = "Colloid-dark-cursors";
      size = 24;
    };
    font = {
      name = "Inter";
      size = 10;
    };
  };

  # No dconf writes: they need a D-Bus session during the switch, which first boot
  # (before login) doesn't have. On Plasma, GTK 4 apps get the dark preference from
  # KDE's desktop portal instead.
  dconf.enable = false;
}
