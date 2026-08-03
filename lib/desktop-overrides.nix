#
# Per-app `.desktop` override data — ONLY for apps that need one. Real upstream desktop-entry
# content, read directly off a live host (a CachyOS laptop, 2026-08-03), not guessed. Every field
# here was copied from the actual installed `/usr/share/applications/<file>` — see the comment on
# each entry for exactly which file.
#
# WHY THIS EXISTS, SEPARATE FROM lib/catalogue.nix. catalogue.nix is install-identity data (which
# package, which channel) — genuinely the same shape for every app in the family. Desktop-entry
# metadata (Name/Icon/Exec/MimeType) is a different kind of fact, only needed for the handful of
# apps whose Wayland/data-dir behavior actually requires shadowing the system `.desktop` file (see
# modules/home.nix's header for why: confirmed live that Discord's own wrapper script has no
# flags-file support, and Signal/Element don't read one either — the `.desktop` override is the
# only reliable injection point for those three). Telegram and ZapZap are Qt-based, not Electron
# — nothing here applies to them, they need no override at all.
#
# `filename` MUST match the upstream basename exactly (not the catalogue key) — confirmed live
# these differ: Signal's real file is `signal.desktop` (not `signal-desktop.desktop`), Element's is
# `io.element.Element.desktop` (not `element-desktop.desktop`). Getting this wrong means the
# override sits next to the system entry instead of shadowing it — silently inert.
#
# `binary`/`argsSuffix` are split rather than one `exec` string so extra flags can be inserted
# between them at the right position (immediately after the binary, before any existing arguments
# — inserting after `%u`/`%U` would pass flags as if they were the URL argument).
#
{ ... }:
{
  discord = {
    # /usr/share/applications/discord.desktop
    filename = "discord.desktop";
    binary = "/usr/bin/discord";
    argsSuffix = "--url -- %u";
    name = "Discord";
    comment = "All-in-one voice and text chat for gamers that's free, secure, and works on both your desktop and phone.";
    genericName = "Internet Messenger";
    icon = "discord";
    categories = "Network;InstantMessaging;";
    mimeType = "x-scheme-handler/discord;";
    # Confirmed live by reading /usr/bin/discord: it's a bootstrap wrapper that downloads its own
    # Electron into ~/.config/discord/ and execs it — no flags-file support, argv is the only
    # reliable injection point. Bundles its own (often lagging) Electron version, so the
    # ELECTRON_OZONE_PLATFORM_HINT env var alone isn't guaranteed to be honored either.
    waylandFlags = [ "--ozone-platform=wayland" ];
  };

  signal = {
    # /usr/share/applications/signal.desktop
    filename = "signal.desktop";
    binary = "signal-desktop";
    argsSuffix = "-- %u";
    name = "Signal";
    comment = "Signal - Private Messenger";
    icon = "signal-desktop";
    categories = "Network;InstantMessaging;";
    mimeType = "x-scheme-handler/sgnl;x-scheme-handler/signalcaptcha;";
    # Confirmed does not read a flags file (signalapp/Signal-Desktop#5955).
    waylandFlags = [ "--ozone-platform-hint=auto" "--use-tray-icon" ];
  };

  element = {
    # /usr/share/applications/io.element.Element.desktop
    filename = "io.element.Element.desktop";
    binary = "/usr/bin/element-desktop";
    argsSuffix = "%u";
    name = "Element";
    comment = "Feature-rich client for Matrix";
    icon = "io.element.Element";
    categories = "Network;InstantMessaging;Chat;IRCClient";
    mimeType = "x-scheme-handler/element;x-scheme-handler/io.element.desktop;";
    # ⚠ Element's native-Wayland mode has open, acknowledged upstream bugs (element-desktop#728:
    # transparent window at startup, white screen joining Jitsi calls). Enabling this is a real
    # tradeoff, not a guaranteed clean win — test after activating.
    waylandFlags = [ "--ozone-platform=wayland" ];
  };

  teams = {
    # /opt/teams-for-linux/teams-for-linux ships its own /usr/share/applications entry, but
    # unlike the three above it does NOT need this mechanism for Wayland — confirmed live
    # (2026-08-03) via `ps aux`: its gpu-process already runs `--ozone-platform=wayland` with no
    # flags added, so its own startup code auto-detects the session type before Electron's
    # config.json is even read (matches upstream teams-for-linux#1675/#1604: config.json's
    # ozone-platform key is confirmed NOT to work, because Electron parses the real switch before
    # config.json loads — the app's own detection bypasses that entirely instead of fighting it).
    # Present here ONLY so `dataDir` relocation (an ordinary Electron --user-data-dir flag, not
    # Wayland-related) can reuse the same override mechanism without a second one.
    filename = "teams-for-linux.desktop";
    binary = "teams-for-linux";
    argsSuffix = "--gtk-version=3 %U";
    name = "Microsoft Teams for Linux";
    comment = "Unofficial Microsoft Teams client for Linux.";
    genericName = "Teams";
    icon = "teams-for-linux";
    categories = "Network;Chat;InstantMessaging;Application;";
    mimeType = "x-scheme-handler/msteams;";
    waylandFlags = [ ];
  };
}
