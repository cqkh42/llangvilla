# Settings every user gets; each concern lives in its own module under modules/.
{ username, ... }:
{
  imports = [
    ./modules/plasma.nix
    ./modules/gtk.nix
    ./modules/apps.nix
    ./modules/git.nix
    ./modules/shell.nix
    ./modules/notices.nix
  ];

  home.username = username;
  home.homeDirectory = "/home/${username}";

  # The home-manager release this config was first written against. Leave it
  # unchanged on upgrades: it guards against changed defaults, not a version pin.
  home.stateVersion = "26.05";

  # Arch, not NixOS: session variables and XDG_DATA_DIRS for Nix-installed things.
  targets.genericLinux.enable = true;

  # GUI apps, themes and anything that plugs into Plasma come from pacman
  # (Ansible); Nix supplies dotfiles, settings and command-line tools.
  programs.home-manager.enable = true;

  # Applied by Ansible, not read interactively: keep the run's output short.
  news.display = "silent";
}
