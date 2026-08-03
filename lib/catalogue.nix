#
# The messenger catalogue: one entry per selectable app, naming it on every real distribution
# channel. Mirrors nixdev's lib/tools.nix shape deliberately (same family, same reasoning): a
# selection resolves to a package NAME per channel, never a role — "signal" is not "an encrypted
# messenger you might swap for another", it is the thing that was asked for by name.
#
# CHANNELS, NOT JUST PLATFORMS. nixdev only ever needed `arch` + `nixpkgs`, because dev tools
# either have a real package or they don't. Messenger apps are messier: several of these have NO
# from-source or repo-native build at all (Teams, WhatsApp), and even where a from-source build
# exists (Threema — see below), an already-installed Flatpak may hold session/link-state a
# from-source swap would discard. So every entry carries up to three independent channels:
#
#   repo     — an OFFICIAL distro repo package (Arch `extra`/`core`). Verified against
#              archlinux.org, not guessed — see each entry's comment for the check.
#   aur      — an AUR package name, for when no official repo package exists (or as an
#              alternative build).
#   flatpak  — a Flatpak application ID, for when no native Linux build exists at all, or where
#              sandboxing genuinely matters more than a native package would (Threema: proprietary
#              Electron handling E2E-encrypted content).
#
# CHANNEL PREFERENCE ORDER, STATED ONCE HERE — never re-justified per entry below. (1) an official
# distro repo package, when one exists: one fewer build to trust, one update path already wired
# into the host's normal reconciler. (2) AUR, when it is a maintained vendor repackage: still ONE
# update path (the host's AUR helper, same cadence as everything else pacman-adjacent) and it
# avoids Flatpak's sandbox friction — file pickers that can't see the real $HOME without a portal,
# autostart entries needing one, GTK/Qt theming falling out of step with the rest of the session.
# (3) Flatpak, and ONLY when one of three things is true: no repo/AUR package exists at all (Teams;
# WhatsApp/ZapZap until nixpkgs picked it up); an operator's account is ALREADY linked to a Flatpak
# identity and re-pairing a messenger is an interactive device event — a QR scan, a phone code —
# that no package manager can redo (Threema, see that entry for the live case); or sandboxing a
# proprietary blob away from $HOME is itself the goal, not a fallback. Each entry's own comment
# says WHICH of these applied to ITS channel choice, not why the order exists at all.
#
# `flatpakRemote` names WHICH remote `flatpak` actually lives on, `null` meaning Flathub — the
# assumption every consumer of this catalogue used to hardcode instead of reading it from here
# (modules/flatpak-install.nix `remote-add`'d only Flathub and installed only from it). That
# assumption is false for Threema specifically: `ch.threema.threema-desktop` does NOT exist on
# Flathub at all — Flathub's own Threema listing is `ch.threema.threema-web-desktop`, a DIFFERENT
# app (the browser-wrapper variant, not the desktop client this catalogue names). The real desktop
# client is only ever distributed from Threema GmbH's own repo. An installer that only ever knows
# Flathub cannot install this entry — not "installs the wrong version", genuinely cannot resolve
# the id at all. See the `threema` entry below for the live values.
#
# `nixpkgs` is separate from all three: the attribute under a nixpkgs instance, or `null` where
# none exists. Every one of the 8 entries below DOES have a nixpkgs attribute (confirmed via
# `nix search nixpkgs` / `nix eval` against nixpkgs-unstable, 2026-08-03) — messenger clients
# turned out to have better nixpkgs coverage than Arch/AUR coverage, the reverse of what a naive
# guess would assume. Kept as its own field rather than folded into `repo` because a NixOS
# consumer resolves through `nixpkgs`, never through `repo`/`aur`/`flatpak` — those three are
# Arch-platform-only. VERIFY THE ATTRIBUTE NAME, NOT JUST ITS EXISTENCE: `zoom`'s entry below is
# the sharp example — top-level `pkgs.zoom` resolves cleanly to a wrong, unrelated package (the
# real one is `pkgs.zoom-us`), the same trap class as `pkgs.ark` being a Jupyter R kernel rather
# than the KDE archiver. A wrong-but-resolving attribute is worse than a missing one: it builds.
#
# `appId` is the Wayland/X11 app-id (StartupWMClass) the running window advertises — what a
# compositor's window-rule (`app-id="..."` in scroll/sway, `match app-id=` in niri) actually
# matches against. This is deliberately NOT always the same string as the flatpak id or the
# .desktop basename — Telegram is the sharpest example (desktop-file id `org.telegram.desktop`,
# but the StartupWMClass a compositor sees is `TelegramDesktop`), and getting this wrong produces
# a window-rule that silently matches nothing, not an error.
#
# WHAT WAS VERIFIED, AND HOW SURE. Six entries (discord, telegram, signal, element, whatsapp,
# zoom) had their app-id independently corroborated from upstream source, a well-established
# compositor window-rule example, or (whatsapp, zoom) a real `.desktop` file read directly out of
# the actual upstream/vendor package — see each entry's own comment for which. Two (teams,
# threema) rest on inference from the .desktop-file naming convention only — flagged per-entry
# below, and in `../experiments/README.md`. Treat those two as "verify once installed"
# (`niri msg windows` / a scroll equivalent), not as settled.
#
# EVERY `flatpak` ID BELOW WAS CHECKED AGAINST A LIVE FLATHUB, not assumed — seven resolve there
# (discord, telegram, signal, element, teams, whatsapp, zoom; confirmed via `flatpak remote-ls
# flathub` and, for whatsapp/zoom specifically, `flatpak remote-info flathub <id>`, 2026-08-03);
# threema's does not and carries `flatpakRemote` naming its real vendor repo instead. Do not add a
# `flatpak` id to a future entry without the same check — a wrong id is invisible at eval time and
# only surfaces as an install failure on a real host.
#
{ ... }:
{
  discord = {
    # extra/discord, confirmed 2026-08-03 (archlinux.org package search). No AUR needed for the
    # stable channel; AUR still separately hosts discord-canary/discord-ptb for the alpha/beta
    # release channels, deliberately NOT the default here (this table names the stable app).
    repo = "discord";
    aur = null;
    nixpkgs = "discord";
    flatpak = "com.discordapp.Discord";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    appId = "discord";
  };

  telegram = {
    # extra/telegram-desktop, confirmed 2026-08-03. No AUR needed.
    repo = "telegram-desktop";
    aur = null;
    nixpkgs = "telegram-desktop";
    flatpak = "org.telegram.desktop";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # NOT "org.telegram.desktop" (that's the .desktop/flatpak id). StartupWMClass is
    # "TelegramDesktop", verified against upstream tdesktop's own lib/xdg/*.desktop source.
    appId = "TelegramDesktop";
  };

  signal = {
    # extra/signal-desktop, confirmed 2026-08-03 — moved into the official repo since the last
    # time anyone checked this by hand; do not assume AUR-only without re-checking.
    repo = "signal-desktop";
    aur = null;
    nixpkgs = "signal-desktop";
    flatpak = "org.signal.Signal";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    appId = "signal";
  };

  element = {
    # extra/element-desktop, confirmed 2026-08-03 — also moved into the official repo since the
    # last time anyone checked this by hand. AUR element-desktop-bin exists as a fallback if
    # extra ever lags, deliberately not the default while extra is current.
    repo = "element-desktop";
    aur = null;
    nixpkgs = "element-desktop";
    # Legacy Riot naming retained upstream for compatibility.
    flatpak = "im.riot.Riot";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub
    # (Flathub kept the legacy id too, not just upstream).
    flatpakRemote = null;
    appId = "Element";
  };

  teams = {
    # No official Arch repo package exists, and Microsoft has shipped no native Linux client
    # since discontinuing classic Teams in Dec 2022 — "teams-for-linux" (IsmaelMartinez) is the
    # de facto unofficial Electron wrapper, actively maintained (weekly-ish releases as of
    # 2026-08-03) but a genuine third-party dependency: it can break silently if Microsoft
    # changes the Teams web app in ways its injected scripts depend on.
    repo = null;
    aur = "teams-for-linux";
    nixpkgs = "teams-for-linux";
    flatpak = "com.github.IsmaelMartinez.teams_for_linux";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # Inferred from the .desktop basename / Flatpak-id convention, NOT independently confirmed
    # against a running window — see experiments/README.md #1.
    appId = "com.github.IsmaelMartinez.teams_for_linux";
  };

  threema = {
    # No official Arch repo package. AUR "threema-desktop" builds an Electron wrapper FROM
    # SOURCE (matches nixpkgs' own threema-desktop attribute, AGPL-3.0 — confirmed via
    # `nix eval`, NOT the unfree proprietary blob a naive guess would expect). Flatpak
    # ch.threema.threema-desktop is a separate, unofficial repackage of the proprietary vendor
    # Electron binary — kept as an alternative channel specifically because an ALREADY-LINKED
    # Threema Beta flatpak install may exist on a host (confirmed live via `flatpak list`,
    # 2026-08-03 — the real installed ID, corrected here from an earlier unverified guess of
    # "ch.threema.threema-web-desktop"): swapping a live-linked Threema instance to a different
    # build is a device-relink event, not a transparent package swap, so the consumer chooses
    # the channel per host rather than this table forcing one.
    repo = null;
    aur = "threema-desktop";
    nixpkgs = "threema-desktop";
    flatpak = "ch.threema.threema-desktop";
    # NOT ON FLATHUB — confirmed live, 2026-08-03: `flatpak remote-ls flathub` has no
    # ch.threema.threema-desktop at all. Flathub's own Threema listing is
    # ch.threema.threema-web-desktop, a DIFFERENT app (the browser-wrapper variant), so this is
    # not "the wrong Flathub build", it is an id that simply does not resolve there. The real
    # desktop client is distributed only from Threema GmbH's own repo, matching the remote
    # already live on this host (`flatpak remotes`, 2026-08-03).
    flatpakRemote = {
      name = "threema-desktop";
      url = "https://releases.threema.ch/flatpak/threema-desktop/";
    };
    # UNVERIFIED which of the aur/nixpkgs from-source build vs the flatpak repackage this
    # actually matches — the two are different builds and may set different app-ids.
    appId = "ch.threema.threema-desktop";
  };

  whatsapp = {
    # WhatsApp has never had an official Linux client, and no official Arch repo package exists
    # for any third-party wrapper either. Between the two maintained AUR wrappers, ZapZap is the
    # one this table names — not on features (both are WebEngine shells around web.whatsapp.com,
    # functionally the same app), on maintenance and adoption, checked directly against the AUR,
    # 2026-08-03:
    #
    #   zapzap   75 votes, popularity 5.65, last updated 2026-07-30, PyQt6 + PyQt6-WebEngine
    #   whatsie  24 votes, popularity 1.08, last updated 2026-04-04, version string
    #            5.1.0.r0.g004863f — a git snapshot off an untagged commit, not a tagged release
    #
    # Whatsie was this table's previous pick; it isn't gone from the AUR, it's simply no longer
    # the better-maintained of the two by any measure checked here — revisit this pick if that
    # gap closes, not on taste. (AUR also hosts "zapzap-bin", a separately-maintained, 1-vote
    # package installing from the project's published wheel rather than building from source; not
    # picked here because the from-source "zapzap" package already builds cleanly and carries the
    # adoption signal above — same reasoning this table already applies to threema's from-source
    # AUR build over a prebuilt alternative.)
    repo = null;
    aur = "zapzap";
    nixpkgs = "zapzap";
    flatpak = "com.rtosta.zapzap";
    # Confirmed live against `flatpak remote-info flathub com.rtosta.zapzap`, 2026-08-03 —
    # genuinely on Flathub.
    flatpakRemote = null;
    # VERIFIED, not inferred — read directly out of upstream's own
    # share/applications/com.rtosta.zapzap.desktop at tag 6.5.2.5 (github.com/rafatosta/zapzap),
    # the exact version nixpkgs' own `zapzap` attribute builds: `StartupWMClass=zapzap`.
    appId = "zapzap";
  };

  zoom = {
    # No official Arch repo package — confirmed against archlinux.org, 2026-08-03: no "zoom"
    # package in core/extra/multilib. AUR "zoom" (738 votes, maintainer edh, updated 2026-07) is a
    # repackage of Zoom's own vendor `.pkg.tar.xz` — Zoom ships no source at all, so unlike
    # Threema there is no from-source alternative to weigh against it; its PKGBUILD's `package()`
    # step is a literal `cp -dpr` of the downloaded vendor tree, confirmed by reading it.
    repo = null;
    aur = "zoom";
    # NOT `pkgs.zoom` — that resolves cleanly to an unrelated package, the same trap class as
    # `pkgs.ark` being a Jupyter R kernel rather than the KDE archiver. The real attribute is
    # `zoom-us`. Confirmed 2026-08-03:
    #   nix eval --raw nixpkgs#zoom-us.name  =>  zoom-7.1.0.3715
    #   nix eval --raw nixpkgs#zoom.name     =>  zoom-1.1.5
    # Getting this backwards doesn't error at eval time — it installs a wrong package, cleanly.
    nixpkgs = "zoom-us";
    flatpak = "us.zoom.Zoom";
    # Confirmed live against `flatpak remote-info flathub us.zoom.Zoom`, 2026-08-03 — genuinely on
    # Flathub (version 7.1.5.4332 there, a few weeks ahead of the AUR package's 7.1.5-1 but the
    # same 7.1.5 line — nothing here suggests channel divergence worth tracking).
    flatpakRemote = null;
    # VERIFIED, not inferred — read directly out of the real vendor `.desktop` file, two
    # independent ways that agree: (1) the AUR package's own vendor tarball, downloaded and
    # extracted at usr/share/applications/Zoom.desktop, declares `StartupWMClass=zoom`; (2)
    # Flathub's own us.zoom.Zoom.desktop (github.com/flathub/us.zoom.Zoom) independently declares
    # the identical `StartupWMClass=zoom`. Both channels' actual shipped desktop files were read,
    # not assumed from a naming convention.
    appId = "zoom";
  };
}
