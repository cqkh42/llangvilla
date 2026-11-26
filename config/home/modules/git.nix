# Git: behaviour only. Identity (user.name, user.email) is added when the
# dotfiles work starts, so nothing personal sits in this repo by default.
{
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.ff = "only";
      push.autoSetupRemote = true;
    };
  };
}
