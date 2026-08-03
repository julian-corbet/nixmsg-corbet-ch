{
  description = "nixmsg — messenger apps (Discord, Telegram, Teams, Threema, Signal, WhatsApp, Element), declared per host";

  # NO INPUTS. Same reasoning as nixdev: this flake is options plus a catalogue, taking `pkgs`
  # from the consumer's own evaluation rather than pinning a nixpkgs, so it never puts a second
  # nixpkgs — or a sibling flake's whole input closure — in anyone's closure.

  outputs = { self }: {
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
  };
}
