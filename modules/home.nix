#
# Home-manager module — session behavior for enabled apps: autostart and workspace-pin intent.
# Deliberately compositor-agnostic (see modules/nixmsg.nix's header) and deliberately does not
# duplicate the system-plane `nixmsg.apps.<name>.enable` list — this module takes its OWN
# `autostart`/`workspacePin` selections (same shape as modules/nixmsg.nix's system-plane
# options), because home-manager and NixOS/system-manager are separate evaluation planes in this
# family with no shared `config.*` to read across (see nix-family-graph.md's own measurement:
# "the home tree has nixremote and no nixnet; the system tree the reverse"). The consumer sets
# both lists to the same values; this module does not invent cross-plane machinery to avoid that
# one line of duplication.
#
{ config, lib, ... }:
let
  cfg = config.nixmsg.home;
  catalogue = import ../lib/catalogue.nix { };
  appNames = lib.attrNames catalogue;

  # Resolve just enough to compute a launch command and an app-id — this module does not need
  # the full channel-resolution machinery modules/nixmsg.nix has (no archPackages/aurPackages
  # here), only "how do I launch it" and "what's its app-id."
  launchCommand = name:
    let entry = catalogue.${name};
    in
    if cfg.channel.${name} or null == "flatpak" || (entry.repo == null && entry.aur == null) then
      "flatpak run ${entry.flatpak}"
    else
      entry.nixpkgs; # the binary name matches the nixpkgs attribute for every catalogue entry today
in
{
  # NO nixdesktop INPUT, deliberately — same reasoning as nixdev's own flake.nix: pinning a
  # sibling flake here would drag its whole input closure (nixpkgs included) into every
  # consumer's lock file for the sake of one option contract. The consumer already composes both
  # nixmsg and nixdesktop, so it wires the one line itself: `nixdesktop.startup =
  # config.nixmsg.home.startupCommands;`. See startupCommands' own description below.
  options.nixmsg.home = {
    autostart = lib.mkOption {
      type = lib.types.listOf (lib.types.enum appNames);
      default = [ ];
      description = "Which apps to launch at session start. Same values as the system-plane nixmsg.apps.<name>.enable list for these apps.";
    };

    channel = lib.mkOption {
      type = lib.types.attrsOf (lib.types.enum [ "repo" "aur" "flatpak" ]);
      default = { };
      description = "Per-app channel, mirroring the system-plane choice — only matters for the launch command (flatpak apps launch via `flatpak run`, everything else by binary name).";
    };

    workspacePin = {
      workspace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Which named workspace to pin `apps` to, if any.";
      };
      apps = lib.mkOption {
        type = lib.types.listOf (lib.types.enum appNames);
        default = [ ];
      };
    };

    startupCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Resolved shell commands for `autostart`, in nixdesktop's plain-string shape — append this
        to `nixdesktop.startup` yourself:

          nixdesktop.startup = config.nixmsg.home.startupCommands;

        Not done automatically by this module — see the file header for why nixdesktop isn't a
        flake input here.
      '';
    };

    pinnedAppIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "app-ids for workspacePin.apps — feed into your compositor's own window-rule/output-assignment syntax (e.g. nixscroll's extraConfig).";
    };
  };

  config = {
    nixmsg.home.startupCommands = map launchCommand cfg.autostart;
    nixmsg.home.pinnedAppIds = map (n: catalogue.${n}.appId) cfg.workspacePin.apps;
  };
}
