#
# Declarative Flatpak app installation — the one channel neither a NixOS nor an Arch package
# manager can express on its own. Shared between modules/nixos.nix and modules/arch.nix (Flatpak
# itself is cross-distro; nothing about installing an app by Flathub ID is platform-specific) so
# there is exactly one place implementing this rather than two copies that could drift.
#
# SYSTEM ("--system") SCOPE, DELIBERATELY, NOT --user. A system-level module (this file is
# imported from a NixOS/system-manager tree, never home-manager) has no user session to run a
# `--user` install as without extra per-host wiring (a target username, that user's
# XDG_RUNTIME_DIR/D-Bus session). `--system` needs none of that — it runs as the oneshot's own
# root user and the app becomes available to every user on the host, which is the correct shape
# for a single-operator workstation (every host this targets has exactly one real user).
#
# IDEMPOTENT AND IMPERATIVE, ON PURPOSE. `flatpak install` is not a Nix-store artifact — the app
# itself lives in Flatpak's own runtime-managed tree (/var/lib/flatpak), outside Nix's reach
# entirely, same as pacman/AUR packages are outside it. This oneshot's job is only to converge
# "which app IDs are installed" toward the declared set on every activation; it does not manage
# updates (Flatpak's own `flatpak update`/auto-update handles that, same division of
# responsibility as pacman/AUR packages already have in this family) and does not remove an app
# that is later dropped from the declared list — same "declaring is not the same as pruning"
# posture nixarch's own `pruneUndeclared` takes, deliberately not solved here either.
#
{ config, lib, pkgs, ... }:
let
  cfg = config.nixmsg;
  ids = cfg.flatpakIds;
in
{
  config = lib.mkIf (ids != [ ]) {
    systemd.services.nixmsg-flatpak-install = {
      description = "nixmsg: converge declared Flatpak messenger apps";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.flatpak ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        ${lib.concatMapStringsSep "\n" (id: ''
          if ! flatpak info --system ${id} >/dev/null 2>&1; then
            flatpak install --system --noninteractive flathub ${id}
          fi
        '') ids}
      '';
    };
  };
}
