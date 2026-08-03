# Experiments

Throwaway trials and the open-questions ledger — every entry below is a default, an inference, or
a "not yet" in `lib/catalogue.nix` or the modules that is reasoned, not measured against a real
running instance of the app. Results feed back into the catalogue as they close; a fully-closed
question moves out of this file into `../studies/README.md` instead of lingering here answered.

`validate-nixpkgs-names.nix` is the one exception that's a real, runnable check rather than a
question: `nix-instantiate --eval --strict experiments/validate-nixpkgs-names.nix -A missing`
confirms every catalogue entry's `nixpkgs` attribute actually resolves (currently: all 8 do) —
resolving is a weaker claim than being the RIGHT attribute, though: it would happily say "resolves"
for a wrong-but-existing attribute too. See `zoom`'s own comment in `lib/catalogue.nix` for why
that distinction mattered for real this time (`pkgs.zoom` resolves, and is not Zoom).

## Table of contents

002. Threema's aur/nixpkgs from-source build does not share the Flatpak repackage's app-id — confirmed different builds, the aur/nixpkgs side's real value is still open
003. `flatpak-install.nix` assumes `--system` scope is right for every consumer; untested against a `--user`-only host
004. The channel auto-resolution order (repo > aur > flatpak) has never been exercised against a host with `aurUser` unset
005. Zoom's Wayland app-id could not be settled by either live or source verification

---

## 002 — Threema's two builds do not share an app-id

**Question:** `lib/catalogue.nix`'s `threema` entry gives one `appId` for two independently-built
packages of different provenance — does the from-source AUR/nixpkgs build (`threema-desktop`, the
DEFAULT channel since threema has no `repo` entry) set the same Wayland app_id as the Flatpak
repackage of Threema GmbH's own proprietary binary?

**What's settled:** the two are confirmed to be genuinely different codebases, not just different
builds of the same one. The Flatpak build's app_id is LIVE-verified: launched on a live Arch host
(2026-08-03), where it's already linked and in daily use, `scrollmsg -t get_tree` reports app_id
`"Threema"`. The AUR/nixpkgs build is `threema-ch/threema-web-electron` (internal package name
`threema-consumer-web`), launched through the system's `electron37` package rather than a bundled
one — an older major version than the Electron 42.5.0 that settled `teams`'s entry in the same
catalogue, so that fallback-inference chain can't be assumed to carry over. Its source sets
neither `package.json`'s `desktopName` field nor calls `app.setDesktopName()` anywhere; it only
bakes a `StartupWMClass` into the generated `.deb`'s desktop file at package time
(`tools/packaging/package-deb.js`) — exactly the X11-only mechanism `lib/catalogue.nix`'s header
now explains is unsound for Wayland.

**Still open:** the AUR/nixpkgs build's real app_id. Not installed on any host checked so far;
`lib/catalogue.nix`'s `appId` field holds the Flatpak's confirmed value only, with an explicit
note that it should not be assumed to also cover this channel.

**Method:** install the AUR or nixpkgs build somewhere and check directly (`scrollmsg -t
get_tree` / `niri msg windows`), or read `electron37`'s own default-app_id fallback source (the
same technique that settled `teams`) if a live check isn't available first.

**Status:** open.

## 003 — `--system` Flatpak scope is asserted, not tested against every shape

**Question:** `modules/flatpak-install.nix` installs every flatpak-channel app at `--system`
scope unconditionally, reasoned (see that file's own header) as the right default for a
single-operator workstation with no per-user Flatpak wiring. Never tested against a host that
only has `flatpak --user` available (no root, or a shared multi-user box where `--system` isn't
wanted).

**Status:** open; not a blocker for any host this catalogue currently targets.

## 004 — Auto-resolution untested against `aurUser == null`

**Question:** `modules/nixmsg.nix`'s channel auto-resolution picks `aur` for `teams`/`threema`/
`whatsapp` whenever no explicit `channel` override is set (no `repo` value exists for any of the
three). On a host with `nixarch.packages.aurUser` unset, `nixarch`'s own reconciler skips the AUR
half with a warning — meaning these three apps would silently not install, with no signal from
`nixmsg` itself (only nixarch's own warning, which a consumer might not be watching).

**Hypothesis:** `nixmsg` could assert on this rather than rely on nixarch's warning to be seen,
but that would mean either reading a value from a different repo's option surface (a coupling this
family generally avoids — see nixdev's own "no inputs" stance) or duplicating nixarch's own
warning text. Left as nixarch's problem to signal, matching how nixdev handles the identical
situation for its own AUR-channel tools.

**Status:** open, low-severity (a loud warning already exists, just not from this repo).

## 005 — Zoom's Wayland app-id could not be settled

**Question:** what does the real Zoom client (either channel — AUR vendor repackage, or the
Flathub build) set as its Wayland app_id?

**What was tried:** live — installed the Flathub build (`us.zoom.Zoom`) fresh on a live Arch host
(2026-08-03) and ran it; no window was ever mapped in `scrollmsg -t get_tree` after ~30s (no
crash, no error beyond a harmless D-Bus warning). The app and its two pulled-in runtimes were
removed again afterward. Source — the AUR package is a literal `cp -dpr` of Zoom's own vendor
tree; no source exists to read. The vendor binary does link the
`QGuiApplication::setDesktopFileName` symbol, but is stripped, so nothing confirms whether Zoom's
own code calls it, or with what string.

**Current state:** `lib/catalogue.nix`'s `zoom.appId` is `"zoom"`, the `StartupWMClass` value —
kept as the best available placeholder, explicitly flagged there as unverified rather than
settled (this is the same field this catalogue's header explains is the wrong one to trust for a
Wayland app_id).

**Method:** get Zoom running long enough on a real Wayland session to map a window (interactively,
past whatever first-run/update step blocked the unattended launch attempted here) and check
directly.

**Status:** open.
