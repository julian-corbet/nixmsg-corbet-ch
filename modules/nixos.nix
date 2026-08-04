#
# NixOS backend — resolves nixmsg's selections into environment.systemPackages. Same asymmetry
# nixdev already documents for itself: on NixOS the package set is part of the same evaluation, so
# there is no reconciler to hand a list to, unlike the Arch side which can only publish names for a
# host's own pacman reconciler to consume.
#
# THE FLATPAK CHANNEL IS NOT INSTALLED HERE, and there is no Arch counterpart to this file at all
# any more. This module used to also import a Flatpak installer; that installer is nixflat's now
# (github:julian-corbet/nixflat-corbet-ch), because it was never messenger-specific -- nixoffice
# grew an identical need the moment it declared its first Flatpak-only app, and a second copy of a
# systemd oneshot is a second thing to fix when the next remote-handling bug turns up. nixmsg
# publishes `nixmsg.flatpakApps` and stops there; a consumer concatenates it with any other
# catalogue's and hands the result to one installer:
#
#   nixflat.apps = config.nixmsg.flatpakApps ++ config.nixoffice.flatpakApps;
#
# That also removed this repo's Arch backend outright. With the installer gone, modules/arch.nix
# imported modules/nixmsg.nix and did nothing else -- a file whose only content was an indirection.
# `systemManagerModules.default` points straight at modules/nixmsg.nix now (see flake.nix).
#
{ config, lib, pkgs, ... }:
let
  cfg = config.nixmsg;
  resolves = attr: lib.hasAttrByPath (lib.splitString "." attr) pkgs;
  missingAttrs = lib.filter (a: !(resolves a)) cfg.nixosPackages;
in
{
  imports = [ ./nixmsg.nix ];

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
