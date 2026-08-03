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
# none exists. Every one of the 7 entries below DOES have a nixpkgs attribute (confirmed via
# `nix search nixpkgs` against nixpkgs-unstable, 2026-08-03) — messenger clients turned out to
# have better nixpkgs coverage than Arch/AUR coverage, the reverse of what a naive guess would
# assume. Kept as its own field rather than folded into `repo` because a NixOS consumer resolves
# through `nixpkgs`, never through `repo`/`aur`/`flatpak` — those three are Arch-platform-only.
#
# `appId` is the Wayland/X11 app-id (StartupWMClass) the running window advertises — what a
# compositor's window-rule (`app-id="..."` in scroll/sway, `match app-id=` in niri) actually
# matches against. This is deliberately NOT always the same string as the flatpak id or the
# .desktop basename — Telegram is the sharpest example (desktop-file id `org.telegram.desktop`,
# but the StartupWMClass a compositor sees is `TelegramDesktop`), and getting this wrong produces
# a window-rule that silently matches nothing, not an error.
#
# WHAT WAS VERIFIED, AND HOW SURE. Four entries (discord, telegram, signal, element) had their
# app-id independently corroborated from upstream source or well-established compositor
# window-rule examples. Three (teams, threema, whatsapp) rest on inference from the .desktop-file
# naming convention only — flagged per-entry below, and in `../experiments/README.md`. Treat those
# three as "verify once installed" (`niri msg windows` / a scroll equivalent), not as settled.
#
# EVERY `flatpak` ID BELOW WAS CHECKED AGAINST A LIVE `flatpak remote-ls flathub`, not assumed —
# six resolve there (discord, telegram, signal, element, teams, whatsapp); threema's does not
# (confirmed live, 2026-08-03) and carries `flatpakRemote` naming its real vendor repo instead. Do
# not add a `flatpak` id to a future entry without the same check — a wrong id is invisible at
# eval time and only surfaces as an install failure on a real host.
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
    # WhatsApp has never had an official Linux client. "Whatsie" (ktechpit) is the best-
    # maintained real option as of 2026-08-03: the same upstream project ships identically as
    # both an AUR package and a Flathub app (28.5k monthly downloads, most popular of the
    # WhatsApp-wrapper options), unlike competitors that were delisted (mimbrero) or fragmented
    # under a rename (WasIstLos). No official Arch repo package.
    repo = null;
    aur = "whatsie";
    nixpkgs = "whatsie";
    flatpak = "com.ktechpit.whatsie";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # Inferred from the Flatpak-id convention, NOT independently confirmed against a running
    # window — see experiments/README.md #1.
    appId = "com.ktechpit.whatsie";
  };
}
