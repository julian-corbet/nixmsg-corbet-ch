#
# nixmsg — messenger apps, declared per host instead of hand-installed and forgotten.
#
# WHAT THIS IS FOR. The gap this closes is real and was found live, not hypothesised: a fleet's
# `messengers` autolaunch toggle already assumed telegram-desktop/signal-desktop/discord/Element
# existed, and a separate audit the same week found a Threema Flatpak installed and in daily use
# with zero line of Nix declaring it anywhere — ambient state, invisible to any reconciler,
# exactly the class of drift nixarch/nixdev exist to close for everything else on these hosts.
#
# EACH APP HAS UP TO THREE INSTALL CHANNELS on Arch (repo/aur/flatpak — see
# ../lib/catalogue.nix), because unlike nixdev's tools this catalogue includes apps with no
# official-repo or even AUR-native build at all, and one case (Threema) where an operator may
# specifically want to KEEP an already-linked Flatpak identity rather than switch builds. The
# channel is therefore named explicitly per app, never silently defaulted away from what's
# already running — an unset `channel` auto-resolves to the best available (repo > aur >
# flatpak), but an operator with a live Flatpak identity to preserve overrides it per host.
#
# WHAT THIS DOES NOT OWN. Compositor window-rule / workspace-pin SYNTAX belongs to whichever
# compositor module the consumer runs (nixscroll's `extraConfig`, niri's own window-rule option)
# — nixmsg only computes and exposes the resolved intent (which app-ids, for the `workspacePin`
# set), never emits raw compositor config itself. Same boundary nixscroll/nixniri already draw
# for themselves ("translate resolved intent → their own syntax" is THEIR job, not a catalogue's).
#
{ config, lib, ... }:
let
  cfg = config.nixmsg;
  catalogue = import ../lib/catalogue.nix { };
  appNames = lib.attrNames catalogue;

  # The implicit default a `null` `flatpakRemote` in the catalogue means — see that field's own
  # comment in lib/catalogue.nix for why an entry can name a different one instead.
  flathubRemote = {
    name = "flathub";
    url = "https://flathub.org/repo/flathub.flatpakrepo";
  };

  channelType = lib.types.nullOr (lib.types.enum [ "repo" "aur" "flatpak" ]);

  appOptions = name: {
    enable = lib.mkEnableOption "the ${name} messenger app";
    channel = lib.mkOption {
      type = channelType;
      default = null;
      description = ''
        Which install channel to use for ${name}: "repo" (official Arch repo), "aur", or
        "flatpak". Left null (the default), the best available channel is picked automatically
        in that order. Set explicitly to pin a specific build — most relevantly, "flatpak" to
        preserve an already-linked/already-configured Flatpak identity rather than switch to a
        different build that would start from a clean state.
      '';
    };
  };

  # Resolve one enabled app's channel + package identity. Asserts rather than silently falling
  # back when an operator names a channel the catalogue entry has no value for — a typo'd
  # override that quietly resolves to nothing is exactly the failure mode this module exists to
  # remove (same reasoning as nixdev's mkGroup: an unknown key is an error, not a silent no-op).
  resolveApp = name:
    let
      entry = catalogue.${name};
      requested = cfg.apps.${name}.channel;
      auto =
        if entry.repo != null then "repo"
        else if entry.aur != null then "aur"
        else if entry.flatpak != null then "flatpak"
        else null;
      channel = if requested != null then requested else auto;
      channelValue = { repo = entry.repo; aur = entry.aur; flatpak = entry.flatpak; }.${
      if channel == null then "repo" else channel
      };
    in
    assert lib.assertMsg (channel != null)
      "nixmsg.apps.${name}: catalogue entry has no repo, aur, or flatpak channel at all — this is a catalogue bug, not a config error.";
    assert lib.assertMsg (channelValue != null)
      "nixmsg.apps.${name}.channel = \"${channel}\" was requested, but lib/catalogue.nix has no \"${channel}\" value for ${name}. Available: ${
        lib.concatStringsSep ", " (lib.filter (c: entry.${c} != null) [ "repo" "aur" "flatpak" ])
      }.";
    entry // {
      inherit name channel;
      packageName = channelValue;
    };

  enabledNames = lib.filter (n: cfg.apps.${n}.enable) appNames;
  resolved = map resolveApp enabledNames;
in
{
  options.nixmsg = {
    apps = lib.genAttrs appNames (name: appOptions name);

    autostart = lib.mkOption {
      type = lib.types.listOf (lib.types.enum appNames);
      default = [ ];
      description = ''
        Which enabled apps should be started automatically at session start. Entries here that
        are not also enabled in `nixmsg.apps.<name>.enable` are a build failure — autostarting an
        app that was never asked to be installed is a mistake to name, not a state to silently
        allow. The home-manager module turns this into commands appended to
        `nixdesktop.startup` (the compositor-agnostic contract nixniri/nixscroll both already
        read), so no compositor-specific wiring is needed here.
      '';
    };

    workspacePin = {
      workspace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Which named workspace to pin `apps` below to, if any.";
      };
      apps = lib.mkOption {
        type = lib.types.listOf (lib.types.enum appNames);
        default = [ ];
        description = ''
          Which enabled apps should be pinned to `workspace`. Same enabled-first constraint as
          `autostart`. nixmsg resolves this to app-ids only (`pinnedAppIds` below) — writing the
          actual window-rule is the consuming compositor module's job.
        '';
      };
    };

    # ── Computed, read-only ─────────────────────────────────────────────────────────────────
    resolved = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Resolved catalogue entries for every enabled app. The contract a platform backend consumes.";
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Enabled apps resolved to the "repo" channel, as official-Arch-repo package names. This
        module installs nothing on Arch — feed it to whatever reconciler the host uses, e.g.

          nixarch.packages.pacman = config.nixmsg.archPackages;
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Enabled apps resolved to the "aur" channel, kept SEPARATE from archPackages because
        `pacman -S` cannot resolve an AUR name — mixing the two aborts the whole transaction.
        Wire to the AUR side of the same reconciler, e.g.

          nixarch.packages.aur = config.nixmsg.aurPackages;
      '';
    };

    flatpakApps = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      description = ''
        Enabled apps resolved to the "flatpak" channel, as `{ id, remoteName, remoteUrl }`.
        Neither a NixOS nor an Arch package manager installs these, and NEITHER DOES THIS REPO —
        this list is inert until a consumer hands it to an installer. nixflat
        (github:julian-corbet/nixflat-corbet-ch) is the one written against this exact shape, and
        it accepts several catalogues at once, which is the point:

            nixflat.apps = config.nixmsg.flatpakApps ++ config.nixoffice.flatpakApps;

        Carries the remote alongside the id RATHER THAN a bare id list, because "which Flatpak
        remote" is not always Flathub — see lib/catalogue.nix's `flatpakRemote` field, and its
        `threema` entry specifically: `ch.threema.threema-desktop` does not exist on Flathub at
        all, only on Threema's own repo. Deliberately ONE option carrying id+remote together,
        not this list plus a second `id -> remote` lookup alongside it: two outputs that must be
        indexed back together by a consumer are two outputs that can silently fall out of step
        the moment either one gains or loses an entry on its own — the failure mode this repo's
        own header comments call out repeatedly for other pairs it keeps merged for exactly this
        reason. A consumer that only wants bare ids: `map (a: a.id) config.nixmsg.flatpakApps`.
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Enabled, non-flatpak-channel apps' nixpkgs attribute names, for the NixOS backend.";
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Enabled, non-flatpak-channel apps with no nixpkgs equivalent. Surfaced rather than
        silently dropped — every entry in the catalogue currently has one, so a non-empty list
        here means either a new catalogue entry shipped without a nixpkgs attribute, or the
        attribute was renamed/removed upstream.
      '';
    };

    appIds = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        name -> Wayland/X11 app-id (StartupWMClass), for every ENABLED app — not just the ones
        `workspacePin` covers. A convenience for a consumer writing window rules of their own
        beyond what this module pins.
      '';
    };

    pinnedAppIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "app-ids for `workspacePin.apps`, resolved — the raw material for a compositor's own window-rule syntax.";
    };

    startupCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Shell command strings for `autostart` apps, for the home-manager module to splice into `nixdesktop.startup`.";
    };
  };

  config = {
    # A build-time typo check for both nixmsg.autostart and nixmsg.workspacePin.apps: naming an
    # app that isn't also enabled is refused rather than silently ignored.
    assertions =
      map
        (n: {
          assertion = cfg.apps.${n}.enable;
          message = "nixmsg.autostart names \"${n}\", but nixmsg.apps.${n}.enable is false.";
        })
        cfg.autostart
      ++ map
        (n: {
          assertion = cfg.apps.${n}.enable;
          message = "nixmsg.workspacePin.apps names \"${n}\", but nixmsg.apps.${n}.enable is false.";
        })
        cfg.workspacePin.apps;

    nixmsg.resolved = resolved;

    nixmsg.archPackages = lib.unique (map (a: a.packageName) (lib.filter (a: a.channel == "repo") resolved));
    nixmsg.aurPackages = lib.unique (map (a: a.packageName) (lib.filter (a: a.channel == "aur") resolved));
    nixmsg.flatpakApps = lib.unique (map
      (a: {
        id = a.packageName;
        remoteName = if a.flatpakRemote == null then flathubRemote.name else a.flatpakRemote.name;
        remoteUrl = if a.flatpakRemote == null then flathubRemote.url else a.flatpakRemote.url;
      })
      (lib.filter (a: a.channel == "flatpak") resolved));

    nixmsg.nixosPackages =
      lib.unique (map (a: a.nixpkgs) (lib.filter (a: a.channel != "flatpak" && a.nixpkgs != null) resolved));
    nixmsg.unavailableOnNixos =
      lib.unique (map (a: a.name) (lib.filter (a: a.channel != "flatpak" && a.nixpkgs == null) resolved));

    nixmsg.appIds = lib.listToAttrs (map (a: lib.nameValuePair a.name a.appId) resolved);
    # A name in workspacePin.apps/autostart that isn't also enabled is caught by the assertions
    # above with a clear message — these two just skip it rather than crash on a missing/null
    # lookup, so that clear message is what actually surfaces instead of a raw eval error racing
    # it (nothing guarantees assertions are forced before these are, under a bare `evalModules`).
    nixmsg.pinnedAppIds = lib.filter (x: x != null) (map (n: cfg.appIds.${n} or null) cfg.workspacePin.apps);

    # a.binary, NEVER a.packageName, for the non-flatpak branch — a.packageName is the PACKAGE
    # name (repo/aur), not necessarily the executable name; see lib/catalogue.nix's own `binary`
    # field comment and modules/home.nix's identical fix (telegram: package "telegram-desktop",
    # real binary "Telegram") for the live proof this mirrors.
    nixmsg.startupCommands =
      lib.filter (x: x != null)
        (map
          (n:
            let a = lib.findFirst (r: r.name == n) null resolved;
            in if a == null then null
            else if a.channel == "flatpak" then "flatpak run ${a.packageName}" else a.binary
          )
          cfg.autostart);
  };
}
