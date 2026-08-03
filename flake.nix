{
  description = "nixmsg — messenger apps (Discord, Telegram, Teams, Threema, Signal, WhatsApp, Element), declared per host";

  # NO INPUTS FOR CONSUMERS. Same reasoning as nixdev: this flake is options plus a catalogue,
  # taking `pkgs` from the consumer's own evaluation rather than pinning a nixpkgs, so a real host
  # never puts a second nixpkgs — or a sibling flake's whole input closure — in its closure.
  inputs = {
    # checks-only, same convention nixdarwin/nixcpu already use in this family: the modules
    # themselves take `pkgs` from whatever evaluation composes them (never from this input
    # directly), so a consumer who doesn't `follow` this flake's `checks` output pays no second
    # nixpkgs fetch for it.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # Platform-neutral policy: the options, catalogue resolution, and computed package lists.
      # Import this directly if you want the lists and intend to wire them yourself.
      nixosModules.nixmsg = ./modules/nixmsg.nix;
      systemManagerModules.nixmsg = ./modules/nixmsg.nix;

      # NixOS backend — installs via environment.systemPackages + the Flatpak-channel oneshot.
      nixosModules.default = ./modules/nixos.nix;
      nixosModules.install = ./modules/nixos.nix;

      # Arch / system-manager backend — publishes archPackages/aurPackages for the host's own
      # pacman reconciler, plus the same Flatpak-channel oneshot (platform-agnostic).
      systemManagerModules.default = ./modules/arch.nix;

      # Home-manager — autostart + workspace-pin intent, compositor-agnostic.
      homeManagerModules.default = ./modules/home.nix;
      homeManagerModules.home = ./modules/home.nix;

      # The catalogue, exposed so a consumer can inspect or validate it without re-reading the file.
      lib.catalogue = import ./lib/catalogue.nix { };

      # EVAL-TIME checks only — see checks/default.nix's own header for what's under test and why
      # it exists (modules/flatpak-install.nix's remote-aware rendering, and the
      # modules/nixmsg.nix `flatpakApps` output that feeds it).
      checks = forAllSystems (system: import ./checks { pkgs = pkgsFor system; });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
