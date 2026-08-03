# nixmsg

Messenger apps — Discord, Telegram, Teams, Threema, Signal, WhatsApp, Element, Zoom — declared per
host instead of hand-installed and forgotten.

## What this is

A platform-neutral catalogue (`lib/catalogue.nix`) naming each app's package identity on every
real distribution channel it actually has: an official Arch repo package, an AUR package, a
Flatpak, and a nixpkgs attribute. A selection resolves to a package NAME per channel, never a
role — "signal" is not "an encrypted messenger you might swap for another," it is the thing that
was asked for by name. Three backends consume it:

- **`modules/nixos.nix`** — installs via `environment.systemPackages` + the Flatpak-channel
  oneshot.
- **`modules/arch.nix`** — publishes `nixmsg.archPackages` / `nixmsg.aurPackages` for the host's
  own pacman reconciler (this module has no installer of its own on Arch, same as nixdev), plus
  the same Flatpak-channel oneshot.
- **`modules/home.nix`** — home-manager: autostart commands and workspace-pin app-ids, both
  compositor-agnostic. Autostart feeds `nixdesktop.startup`'s existing self-splicing contract;
  workspace-pin only resolves app-ids, never compositor syntax — writing the actual window rule
  stays the consuming compositor module's job.

## Why three channels, not two

Several of these apps have no official-repo or even AUR-native build at all (Teams, WhatsApp), and
one (Threema) has a real case for keeping an already-linked Flatpak identity rather than switching
builds — messenger accounts are usually tied to an interactive link/login step (a QR scan, a phone
code) that no package manager can redo for you, so an operator who already has a working linked
session gets to say so per host:

```nix
nixmsg.apps.threema.enable = true;
nixmsg.apps.threema.channel = "flatpak"; # keep the existing linked session; default would be AUR
```

Left unset, `channel` auto-resolves to the best available channel (repo > aur > flatpak).

## What this does not own

- **Compositor window-rule / workspace-pin syntax.** `nixscroll`/`nixniri` translate resolved
  intent into their own config language — this module only computes *which* app-ids belong in
  such a rule.
- **The interactive account-linking step itself.** No package manager can automate a QR scan or a
  phone-number code. What this module can do: keep an app's data directory in a stable, backed-up
  location so a rebuilt host doesn't force a re-link, and get out of the way of Secret-Service
  keyring integration (oo7) for the apps that use it.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules`/`systemManagerModules`/`homeManagerModules` outputs, `lib.catalogue`. |
| `lib/catalogue.nix` | The app catalogue: one entry per app, with its repo/aur/flatpak/nixpkgs identity and Wayland app-id. |
| `modules/nixmsg.nix` | Platform-neutral options + channel resolution. |
| `modules/nixos.nix`, `modules/arch.nix` | Platform backends. |
| `modules/flatpak-install.nix` | Shared Flatpak-channel installer (systemd oneshot), imported by both backends. Remote-aware — installs each app from whichever remote its catalogue entry actually names, not just Flathub. |
| `modules/home.nix` | Home-manager: autostart + workspace-pin. |
| `checks/` | `nix flake check` — eval-time proof of `flatpakApps`/`flatpak-install.nix`'s rendering. |

## Platform support

**NixOS:** Full — repo/nixpkgs-resolvable apps via `environment.systemPackages`, flatpak-channel
apps via the shared oneshot.

**Arch / CachyOS (via system-manager):** Publishes package-name lists for a host's own reconciler
(e.g. `nixarch.packages.pacman = config.nixmsg.archPackages;`), plus the same Flatpak oneshot.

## Related projects

Part of the same independently-usable NixOS module family:
[nixdev](https://github.com/julian-corbet/nixdev-corbet-ch) (the same catalogue-and-resolve
pattern, for CLI tooling), [nixarch](https://github.com/julian-corbet/nixarch-corbet-ch) (the Arch
package reconciler this module's Arch backend feeds), [nixdesktop](https://github.com/julian-corbet/nixdesktop-corbet-ch)
(the session/startup contract `modules/home.nix` writes into), and
[nixpush](https://github.com/julian-corbet/nixpush-corbet-ch) (provider-agnostic notification
*sending* — a different problem: nixpush delivers alerts you generate, nixmsg installs the clients
you read other people's messages in).

## License

MIT License &copy; 2026 Julian Corbet
