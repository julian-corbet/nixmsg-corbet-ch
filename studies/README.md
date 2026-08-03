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
