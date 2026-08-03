# checks/default.nix
#
# EVAL-TIME checks for modules/nixmsg.nix's `flatpakApps` output and modules/flatpak-install.nix's
# rendering of it -- the same `lib.evalModules` + stubbed option-surface technique nixarch's own
# checks/default.nix uses (see that file's own header): no real NixOS/system-manager evaluation,
# because what is under test is only what these two files RENDER (an option value, a systemd unit
# script), never whether `flatpak` on a real host actually converges.
#
# THE BUG THIS SUITE EXISTS TO CATCH, PERMANENTLY. An earlier version of flatpak-install.nix
# hardcoded Flathub as the only remote it would ever `remote-add` or install from. Threema's
# catalogue entry (../lib/catalogue.nix) names `ch.threema.threema-desktop`, which does not exist
# on Flathub at all (confirmed live, 2026-08-03 -- see that file's own header); the real desktop
# client is only ever distributed from Threema GmbH's own repo. Every fixture below that involves
# threema proves BOTH directions: the right remote gets `remote-add`'d and installed from, AND
# Flathub does NOT get added when nothing declared here needs it -- a suite that only checked the
# first half would pass just as happily on a version that added every known remote unconditionally,
# which is not the property this fix is actually for.
{ pkgs }:
let
  lib = pkgs.lib;

  # Stub of the surface only NixOS/system-manager itself provides -- `systemd.services` opaque the
  # same way nixarch's own checks/default.nix stubs it (a single definition per key is all either
  # module here ever contributes), plus `assertions`, which modules/nixmsg.nix writes to
  # unconditionally (the autostart/workspacePin typo guard) even though this suite's fixtures never
  # trip it.
  systemSurfaceStub = { lib, ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
    };
  };

  evalMod = extraConfig: (lib.evalModules {
    modules = [
      systemSurfaceStub
      { _module.args.pkgs = pkgs; }
      ../modules/nixmsg.nix
      ../modules/flatpak-install.nix
      extraConfig
    ];
  }).config;

  check = name: ok: detail: { inherit name ok detail; };

  scriptOf = cfg: cfg.systemd.services.nixmsg-flatpak-install.script or "";

  # ── Fixture 1: ONLY a non-Flathub app declared (threema, pinned to its flatpak channel -- its
  # auto-resolution default is "aur", so channel has to be named explicitly to exercise this path).
  cfgThreemaOnly = evalMod {
    nixmsg.apps.threema = { enable = true; channel = "flatpak"; };
  };

  # ── Fixture 2: ONLY a genuine Flathub app declared -- the unaffected case this fix must not
  # regress.
  cfgFlathubOnly = evalMod {
    nixmsg.apps.discord = { enable = true; channel = "flatpak"; };
  };

  # ── Fixture 3: BOTH together -- the case that actually motivated this fix (a real host wanting
  # Threema's linked session alongside an ordinary Flathub app).
  cfgMixed = evalMod {
    nixmsg.apps.threema = { enable = true; channel = "flatpak"; };
    nixmsg.apps.discord = { enable = true; channel = "flatpak"; };
  };

  # ── Fixture 4: no flatpak-channel app declared at all -- the oneshot must stay a clean no-op,
  # same contract `lib.mkIf (apps != [ ])` already promised for the old `ids` list.
  cfgNoFlatpak = evalMod {
    nixmsg.apps.discord = { enable = true; channel = "repo"; };
  };

  results = [
    # ── nixmsg.flatpakApps carries id + remote TOGETHER, not just a bare id list ──
    (check "flatpakApps/threema-carries-its-own-remote"
      (cfgThreemaOnly.nixmsg.flatpakApps == [
        { id = "ch.threema.threema-desktop"; remoteName = "threema-desktop"; remoteUrl = "https://releases.threema.ch/flatpak/threema-desktop/"; }
      ])
      "got: ${builtins.toJSON cfgThreemaOnly.nixmsg.flatpakApps}")

    (check "flatpakApps/discord-defaults-to-flathub"
      (cfgFlathubOnly.nixmsg.flatpakApps == [
        { id = "com.discordapp.Discord"; remoteName = "flathub"; remoteUrl = "https://flathub.org/repo/flathub.flatpakrepo"; }
      ])
      "got: ${builtins.toJSON cfgFlathubOnly.nixmsg.flatpakApps}")

    # ── threema-only: adds threema's remote, and ONLY threema's remote ──
    (check "script/threema-only-adds-threema-remote"
      (lib.hasInfix "flatpak remote-add --system --if-not-exists threema-desktop https://releases.threema.ch/flatpak/threema-desktop/" (scriptOf cfgThreemaOnly))
      "script: ${scriptOf cfgThreemaOnly}")

    (check "script/threema-only-does-not-add-flathub"
      (!(lib.hasInfix "remote-add --system --if-not-exists flathub" (scriptOf cfgThreemaOnly)))
      "script: ${scriptOf cfgThreemaOnly}")

    (check "script/threema-only-installs-from-threema-remote-not-flathub"
      (lib.hasInfix "flatpak install --system --noninteractive threema-desktop ch.threema.threema-desktop" (scriptOf cfgThreemaOnly)
        && !(lib.hasInfix "flatpak install --system --noninteractive flathub ch.threema.threema-desktop" (scriptOf cfgThreemaOnly)))
      "script: ${scriptOf cfgThreemaOnly}")

    # ── the flip side: a genuine Flathub app is unaffected by the fix ──
    (check "script/flathub-only-adds-flathub-remote"
      (lib.hasInfix "flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" (scriptOf cfgFlathubOnly))
      "script: ${scriptOf cfgFlathubOnly}")

    (check "script/flathub-only-does-not-add-threema-remote"
      (!(lib.hasInfix "threema-desktop" (scriptOf cfgFlathubOnly)))
      "script: ${scriptOf cfgFlathubOnly}")

    (check "script/flathub-only-installs-discord-from-flathub"
      (lib.hasInfix "flatpak install --system --noninteractive flathub com.discordapp.Discord" (scriptOf cfgFlathubOnly))
      "script: ${scriptOf cfgFlathubOnly}")

    # ── mixed: BOTH remotes present, each app installs from ITS OWN remote, never crossed ──
    (check "script/mixed-adds-both-remotes"
      (lib.hasInfix "remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" (scriptOf cfgMixed)
        && lib.hasInfix "remote-add --system --if-not-exists threema-desktop https://releases.threema.ch/flatpak/threema-desktop/" (scriptOf cfgMixed))
      "script: ${scriptOf cfgMixed}")

    (check "script/mixed-threema-installs-from-threema-remote"
      (lib.hasInfix "flatpak install --system --noninteractive threema-desktop ch.threema.threema-desktop" (scriptOf cfgMixed))
      "script: ${scriptOf cfgMixed}")

    (check "script/mixed-discord-installs-from-flathub-not-threema-remote"
      (lib.hasInfix "flatpak install --system --noninteractive flathub com.discordapp.Discord" (scriptOf cfgMixed)
        && !(lib.hasInfix "flatpak install --system --noninteractive threema-desktop com.discordapp.Discord" (scriptOf cfgMixed)))
      "script: ${scriptOf cfgMixed}")

    # ── no flatpak-channel app declared: the oneshot renders no unit at all ──
    (check "no-flatpak-app/unit-absent"
      (!(cfgNoFlatpak.systemd.services ? "nixmsg-flatpak-install"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfgNoFlatpak.systemd.services)}")
  ];

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-checks =
    if failed != [ ]
    then throw ''
      nixmsg eval-checks FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
      ${report}
    ''
    else
    # Depending on `passedCount` forces `results` (and every `check` assertion above), so the
    # checks genuinely run under `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixmsg-eval-checks"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixmsg eval checks passed"
          touch $out
        '';
in
{
  inherit eval-checks;
}
