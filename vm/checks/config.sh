#!/usr/bin/env bash
# What the config produced (vm/test-vm.sh config), run ON THE VM as the test user:
# vm/test-vm.sh pipes this file to `bash -s` over SSH, with the expected values (from
# config/home/theme.json and host.json) as environment variables. Prints one line per
# check; exits 1 if any failed. No `set -e`: every check runs.
# The helper functions below are called through `check NAME FUNCTION`, which
# ShellCheck can't follow.
# shellcheck disable=SC2329
# No pipefail: checks like `cmd | grep -q` must not fail when grep exits early.
set -u
: "${PW:?}" "${KEYBOARD:?}" "${SCHEME:?}" "${ICONS:?}" "${GTK:?}" "${PLASMA:?}" "${DECO:?}"
: "${CURSOR:?}" "${CURSOR_SIZE:?}" "${FONT:?}" "${FONT_SIZE:?}" "${WP_NAME:?}" "${WP_SIZE:?}"
USER=${USER:-$(id -un)}   # set by SSH logins, but not guaranteed
fails=0
pass() { printf '  \e[32m✔\e[0m %s\n' "$1"; }
fail() { printf '  \e[31m✖\e[0m %s: %s\n' "$1" "$2"; fails=1; }
check() { local name=$1; shift; if out=$("$@" 2>&1 </dev/null); then pass "$name"; else fail "$name" "${out:-not as expected}"; fi; }
s() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
img="/usr/share/wallpapers/$WP_NAME/contents/images/$WP_SIZE.jpg"
greeter=$(getent passwd plasmalogin | cut -d: -f6)

# login_screen
check "login screen: wallpaper drop-in"  s grep -qx "Image=file://$img" /etc/plasmalogin.conf.d/10-llangvilla.conf
# Once the login screen has started, Plasma replaces ColorScheme with the SHA-1 of the
# scheme file it applied (login_screen role): either means the scheme is set.
greeter_scheme() {
  local h
  h=$(sha1sum "/usr/share/color-schemes/$SCHEME.colors" | cut -d' ' -f1)
  s grep -qx -e "ColorScheme=$SCHEME" -e "ColorSchemeHash=$h" "$greeter/.config/kdeglobals"
}
check "login screen: colour scheme"      greeter_scheme
check "login screen: icons"              s grep -qx "Theme=$ICONS" "$greeter/.config/kdeglobals"
check "login screen: font"               s grep -q "^font=$FONT,$FONT_SIZE," "$greeter/.config/kdeglobals"
check "login screen: cursor"             s grep -qx "cursorTheme=$CURSOR" "$greeter/.config/kcminputrc"
check "login screen: cursor size"        s grep -qx "cursorSize=$CURSOR_SIZE" "$greeter/.config/kcminputrc"
check "wallpaper package $WP_NAME"       test -f "$img" -a -f "/usr/share/wallpapers/$WP_NAME/metadata.json"
# theme
check "window decoration $DECO"          test -d "/usr/share/aurorae/themes/$DECO"
check "colour scheme $SCHEME"            test -f "/usr/share/color-schemes/$SCHEME.colors"
check "Plasma style $PLASMA"             test -d "/usr/share/plasma/desktoptheme/$PLASMA"
check "icons $ICONS"                     test -f "/usr/share/icons/$ICONS/index.theme"
check "cursors $CURSOR"                  test -d "/usr/share/icons/$CURSOR/cursors"
check "GTK theme $GTK"                   test -d "/usr/share/themes/$GTK/gtk-3.0"
# user_avatar
check "avatar icon"                      test -f "/var/lib/AccountsService/icons/$USER"
check "avatar entry"                     s grep -qx "Icon=/var/lib/AccountsService/icons/$USER" "/var/lib/AccountsService/users/$USER"
# boot
# shellcheck disable=SC2016  # $f expands in the inner bash
check "zswap off in every boot entry"    s bash -c 'for f in /boot/loader/entries/*.conf; do grep -q "^options.*zswap\.enabled=0" "$f" || { echo "$f"; exit 1; }; done'
# nix
check "Nix daemon socket active"         systemctl is-active nix-daemon.socket
check "Nix flakes enabled"               grep -qx 'experimental-features = nix-command flakes' /etc/nix/nix.conf
# home_manager (written during the switch; colours, icons, panels and wallpaper come at login)
check "qdbus on the PATH (plasma-manager)" command -v qdbus
check "home-manager generation"          test -L "$HOME/.local/state/nix/profiles/home-manager"
check "keyboard layout $KEYBOARD (kxkbrc)" grep -qx "LayoutList=$KEYBOARD" "$HOME/.config/kxkbrc"
check "window buttons on the left"       grep -qx 'ButtonsOnLeft=XIA' "$HOME/.config/kwinrc"
check "window decoration selected"       grep -qx "theme=__aurorae__svg__$DECO" "$HOME/.config/kwinrc"
check "interface font $FONT $FONT_SIZE"  grep -q "^font=$FONT,$FONT_SIZE," "$HOME/.config/kdeglobals"
for app in dolphinrc katerc arkrc; do
  check "menu bar off ($app)"            grep -qx 'MenuBar=Disabled' "$HOME/.config/$app"
done
check "menu bar off (konsolerc)"         grep -qix 'ShowMenuBarByDefault=false' "$HOME/.config/konsolerc"
check "no login splash (ksplashrc)"     grep -qx 'Engine=none' "$HOME/.config/ksplashrc"
check "GTK 3 theme $GTK"                 grep -qx "gtk-theme-name=$GTK" "$HOME/.config/gtk-3.0/settings.ini"
check "GTK 4 settings"                   test -e "$HOME/.config/gtk-4.0/settings.ini"
check "GTK 2 settings"                   test -e "$HOME/.gtkrc-2.0"
check "notices at desktop login"         grep -q '^Exec=/nix/store/.*llangvilla-notices' "$HOME/.config/autostart/llangvilla-notices.desktop"
check "no llangvilla notices pending"    bash -c '! ls /etc/motd.d/llangvilla-* 2>/dev/null'
exit $fails
