# Experiments

Throwaway trials and the open-questions ledger — every entry below is a default, an inference, or
a "not yet" in `lib/catalogue.nix` or the modules that is reasoned, not measured against a real
running instance of the app. Results feed back into the catalogue as they close.

`validate-nixpkgs-names.nix` is the one exception that's a real, runnable check rather than a
question: `nix-instantiate --eval --strict experiments/validate-nixpkgs-names.nix -A missing`
confirms every catalogue entry's `nixpkgs` attribute actually resolves (currently: all 8 do) —
resolving is a weaker claim than being the RIGHT attribute, though: it would happily say "resolves"
for a wrong-but-existing attribute too. See `zoom`'s own comment in `lib/catalogue.nix` for why
that distinction mattered for real this time (`pkgs.zoom` resolves, and is not Zoom).

## Table of contents

001. Three catalogue entries' Wayland app-ids (teams, threema, whatsapp) are inferred from the desktop-file/Flatpak-id naming convention, not observed on a running window
002. Threema's AUR/nixpkgs from-source build and its Flatpak repackage may not share the same app-id
003. `flatpak-install.nix` assumes `--system` scope is right for every consumer; untested against a `--user`-only host
004. The channel auto-resolution order (repo > aur > flatpak) has never been exercised against a host with `aurUser` unset

---

## 001 — Three app-ids are inferred, not observed

**Question:** `discord`/`telegram`/`signal`/`element`'s `appId` values were corroborated against
upstream source or established compositor window-rule examples. `teams`, `threema`, and
`whatsapp`'s were not — they're inferred from the .desktop-file-basename-equals-app-id convention
(true for most well-behaved Electron/Flatpak apps, not guaranteed for every Qt/QtWebEngine
wrapper).

**Method:** once each app is actually installed, `niri msg windows` (or the scroll/sway
equivalent) against a running instance settles it directly.

**Status:** open.

## 002 — Threema's two builds may not share an app-id

**Question:** `lib/catalogue.nix`'s `threema` entry gives both `aur`/`nixpkgs` (a from-source
Electron build) and `flatpak` (an unofficial repackage of Threema's own proprietary binary) the
same `appId`. These are two independently-built packages of different provenance; nothing confirms
they set the same `StartupWMClass`.

**Method:** compare directly once both are installed somewhere, or accept per-channel
`appId` divergence in the schema if it turns out to matter for a workspace-pin rule.

**Status:** open, and moot for any host that only ever runs one channel of the two.

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
