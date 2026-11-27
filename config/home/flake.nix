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
    plasma-manager = {
      url = "git+https://github.com/nix-community/plasma-manager?ref=trunk&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      plasma-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # The machine's facts (login user, keyboard), shared with Ansible (site.yml).
      host = builtins.fromJSON (builtins.readFile ./host.json);
      mkHome =
        username:
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = { inherit username; };
          modules = [
            plasma-manager.homeModules.plasma-manager
            ./home.nix
          ];
        };
    in
    {
      # The login user from host.json, which Ansible's user_name also comes from.
      homeConfigurations.${host.user} = mkHome host.user;

      # `nix flake check` builds the home configuration (make lint-nix, CI).
      checks.${system}.home = self.homeConfigurations.${host.user}.activationPackage;

      # The home-manager CLI from the same pinned input, so it matches the modules.
      packages.${system}.home-manager = home-manager.packages.${system}.home-manager;

      formatter.${system} = pkgs.nixfmt;
    };
}
