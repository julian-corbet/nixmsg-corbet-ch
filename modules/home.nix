#
# Home-manager module — session behavior for enabled apps: autostart, workspace-pin intent, and
# per-app runtime tuning (Wayland flags, data-dir relocation, teams-for-linux config). Deliberately
# compositor-agnostic (see the autostart/pin options' own history below) and deliberately does not
# duplicate the system-plane `nixmsg.apps.<name>.enable` list — this module takes its OWN
# `autostart`/`workspacePin` selections (same shape as modules/nixmsg.nix's system-plane
# options), because home-manager and NixOS/system-manager are separate evaluation planes in this
# family with no shared `config.*` to read across (see nix-family-graph.md's own measurement:
# "the home tree has nixremote and no nixnet; the system tree the reverse"). The consumer sets
# both lists to the same values; this module does not invent cross-plane machinery to avoid that
# one line of duplication.
#
# WHY A .desktop OVERRIDE MECHANISM EXISTS AT ALL. Verified live on a CachyOS laptop (2026-08-03),
# not assumed: three of the four Electron apps in this catalogue (Discord, Signal, Element) do not
# reliably pick up native Wayland rendering or an `ELECTRON_OZONE_PLATFORM_HINT` env var — Discord
# specifically bundles its own (often lagging) Electron via a bootstrap wrapper script with no
# flags-file support at all (confirmed by reading `/usr/bin/discord`: it just `exec`s argv
# through). The one reliable injection point for all three is the `.desktop` file's own `Exec=`
# line — see lib/desktop-overrides.nix for the real, live-verified upstream content each override
# is built from. teams-for-linux and Telegram/ZapZap need none of this (teams-for-linux
# auto-detects Wayland itself, confirmed live; Telegram/ZapZap are Qt-based, not Electron —
# native Qt for Telegram, PyQt6 + PyQt6-WebEngine for ZapZap).
#
{ config, lib, ... }:
let
  cfg = config.nixmsg.home;
  catalogue = import ../lib/catalogue.nix { };
  appNames = lib.attrNames catalogue;
  desktopOverrides = import ../lib/desktop-overrides.nix { };
  overrideNames = lib.attrNames desktopOverrides;

  # An enabled override's resolved flags: the app's own researched Wayland flags, plus
  # --user-data-dir when this app's data is being relocated (an ordinary Electron flag, not
  # Wayland-specific — every Electron app honors it, so no per-app research was needed for this
  # part the way the Wayland flags needed per-app verification).
  overrideFlags = name:
    let
      entry = desktopOverrides.${name};
      ov = cfg.desktopOverride.${name};
    in
    entry.waylandFlags ++ lib.optional (ov.dataDir != null) "--user-data-dir=${ov.dataDir}";

  overrideEnabled = name: cfg.desktopOverride ? ${name} && cfg.desktopOverride.${name}.enable;

  # Resolve a launch command for `autostart` — reuses an enabled override's binary+flags so an
  # autostarted app gets the same Wayland/data-dir treatment as its shadowed .desktop entry,
  # rather than the two mechanisms silently disagreeing about how the app should be launched.
  launchCommand = name:
    if overrideEnabled name then
      let entry = desktopOverrides.${name};
      in lib.concatStringsSep " " ([ entry.binary ] ++ overrideFlags name)
    else
      let
        entry = catalogue.${name};
        requested = cfg.channel.${name} or null;
      in
      if requested == "flatpak" || (entry.repo == null && entry.aur == null) then
        "flatpak run ${entry.flatpak}"
      else
        entry.binary;
  # entry.binary, NEVER entry.repo/entry.aur (the PACKAGE name) or entry.nixpkgs (a
  # NixOS-ecosystem name that can legitimately differ from either). Proven live that package name
  # and binary name diverge: `pacman -Ql telegram-desktop` installs `/usr/bin/Telegram` (capital
  # T), and `type -a telegram-desktop` finds nothing on $PATH at all — threema-desktop's AUR
  # package repeats the same mistake even more sharply, installing `/usr/bin/threema`. See
  # lib/catalogue.nix's own `binary` field comment for the per-app verification. Every catalogue
  # entry currently populates AT MOST one of repo/aur (never both), so `binary` doesn't need to
  # vary by requested channel the way `packageName` does — a future entry populating both with
  # genuinely different binaries would need this to become per-channel.

  mkDesktopFileText = name:
    let
      entry = desktopOverrides.${name};
      execLine = lib.concatStringsSep " " ([ entry.binary ] ++ overrideFlags name ++ [ entry.argsSuffix ]);
    in
    lib.concatStringsSep "\n" (lib.filter (l: l != null) [
      "[Desktop Entry]"
      "Type=Application"
      "Name=${entry.name}"
      "Comment=${entry.comment}"
      (if entry ? genericName then "GenericName=${entry.genericName}" else null)
      "Exec=${execLine}"
      "Icon=${entry.icon}"
      "Terminal=false"
      "Categories=${entry.categories}"
      "MimeType=${entry.mimeType}"
      "" # trailing newline
    ]);
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


    # ── Relocating an app's data out of $HOME ──────────────────────────────────────────────────
    #
    # `desktopOverride.<app>.dataDir` cannot do this job. It renders Electron's --user-data-dir,
    # so it reaches exactly the Electron apps and silently does nothing for the rest -- and this
    # catalogue is not all Electron: Telegram and ZapZap are Qt, and Threema is a Flatpak whose
    # data lives under ~/.var/app inside a sandbox that must be granted access to the target
    # before it can follow anything out.
    #
    # A symlink at each app's own data path works for every toolkit and every packaging, because
    # it is the filesystem answering rather than the application cooperating. mkOutOfStoreSymlink
    # rather than a managed copy: the target is mutable state the app writes constantly, so it
    # must NOT live in the nix store, and home-manager must not try to own its contents.
    #
    # WHY RELOCATE AT ALL is a storage question, not a messaging one: this data is large, changes
    # constantly, and on a host that snapshots $HOME every changed block is pinned by every
    # snapshot that follows. Giving it its own subvolume/dataset is what lets it carry its own
    # retention. The consumer decides where; this module only knows which path each app uses.
    #
    # A FLATPAK APP NEEDS ONE MORE STEP the consumer must take: the sandbox has no access to the
    # target by default, so a `flatpak override --filesystem=<target>` is required or the app
    # sees a dangling link. Nothing here can grant that -- it is host state, not user config.
    relocate = lib.mkOption {
      type = lib.types.listOf (lib.types.enum appNames);
      default = [ ];
      description = ''
        Apps whose data directory should live under `relocateTo` instead of its default place in
        $HOME, reached by a symlink at the original path.
      '';
    };

    relocateTo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/someone/msg";
      description = ''
        Absolute path of the directory holding relocated app data; each app in `relocate` gets a
        `<relocateTo>/<app>` leaf. Creating it, and giving it whatever snapshot or backup policy
        it deserves, is the consumer's job -- this module only points at it.
      '';
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

    # ── Per-app runtime tuning ────────────────────────────────────────────────────────────────
    desktopOverride = lib.genAttrs overrideNames (name: {
      enable = lib.mkEnableOption "a shadowing ~/.local/share/applications/${desktopOverrides.${name}.filename} for ${desktopOverrides.${name}.name}";
      dataDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          If set, appended as --user-data-dir=<path>. Electron-only (this app's own real,
          low-level Electron flag, not app-specific) — do not set this for a non-Electron app.
        '';
      };
    });

    electronWaylandHint = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Write ~/.config/environment.d/electron-wayland.conf (ELECTRON_OZONE_PLATFORM_HINT=auto).
        Read by Electron's own runtime bootstrap, not app code — applies uniformly including to
        apps whose .desktop override this module also generates. Harmless no-op on Electron ≥38.2
        (which auto-detects Wayland without it) and never read by non-Electron apps at all.
      '';
    };

    teamsConfig = {
      enable = lib.mkEnableOption "declarative ~/.config/teams-for-linux/config.json generation";
      trayIconEnabled = lib.mkOption { type = lib.types.bool; default = true; };
      minimizeOnClose = lib.mkOption { type = lib.types.bool; default = true; };
      closeAppOnCross = lib.mkOption { type = lib.types.bool; default = false; };
      maxCacheSizeMB = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 600;
        description = "null disables the cache cap (teams-for-linux's own default — off).";
      };
    };
  };

  config = {
    # throwIf rather than an `assertions` entry: this module is evaluated standalone by the
    # checks, where the module system carrying `assertions` is not composed, and a guard that
    # only fires inside a full home-manager evaluation is a guard that the tests cannot see.
    home.file = lib.throwIf (cfg.relocate != [ ] && cfg.relocateTo == null)
      "nixmsg.home.relocate names apps but nixmsg.home.relocateTo is null -- there is nowhere to point their data at."
      (lib.listToAttrs (map
        (n: lib.nameValuePair catalogue.${n}.dataPath {
          source = config.lib.file.mkOutOfStoreSymlink "${cfg.relocateTo}/${n}";
        })
        cfg.relocate));

    nixmsg.home.startupCommands = map launchCommand cfg.autostart;
    nixmsg.home.pinnedAppIds = map (n: catalogue.${n}.appId) cfg.workspacePin.apps;

    xdg.dataFile = lib.mapAttrs'
      (name: _: lib.nameValuePair
        "applications/${desktopOverrides.${name}.filename}"
        { text = mkDesktopFileText name; })
      (lib.filterAttrs (name: _: overrideEnabled name) desktopOverrides);

    xdg.configFile = lib.mkMerge [
      (lib.mkIf cfg.electronWaylandHint {
        "environment.d/electron-wayland.conf".text = "ELECTRON_OZONE_PLATFORM_HINT=auto\n";
      })
      (lib.mkIf cfg.teamsConfig.enable {
        "teams-for-linux/config.json".text = builtins.toJSON ({
          trayIconEnabled = cfg.teamsConfig.trayIconEnabled;
          minimizeOnClose = cfg.teamsConfig.minimizeOnClose;
          closeAppOnCross = cfg.teamsConfig.closeAppOnCross;
        } // lib.optionalAttrs (cfg.teamsConfig.maxCacheSizeMB != null) {
          cacheManagement = {
            enabled = true;
            maxCacheSizeMB = cfg.teamsConfig.maxCacheSizeMB;
          };
        });
      })
    ];
  };
}
