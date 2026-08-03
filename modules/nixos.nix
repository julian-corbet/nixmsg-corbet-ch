#
# NixOS backend — resolves nixmsg's selections into environment.systemPackages, plus the shared
# Flatpak-channel installer. Same asymmetry nixdev already documents for itself: on NixOS the
# package set is part of the same evaluation, so there is no reconciler to hand a list to, unlike
# the Arch side which can only publish names for a host's own pacman reconciler to consume.
#
{ config, lib, pkgs, ... }:
let
  cfg = config.nixmsg;
  resolves = attr: lib.hasAttrByPath (lib.splitString "." attr) pkgs;
  missingAttrs = lib.filter (a: !(resolves a)) cfg.nixosPackages;
in
{
  imports = [ ./nixmsg.nix ./flatpak-install.nix ];

  config = {
    environment.systemPackages =
      map (a: lib.getAttrFromPath (lib.splitString "." a) pkgs)
        (lib.filter resolves cfg.nixosPackages);

    warnings =
      lib.optional (cfg.unavailableOnNixos != [ ]) ''
        nixmsg: ${toString (builtins.length cfg.unavailableOnNixos)} selected app(s) have no nixpkgs equivalent and will NOT be installed on this host: ${lib.concatStringsSep ", " cfg.unavailableOnNixos}.
      ''
      ++ lib.optional (missingAttrs != [ ]) ''
        nixmsg: ${toString (builtins.length missingAttrs)} app(s) name a nixpkgs attribute that does not exist in this nixpkgs: ${lib.concatStringsSep ", " missingAttrs}. Fix lib/catalogue.nix rather than pinning around it.
      '';
  };
}
