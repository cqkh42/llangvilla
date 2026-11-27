# The config's notices on the desktop. The checks (firmware updates, disk health, an
# overdue apply; the installer's first-boot failure) write them to the login message,
# /etc/motd.d/llangvilla-*, which only SSH and the text console show. At each desktop
# login, an autostart entry shows each one as a notification that stays until
# dismissed. A plain file, so the switch needs no desktop session (first boot).
{ pkgs, ... }:
let
  show = pkgs.writeShellScript "llangvilla-notices" ''
    for f in /etc/motd.d/llangvilla-*; do
      [ -s "$f" ] || continue
      ${pkgs.libnotify}/bin/notify-send --app-name=llangvilla --urgency=critical \
        --icon=dialog-warning "llangvilla" "$(cat "$f")"
    done
  '';
in
{
  xdg.configFile."autostart/llangvilla-notices.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=llangvilla notices
    Comment=Show the config's notices (firmware, disks, upgrades) after login
    Exec=${show}
    NoDisplay=true
  '';
}
