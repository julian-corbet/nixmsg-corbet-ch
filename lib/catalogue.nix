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
# (this repo's own installer, now nixflat's, `remote-add`'d only Flathub and installed only from
# it before that was fixed). That
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
# VERIFY THE VERSION TOO IF AN ENTRY MAKES A CLAIM ABOUT IT: nixpkgs' pin moves independently of
# any specific upstream tag, and citing "the exact version X builds" goes stale the moment either
# side updates — see zapzap's own comment below for a claim of this shape that was wrong, and how
# it's stated now instead.
#
# `binary` is the actual executable name pacman puts on $PATH for the repo/aur channel — NOT
# necessarily the package name, and modules/home.nix used to assume they were identical (feeding
# `entry.repo`/`entry.aur` straight into a shell command as if a package name were also its
# binary). Proven wrong live: `pacman -Ql telegram-desktop | grep /usr/bin/` installs
# `/usr/bin/Telegram` (capital T), and `type -a telegram-desktop` finds nothing on $PATH at all —
# the old launch command was a string that built cleanly and failed silently at runtime.
# Threema's AUR package repeats the same mistake even more sharply: package `threema-desktop`,
# binary `/usr/bin/threema` (see that entry's own comment). Verified against
# `pacman -Ql <pkg> | grep /usr/bin/` on a live Arch host for the five entries actually installed
# there (discord, telegram-desktop, signal-desktop, element-desktop, teams-for-linux); the other
# three (threema-desktop, zapzap, zoom) aren't installed on that host, so their `binary` value
# comes from reading the AUR package's own `package()` step / upstream packaging config instead —
# see each entry's own comment for which. Only meaningful for the repo/aur channels: the flatpak
# channel never launches by executable name, always `flatpak run <flatpak id>`. Every entry below
# currently populates AT MOST one of repo/aur, never both, so one `binary` field is enough to
# cover whichever channel actually exists — if a future entry ever populates both with genuinely
# different binaries, this single field stops being sufficient and needs to become per-channel.
#
# `appId` is the Wayland app-id the running window's `xdg_toplevel` surface actually advertises —
# what a compositor's window-rule (`app-id="..."` in scroll/sway, `match app-id=` in niri) matches
# against.
#
# STARTUPWMCLASS IS THE WRONG FIELD TO READ FOR THIS, AND WAS THIS TABLE'S ORIGINAL SIN. A
# `.desktop` file's `StartupWMClass` is an X11 concept — freedesktop.org's Desktop Entry spec
# defines it as "should be equal to the string WM_CLASS property [...] of the application's main
# window". It says nothing about a Wayland client's `xdg_toplevel` `app_id`, and nothing REQUIRES
# the two to match. Each toolkit sets its Wayland app_id through its own, separate mechanism, none
# of which reads StartupWMClass: Qt/PyQt from `QGuiApplication::setDesktopFileName()` (zapzap;
# Threema's builds, unverified — see below); Electron from `app.setDesktopName()`, which Electron's
# OWN bootstrap (`lib/browser/init.ts`) calls automatically with `package.json`'s `desktopName`
# field if present, else a computed slug of the app's name — and which the app's own code can call
# again later to override that default (discord/signal/element/teams-for-linux, all Electron; see
# each entry below for which path applies). Proven wrong live, on this exact table's first draft:
# Telegram's `.desktop` file declares `StartupWMClass=TelegramDesktop`, but `scrollmsg -t get_tree`
# against the REAL running window (a live Arch host, 2026-08-03) reports `app_id:
# "org.telegram.desktop"` — the desktop-file id, not the StartupWMClass string. Reading
# StartupWMClass produces a window-rule that silently matches nothing on Wayland, not an error.
#
# WHAT WAS VERIFIED, AND HOW, PER APP (2026-08-03, re-verified end to end after the
# StartupWMClass mistake above was found — see `../experiments/README.md` #002 (threema) and #005
# (zoom) for what's still genuinely open):
#
#   discord   LIVE — launched on a live Arch host, `scrollmsg -t get_tree`: app_id "discord".
#   telegram  LIVE — was already running on a live Arch host, `scrollmsg -t get_tree`: app_id
#             "org.telegram.desktop". Previously wrong: "TelegramDesktop" (StartupWMClass).
#   signal    SOURCE — the shipped app.asar's own `package.json` carries `"desktopName":
#             "signal.desktop"`, read directly out of the real
#             `/usr/lib/signal-desktop/resources/app.asar` on a live Arch host; Electron's
#             bootstrap uses this value literally (minus the `.desktop` suffix) as the app_id.
#             Live attempt aborted: signal-desktop's local DB failed to decrypt against this
#             host's current keyring backend (an unrelated, in-flight issue) and it crashed
#             before ever mapping a window.
#   element   SOURCE — the shipped app.asar's own JS explicitly calls
#             `app.setDesktopName("Element")`, read directly out of the real
#             `/usr/lib/element/app.asar` on a live Arch host, with the developers' own comment
#             attached: "Set the desktop name explicitly to ensure correct WM_CLASS and Wayland
#             app_id when running with a system Electron binary."
#   teams     SOURCE, derived rather than captured — teams-for-linux only calls
#             `app.setDesktopName()` when an operator explicitly sets the non-default `class`
#             config key (default: `null`); its shipped `package.json` has neither `desktopName`
#             nor `productName`, so Electron's own bootstrap falls back to slugifying `name`
#             ("teams-for-linux", already a valid slug) — confirmed against the exact Electron
#             version this package ships, 42.5.0 (`teams-for-linux --version`), well past the
#             41.6.1 backport this specific fallback needs. NOT the Flatpak id this table
#             previously guessed by naming convention. Live attempt made: the app starts fully
#             into the system tray with no window ever mapped (26s waited), so this rests on the
#             derivation above, not a capture.
#   threema   SPLIT — the two channels are confirmed to be different builds and do not share an
#             app_id. flatpak (`ch.threema.threema-desktop`, Threema GmbH's own official build):
#             LIVE — launched on a live Arch host, where it is already linked and in daily use,
#             `scrollmsg -t get_tree`: app_id "Threema". aur/nixpkgs (`threema-desktop` — the
#             DEFAULT channel, since threema has no `repo` entry): UNVERIFIED. Its own AUR
#             PKGBUILD shows a from-source Electron build of a genuinely different upstream
#             project (threema-ch/threema-web-electron, package name "threema-consumer-web"
#             internally) launched through the system's `electron37` package rather than a
#             bundled one — an older major version than teams-for-linux's, so the fallback logic
#             above cannot be assumed to apply the same way — and the source sets neither
#             `desktopName` nor calls `setDesktopName()` anywhere. See
#             `../experiments/README.md` #002.
#   zapzap    SOURCE — upstream's own `zapzap/app/application.py` calls
#             `app.setDesktopFileName(zapzap.__desktopid__)`, where `zapzap/__init__.py` sets
#             `__desktopid__ = 'com.rtosta.zapzap'` — read directly out of upstream source,
#             confirmed unchanged from tag 6.5.2.5 through the current 7.2. NOT "zapzap": that's
#             `StartupWMClass=zapzap` in the same shipped `.desktop` file, exactly the field this
#             header explains is wrong for Wayland.
#   zoom      UNVERIFIED — neither method settled it. Live: installed the Flathub build fresh on
#             a live Arch host (`flatpak install`/`flatpak run us.zoom.Zoom`) — no window ever
#             mapped in ~30s (no crash, no error beyond a harmless D-Bus warning); the app and
#             its two pulled-in runtimes were removed again afterward, leaving no trace. Source:
#             the AUR package is a literal `cp -dpr` of Zoom's own proprietary vendor tree — no
#             source exists to read. The vendor binary does link the
#             `QGuiApplication::setDesktopFileName` symbol, but is stripped, so nothing confirms
#             whether Zoom's own code calls it, or with what string. `StartupWMClass=zoom`, read
#             from two independent shipped `.desktop` files, is kept below as the best available
#             placeholder — no longer claimed as settled.
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
    # pacman -Ql discord | grep /usr/bin/ -> /usr/bin/discord, confirmed on a live Arch host.
    binary = "discord";
    nixpkgs = "discord";
    flatpak = "com.discordapp.Discord";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # LIVE — launched on a live Arch host (2026-08-03), scrollmsg -t get_tree: app_id "discord".
    dataPath = ".config/discord";
    appId = "discord";
  };

  telegram = {
    # extra/telegram-desktop, confirmed 2026-08-03. No AUR needed.
    repo = "telegram-desktop";
    aur = null;
    # NOT "telegram-desktop" — pacman -Ql telegram-desktop | grep /usr/bin/ -> /usr/bin/Telegram
    # (capital T), confirmed on a live Arch host. `type -a telegram-desktop` finds nothing on
    # $PATH at all; the old launch command (package name reused as the binary) built cleanly and
    # failed silently at runtime. See the header's own `binary` paragraph.
    binary = "Telegram";
    nixpkgs = "telegram-desktop";
    flatpak = "org.telegram.desktop";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # LIVE, and the proof cited in the header above: was already running on a live Arch host,
    # scrollmsg -t get_tree: app_id "org.telegram.desktop" (the desktop-file id) — NOT
    # "TelegramDesktop" (that's StartupWMClass, the wrong X11-only field; see the header).
    dataPath = ".local/share/TelegramDesktop";
    appId = "org.telegram.desktop";
  };

  signal = {
    # extra/signal-desktop, confirmed 2026-08-03 — moved into the official repo since the last
    # time anyone checked this by hand; do not assume AUR-only without re-checking.
    repo = "signal-desktop";
    aur = null;
    # pacman -Ql signal-desktop | grep /usr/bin/ -> /usr/bin/signal-desktop, confirmed on
    # a live Arch host — matches the package name here, but see telegram's own comment for why
    # that can never be assumed without checking.
    binary = "signal-desktop";
    nixpkgs = "signal-desktop";
    flatpak = "org.signal.Signal";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # SOURCE — the shipped app.asar's own package.json carries `"desktopName": "signal.desktop"`
    # (read directly out of /usr/lib/signal-desktop/resources/app.asar on a live Arch host);
    # Electron's own bootstrap (lib/browser/init.ts) calls
    # `app.setDesktopName(packageJson.desktopName || ...)` with this value automatically, and the
    # Wayland app_id is this string with the .desktop suffix stripped. Live attempt aborted:
    # signal-desktop's local DB failed to decrypt against this host's current keyring backend (an
    # unrelated, in-flight issue) and it crashed before ever mapping a window.
    dataPath = ".config/Signal";
    appId = "signal";
  };

  element = {
    # extra/element-desktop, confirmed 2026-08-03 — also moved into the official repo since the
    # last time anyone checked this by hand. AUR element-desktop-bin exists as a fallback if
    # extra ever lags, deliberately not the default while extra is current.
    repo = "element-desktop";
    aur = null;
    # pacman -Ql element-desktop | grep /usr/bin/ -> /usr/bin/element-desktop, confirmed on
    # a live Arch host.
    binary = "element-desktop";
    nixpkgs = "element-desktop";
    # Legacy Riot naming retained upstream for compatibility.
    flatpak = "im.riot.Riot";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub
    # (Flathub kept the legacy id too, not just upstream).
    flatpakRemote = null;
    # SOURCE — the shipped app.asar's own JS explicitly calls `app.setDesktopName("Element")`
    # (read directly out of /usr/lib/element/app.asar on a live Arch host), with the developers'
    # own comment attached to the call: "Set the desktop name explicitly to ensure correct
    # WM_CLASS and Wayland app_id when running with a system Electron binary."
    dataPath = ".config/Element";
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
    # pacman -Ql teams-for-linux | grep /usr/bin/ -> /usr/bin/teams-for-linux, confirmed on
    # a live Arch host.
    binary = "teams-for-linux";
    nixpkgs = "teams-for-linux";
    flatpak = "com.github.IsmaelMartinez.teams_for_linux";
    # Confirmed live against `flatpak remote-ls flathub`, 2026-08-03 — genuinely on Flathub.
    flatpakRemote = null;
    # SOURCE, derived rather than captured live — see the header for the full chain. In short:
    # teams-for-linux only calls `app.setDesktopName()` when an operator sets the non-default
    # `class` config key (default null); absent that, Electron's own bootstrap slugifies
    # package.json's `name` field ("teams-for-linux", already a valid slug) — confirmed against
    # this package's actual shipped Electron version, 42.5.0. NOT the Flatpak id this table
    # previously guessed by naming convention.
    dataPath = ".config/teams-for-linux";
    appId = "teams-for-linux";
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
    # NOT "threema-desktop" — the AUR PKGBUILD's own package() step installs to
    # "${pkgdir}/usr/bin/${_binname}" with _binname=threema, i.e. /usr/bin/threema (confirmed by
    # reading the PKGBUILD directly; this channel isn't installed on a live Arch host to also
    # check with pacman -Ql). A second, sharper instance of exactly telegram's mistake — see the
    # header's `binary` paragraph.
    binary = "threema";
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
      # A BARE OSTREE REPO, not a `.flatpakrepo` — and that distinction is load-bearing, not
      # cosmetic. A `.flatpakrepo` (Flathub's url is one) carries the remote's public key inline
      # as `GPGKey=`; this url carries nothing. `flatpak remote-add` accepts it regardless and
      # succeeds, then every later operation on that remote fails with
      # "Can't check signature: public key not found" — the key is missing, but the error names
      # the summary, so it reads like a broken repo rather than a keyless remote.
      #
      # Threema's own documented install command is a `.flatpakref`, never a remote-add, for
      # exactly this reason: the ref carries `GPGKey=`, `Url=` and `SuggestRemoteName=` together,
      # so `flatpak install --from` registers the remote WITH its key and installs in one step.
      # Verified live 2026-08-04 (HTTP 200, `GPGKey=` present); no `.flatpakrepo` is published at
      # any conventional path (four probed, all 404).
      #
      # Found the hard way: a host that had this remote added BY HAND months earlier worked, and
      # a fresh host failed — the difference being a `threema-desktop.trustedkeys.gpg` sitting in
      # one repo and not the other. A catalogue that only names a url reproduces the hand-setup,
      # not the working state.
      flatpakref = "https://releases.threema.ch/flatpak/threema-desktop/ch.threema.threema-desktop.flatpakref";
    };
    # SPLIT, confirmed rather than merely suspected now — see the header and
    # ../experiments/README.md #002. The flatpak build's app_id is LIVE-verified "Threema":
    # launched on a live Arch host, where it is already linked and in daily use, scrollmsg -t
    # get_tree: app_id "Threema". The aur/nixpkgs build — the one this table's DEFAULT channel
    # actually resolves to, since threema has no `repo` — is a genuinely different codebase
    # (threema-ch/threema-web-electron, launched through the system's older `electron37`, not a
    # bundled Electron) whose source sets neither `desktopName` nor calls `setDesktopName()`
    # anywhere: UNVERIFIED. This field holds the one confirmed value; do not assume it also
    # matches the aur/nixpkgs channel's real window.
    dataPath = ".var/app/ch.threema.threema-desktop";
    appId = "Threema";
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
    # gap closes, not on taste.
    #
    # "zapzap-bin" RATHER THAN "zapzap", and the adoption numbers are the wrong criterion here.
    # Both package the SAME upstream at the same version (7.2 at the time of writing); the only
    # difference is that "zapzap" compiles PyQt6 + PyQt6-WebEngine on every host that installs it
    # and "zapzap-bin" installs the project's own published wheel. A fleet pays that compile once
    # per machine, and a source build is one more thing that can fail on a host with a slightly
    # different toolchain — which it did, on a container where the from-source package aborted
    # while every other declared package converged. Vote counts measure how many people run a
    # package, not whether building it is a sensible thing for a reconciler to do unattended.
    #
    # The artifact still comes from upstream either way; what is skipped is the local compile,
    # not the provenance.
    repo = null;
    aur = "zapzap-bin";
    # pyproject.toml's own [project.scripts] entry point: `zapzap = "zapzap.__main__:main"` — read
    # directly out of upstream source (tag 7.2), matching the AUR PKGBUILD's wheel install and the
    # pkgname itself; not installed on a live Arch host to also check with pacman -Ql.
    binary = "zapzap";
    nixpkgs = "zapzap";
    flatpak = "com.rtosta.zapzap";
    # Confirmed live against `flatpak remote-info flathub com.rtosta.zapzap`, 2026-08-03 —
    # genuinely on Flathub.
    flatpakRemote = null;
    # SOURCE — upstream's own zapzap/app/application.py calls
    # `app.setDesktopFileName(zapzap.__desktopid__)`, where zapzap/__init__.py sets
    # `__desktopid__ = 'com.rtosta.zapzap'` — read directly out of upstream source, confirmed
    # unchanged from tag 6.5.2.5 through the current 7.2. NOT "zapzap": that's
    # `StartupWMClass=zapzap` in the same shipped .desktop file — exactly the field the header
    # above explains is wrong for Wayland. nixpkgs' own `zapzap` attribute does NOT build
    # 6.5.2.5 (a since-corrected claim this entry used to make): infra's pinned nixpkgs builds
    # zapzap-6.2.4 (`nix eval --raw <infra's nixpkgs flake ref>#zapzap.name`, 2026-08-03) —
    # nixpkgs tracks its own point in zapzap's history, not any specific upstream tag, and that
    # point moves independent of this table. The app_id claim above does not depend on which
    # version is actually pinned: setDesktopFileName's argument hasn't changed across the tags
    # checked here.
    dataPath = ".config/zapzap";
    appId = "com.rtosta.zapzap";
  };

  zoom = {
    # No official Arch repo package — confirmed against archlinux.org, 2026-08-03: no "zoom"
    # package in core/extra/multilib. AUR "zoom" (738 votes, maintainer edh, updated 2026-07) is a
    # repackage of Zoom's own vendor `.pkg.tar.xz` — Zoom ships no source at all, so unlike
    # Threema there is no from-source alternative to weigh against it; its PKGBUILD's `package()`
    # step is a literal `cp -dpr` of the downloaded vendor tree, confirmed by reading it.
    repo = null;
    aur = "zoom";
    # /usr/bin/zoom is a symlink to /opt/zoom/ZoomLauncher inside the vendor tree the AUR
    # package's package() step copies verbatim — confirmed by extracting the real vendor package
    # and reading it directly; this channel isn't installed via pacman on a live Arch host to
    # also check with pacman -Ql.
    binary = "zoom";
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
    # UNVERIFIED — neither method settled it; see the header. `StartupWMClass=zoom`, read from
    # two independent shipped .desktop files, is kept here as the best available placeholder —
    # it is exactly the X11-only field the header explains is unsound for Wayland, not a
    # confirmed value. Live: installed the Flathub build fresh on a live Arch host and ran it —
    # no window ever mapped in ~30s; the app and its two pulled-in runtimes were removed again
    # afterward. Source: the vendor binary is proprietary and stripped; it links the
    # QGuiApplication::setDesktopFileName symbol, but nothing confirms whether Zoom's own code
    # calls it, or with what string.
    dataPath = ".config/zoomus.conf";
    appId = "zoom";
  };
}
