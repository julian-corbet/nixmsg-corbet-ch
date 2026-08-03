# studies

Written-up findings: things that were checked against a real source and are worth recording
properly, not just the result. See [`../experiments/`](../experiments/README.md) for what's still
open.

**Honesty check:** nothing here has been measured against a running deployment yet — this
catalogue has not been activated on any host as of this writing. What's recorded below is real
package-registry verification (checked against archlinux.org, the AUR, Flathub, and nixpkgs
directly), not a guess, but it is not the same claim as "this app runs correctly once installed."

## Table of contents

001. Four of the seven catalogue apps turned out to be official Arch repo packages, not AUR-only as assumed going in
002. `StartupWMClass` is the wrong field for a Wayland app-id, and produced two wrong catalogue values before this was caught

---

## 001 — Discord, Telegram, Signal, and Element are official Arch repo packages

**What was checked:** each catalogue entry's `repo`/`aur`/`flatpak`/`nixpkgs` identity was
verified directly — archlinux.org package search for official-repo status, the AUR for fallback
packages, `flatpak remote-ls flathub` for Flatpak IDs, and `nix search nixpkgs` for every
`nixpkgs` attribute (confirmed live, 2026-08-03: all 7 `nixpkgs` attributes resolve — see
`../experiments/validate-nixpkgs-names.nix`). Six of the seven `flatpak` IDs resolve against
Flathub this way; the seventh (threema) does not — see the `flatpakRemote` field and the
`threema` entry's own comment in `lib/catalogue.nix`.

**Finding:** going in, the assumption was that most of these apps would be AUR-only (the common
case for proprietary/community-wrapped Linux clients). Checked directly, four of the seven —
Discord, Telegram, Signal, Element — are in Arch's official `extra` repo, not AUR. Signal and
Element specifically moved into `extra` recently enough that an unverified assumption would have
gotten them wrong. Only Teams (`teams-for-linux`, unofficial wrapper — Microsoft ships no Linux
client at all), Threema (no official Linux distribution from Threema GmbH), and WhatsApp (no
official Linux client ever) are genuinely AUR/Flatpak-only, and that's a real property of those
three services, not a gap in Arch's package coverage.

**Why it mattered:** it changed the shape of a real design conversation — see the fleet's own
knowledge base for the Matrix-bridging discussion this fed into. Bridging Discord/Telegram/Signal
would have only ever bought a UX preference (unified inbox), never a maintenance-burden reduction,
once it was clear these three were trivial zero-maintenance native installs already.

**Status:** verified 2026-08-03 against live registries; re-check before citing if this file is
read much later — package-repo status moves (as this same finding demonstrates).

## 002 — `StartupWMClass` is the wrong field for a Wayland app-id

**What was checked:** `lib/catalogue.nix`'s `appId` field was originally sourced from each app's
`.desktop` file `StartupWMClass` key wherever a real `.desktop` file could be read. That key is
defined by freedesktop.org's Desktop Entry spec as matching the X11 `WM_CLASS` property — it says
nothing about a Wayland client's `xdg_toplevel` `app_id`, and nothing requires the two to be equal.

**Finding:** they weren't equal, twice, in this table specifically. Telegram's shipped `.desktop`
file declares `StartupWMClass=TelegramDesktop`, but the real running window (checked live via
`scrollmsg -t get_tree` on a live Arch host, 2026-08-03) advertises app_id
`"org.telegram.desktop"` — the desktop-file id, not the StartupWMClass string. ZapZap's shipped
`.desktop` file declares `StartupWMClass=zapzap`, but its own upstream Python source
(`zapzap/app/application.py`) explicitly calls
`app.setDesktopFileName('com.rtosta.zapzap')` — a different string entirely, and the one
`QGuiApplication`'s Wayland integration actually reads. Both wrong values had sat in the catalogue
presented as settled.

**What replaced it:** every entry was re-verified either live (`scrollmsg -t get_tree` against a
real running window, preferred whenever available) or by reading the specific mechanism each
toolkit actually uses — Qt/PyQt's `QGuiApplication::setDesktopFileName()`, Electron's
`app.setDesktopName()` (called automatically by Electron's own bootstrap from `package.json`'s
`desktopName` field, or overridable by the app's own code) — never StartupWMClass again. Two
entries (Threema's aur/nixpkgs channel, Zoom) could not be settled by either method and are marked
UNVERIFIED rather than left on a guess; see `../experiments/README.md` #002 and #005.

**Why it mattered:** a wrong `appId` doesn't fail a build — `nixmsg.pinnedAppIds`/`appIds` feed
straight into a compositor's window-rule syntax (nixscroll's `extraConfig`, niri's own
`match app-id=`), and a wrong string there produces a rule that silently matches nothing. The
failure is invisible until someone notices a workspace-pin or autostart placement never actually
takes effect.

**Status:** verified 2026-08-03, per-app method recorded in `lib/catalogue.nix`'s own header;
6 of 8 entries settled, 2 explicitly open (see the experiments entries above).
