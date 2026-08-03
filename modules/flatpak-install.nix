#
# Declarative Flatpak app installation — the one channel neither a NixOS nor an Arch package
# manager can express on its own. Shared between modules/nixos.nix and modules/arch.nix (Flatpak
# itself is cross-distro; nothing about installing an app by Flatpak ID is platform-specific) so
# there is exactly one place implementing this rather than two copies that could drift.
#
# REMOTE-AWARE, NOT FLATHUB-ONLY. An earlier version of this file hardcoded Flathub as the only
# remote it would ever `remote-add` or install from — which silently could not install
# lib/catalogue.nix's own `threema` entry: `ch.threema.threema-desktop` does not exist on
# Flathub at all (Flathub's own Threema listing, `ch.threema.threema-web-desktop`, is a different
# app), only on Threema GmbH's own repo. `flatpak install --system flathub
# ch.threema.threema-desktop` fails outright — not "installs the wrong build", fails to resolve
# the id. `nixmsg.flatpakApps` (modules/nixmsg.nix) now carries each app's actual remote
# alongside its id, sourced from the catalogue's own `flatpakRemote` field, and this file adds
# every DISTINCT remote the declared set actually needs and installs each app from ITS remote —
# never unconditionally adding or installing from Flathub when nothing declared here needs it.
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
  apps = cfg.flatpakApps;

  # Every DISTINCT remote the declared apps actually need, deduplicated by name — built as an
  # attrset (name -> url) rather than filtering a list, so two apps naming the same remote never
  # produce two `remote-add` lines for it. `flatpak remote-add --if-not-exists` is itself
  # idempotent against a remote that's already there from a PREVIOUS activation; this dedup is
  # about not repeating the line pointlessly within a single generated script.
  remotes = lib.mapAttrsToList (name: url: { inherit name url; })
    (lib.foldl' (acc: a: acc // { ${a.remoteName} = a.remoteUrl; }) { } apps);
in
{
  config = lib.mkIf (apps != [ ]) {
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
        ${lib.concatMapStringsSep "\n" (r: ''
          flatpak remote-add --system --if-not-exists ${r.name} ${r.url}
        '') remotes}
        ${lib.concatMapStringsSep "\n" (a: ''
          if ! flatpak info --system ${a.id} >/dev/null 2>&1; then
            flatpak install --system --noninteractive ${a.remoteName} ${a.id}
          fi
        '') apps}
      '';
    };
  };
}
