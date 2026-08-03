#
# Arch / system-manager backend — publishes `nixmsg.archPackages` / `nixmsg.aurPackages` for the
# host's own pacman reconciler to consume, and wires the shared Flatpak-channel installer (which
# needs no Arch-specific handling — Flatpak is cross-distro).
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
{ ... }:
{
  imports = [ ./nixmsg.nix ./flatpak-install.nix ];
}
