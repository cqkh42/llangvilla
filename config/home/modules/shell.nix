# Shell: bash, Arch's default, until the shell/prompt/editor choice is made.
# home-manager now owns ~/.bashrc and ~/.bash_profile (the first switch backs
# up existing ones as *.backup).
{
  programs.bash = {
    enable = true;
    historyControl = [
      "ignoredups"
      "erasedups"
    ];
    shellAliases = {
      ll = "ls -lah";
    };
  };
}
