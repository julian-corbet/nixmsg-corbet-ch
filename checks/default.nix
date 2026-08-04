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
#
# A SECOND BUG THIS SUITE EXISTS TO CATCH: modules/home.nix and modules/nixmsg.nix both used to
# resolve an autostart LAUNCH COMMAND from the catalogue's `repo`/`aur` PACKAGE name, silently
# assuming a package name is also its binary's name on $PATH. Proven false live, 2026-08-03:
# `pacman -Ql telegram-desktop` installs `/usr/bin/Telegram` (capital T), not
# `/usr/bin/telegram-desktop` -- the old command built cleanly and failed at runtime with no
# signal at eval time. The fixtures below pin telegram specifically (its catalogue entry's
# `repo`/`binary` values are deliberately DIFFERENT strings) so a regression back to
# `packageName`/`entry.repo` fails this suite immediately instead of waiting for another live
# autostart to silently do nothing.
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

  # Stub of the home-manager-only surface modules/home.nix writes to (`xdg.dataFile`/
  # `xdg.configFile`) -- same opaque-attrs technique as systemSurfaceStub above, needed because
  # home.nix is a home-manager module (a different option tree entirely from nixmsg.nix/
  # flatpak-install.nix, which is why it gets its own eval helper rather than reusing evalMod).
  homeSurfaceStub = { lib, ... }: {
    options = {
      xdg.dataFile = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      xdg.configFile = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      # `relocate` renders through home-manager's own mkOutOfStoreSymlink, which lives on
      # `config.lib.file` rather than in nixpkgs' lib. Stubbing it to the identity keeps the
      # rendered target readable as a plain path in the assertions below, so a check can state
      # the exact link target instead of matching a store path it cannot predict.
      lib = lib.mkOption { type = lib.types.attrs; default = { file.mkOutOfStoreSymlink = p: p; }; };
    };
  };

  evalHomeMod = extraConfig: (lib.evalModules {
    modules = [
      homeSurfaceStub
      ../modules/home.nix
      extraConfig
    ];
  }).config;

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

  # ── Fixture 5: telegram autostart, system-plane (modules/nixmsg.nix) -- telegram's real
  # catalogue entry deliberately has repo="telegram-desktop" and binary="Telegram", two DIFFERENT
  # strings, so this fails loudly if startupCommands regresses to packageName/entry.repo.
  cfgAutostartTelegramSystem = evalMod {
    nixmsg.apps.telegram.enable = true;
    nixmsg.autostart = [ "telegram" ];
  };

  # ── Fixture 6: telegram autostart, home-manager plane (modules/home.nix) -- same regression
  # target, the actually-consumed launchCommand path (nixmsg.startupCommands above is never read
  # by anything else in this repo, but is fixed and checked anyway rather than left as a second,
  # unguarded copy of the same bug).
  cfgAutostartTelegramHome = evalHomeMod {
    nixmsg.home.autostart = [ "telegram" ];
  };

  cfgRelocate = evalHomeMod {
    nixmsg.home.relocate = [ "telegram" "threema" ];
    nixmsg.home.relocateTo = "/example/msg";
  };

  results = [
    # ── relocate: a Qt app and a Flatpak app both get a symlink at their OWN data path, which is
    #    the whole reason this is not desktopOverride.dataDir (Electron's --user-data-dir reaches
    #    neither of them) ──
    {
      name = "relocate/telegram-links-its-real-data-path";
      ok = (cfgRelocate.home.file.".local/share/TelegramDesktop" or null) != null
        && cfgRelocate.home.file.".local/share/TelegramDesktop".source == "/example/msg/telegram";
    }
    {
      name = "relocate/threema-flatpak-path-is-relocated-too";
      ok = (cfgRelocate.home.file.".var/app/ch.threema.threema-desktop" or null) != null
        && cfgRelocate.home.file.".var/app/ch.threema.threema-desktop".source == "/example/msg/threema";
    }
    {
      name = "relocate/unnamed-apps-are-left-alone";
      ok = !(cfgRelocate.home.file ? ".config/Signal");
    }

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

    # ── autostart launch command uses the real binary, never the package name (system-plane) ──
    (check "startupCommands/system-plane-uses-binary-not-package-name"
      (cfgAutostartTelegramSystem.nixmsg.startupCommands == [ "Telegram" ])
      "got: ${builtins.toJSON cfgAutostartTelegramSystem.nixmsg.startupCommands}")

    (check "startupCommands/system-plane-does-not-fall-back-to-package-name"
      (!(builtins.elem "telegram-desktop" cfgAutostartTelegramSystem.nixmsg.startupCommands))
      "got: ${builtins.toJSON cfgAutostartTelegramSystem.nixmsg.startupCommands}")

    # ── same property, home-manager plane -- the launchCommand path autostart actually uses ──
    (check "startupCommands/home-plane-uses-binary-not-package-name"
      (cfgAutostartTelegramHome.nixmsg.home.startupCommands == [ "Telegram" ])
      "got: ${builtins.toJSON cfgAutostartTelegramHome.nixmsg.home.startupCommands}")

    (check "startupCommands/home-plane-does-not-fall-back-to-package-name"
      (!(builtins.elem "telegram-desktop" cfgAutostartTelegramHome.nixmsg.home.startupCommands))
      "got: ${builtins.toJSON cfgAutostartTelegramHome.nixmsg.home.startupCommands}")
  ];

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-checks =
    if failed != [ ]
    then
      throw ''
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
