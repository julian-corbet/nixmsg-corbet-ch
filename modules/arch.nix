#
# Arch / system-manager backend — publishes `nixmsg.archPackages` / `nixmsg.aurPackages` for the
# host's own pacman reconciler to consume, and feeds flatpak-channel selections to nixflat
# (github:julian-corbet/nixflat-corbet-ch), the shared Flatpak installer this repo no longer
# carries its own copy of. `nixflat.systemManagerModules.default` is composed in alongside this
# file at the flake-output level (see ../flake.nix) rather than imported here — this file has no
# flake-input access of its own, only `nixflat.apps` to hand it.
#
# Installs nothing on the repo/AUR channels itself, for the same reason nixdev's arch.nix
# installs nothing: on Arch, packages arrive through whatever reconciler the host runs
# (nixarch's `nixarch.packages.{pacman,aur}`, for the deployment this was written against).
# Wiring that reconciler in here would couple a general flake to one consumer's module, so the
# lists are published and the consumer connects them:
#
#   nixarch.packages.pacman = config.nixmsg.archPackages;
#   nixarch.packages.aur    = config.nixmsg.aurPackages;
#
{ config, ... }:
{
  imports = [ ./nixmsg.nix ];
  config.nixflat.apps = config.nixmsg.flatpakApps;
}
