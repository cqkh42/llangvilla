{
  # The user layer (config/README.md, "User layer"): home-manager owns $HOME.
  # Ansible's home_manager role applies it with:
  #   nix run path:config/home#home-manager -- switch -b backup --flake path:config/home#<user>
  # Inputs are fetched with git (shallow) and pinned by flake.lock; update them
  # deliberately with `nix flake update`, test in the VM, then commit the lock.
  description = "llangvilla user layer: home-manager on Arch";

  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable&shallow=1";
    home-manager = {
      url = "git+https://github.com/nix-community/home-manager?ref=master&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkHome =
        username:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit username; };
          modules = [ ./home.nix ];
        };
    in
    {
      # One entry per login user; the key must match Ansible's user_name.
      homeConfigurations.jack = mkHome "jack";

      # The home-manager CLI from the same pinned input, so it matches the modules.
      packages.${system}.home-manager = home-manager.packages.${system}.home-manager;

      formatter.${system} = pkgs.nixfmt;
    };
}
