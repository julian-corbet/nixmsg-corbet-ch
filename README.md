# nixmsg

Messaging, both ends of it: the messenger apps — Discord, Telegram, Teams, Threema, Signal,
WhatsApp, Element, Zoom, Mumble — declared per host instead of hand-installed and forgotten, and
the servers they talk to declared into a cluster instead of hand-written as YAML.

The two planes are independent. Take the host half and never render a manifest; take the cluster
half and never install a client. They live together because they are one subject seen from its two
ends, and because a fact about a Matrix homeserver is not a fact about a Matrix client.

## What this is — the host plane

A platform-neutral catalogue (`lib/catalogue.nix`) naming each app's package identity on every
real distribution channel it actually has: an official Arch repo package, an AUR package, a
Flatpak, and a nixpkgs attribute. A selection resolves to a package NAME per channel, never a
role — "signal" is not "an encrypted messenger you might swap for another," it is the thing that
was asked for by name. Three backends consume it:

- **`modules/nixos.nix`** — installs via `environment.systemPackages`.
- **`modules/nixmsg.nix` itself, on system-manager** — publishes `nixmsg.archPackages` /
  `nixmsg.aurPackages` for the host's own pacman reconciler. There is no separate Arch backend:
  this module has no installer of its own on Arch (same as nixdev), so once the Flatpak installer
  moved out there was nothing platform-specific left for one to hold.
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
| `modules/nixos.nix` | The NixOS backend. There is no Arch one — see above. |
| `modules/home.nix` | Home-manager: autostart + workspace-pin. |
| `lib/servers.nix` | The server catalogue: what each cluster-side server IS — ports, the directories it writes, whether it runs its own database, how patient a probe must be. |
| `modules/cluster.nix` | The cluster translator: declares into the `nixk3s` app grammar and renders no Kubernetes object of its own. |
| `examples/all/values.nix` | A complete invented declaration of both servers, greenfield: every name is the catalogue's and every number is its default. |
| `examples/adopted/values.nix` | The same two servers declared against objects that ALREADY exist — every live name kept, every number this cluster's. The surface that decides whether the vocabulary can be adopted without a rollout. |
| `checks/` | `nix flake check` — eval-time proof of `flatpakApps` and the autostart commands, plus the cluster module's guards, the manifests they produce, and the adopted surface reproducing an object that already exists. |

## The cluster plane

`lib/servers.nix` catalogues the messaging SERVERS: Mattermost (team chat) and Tuwunel (a Matrix
homeserver). It holds only what is true of that software wherever anyone runs it — the ports, the
directories it writes and what kind of thing may back each one, whether it runs its own database,
how long a cold start may take before a probe calls it a failure. No address, no node, no
namespace, no uid and no secret appears anywhere in it; those are one deployment's facts and arrive
from a declaration.

`modules/cluster.nix` translates a declaration into the [nixk3s](https://github.com/julian-corbet/nixk3s-corbet-ch)
app grammar, which is what actually renders the Argo CD Application, Namespace, Deployment and
Service. This repository renders no Kubernetes object of its own; what it adds is the knowledge the
grammar cannot have.

```nix
nixmsg.servers.chat = {
  app = "mattermost";
  version = "10.0.0";
  namespace = "chat";
  createNamespace = true;
  exposure = "public";

  helperImage = "busybox@sha256:...";        # runs the ownership fix and the database wait
  database = { host = "postgres"; port = 5432; };
  state.data = { hostPath = "/srv/chat"; owner = { uid = 2000; gid = 2000; }; };
  secrets.chat-env.envFrom = true;

  resources = { cpuRequest = "200m"; memoryRequest = "512Mi"; memoryLimit = "2Gi"; };
  probeBudget.failureThreshold = 24;         # the catalogue's endpoint, this disk's patience
};
```

### The five things only a deployment can answer

Each of these looks at first like something a catalogue ought to know, and none of them is. They
exist because a workload that already runs has to be re-declarable in this vocabulary **without the
manifest moving** — both servers here declare durable state, which forces `Recreate`, so a changed
pod template is not a refactor but a stop-then-start: an outage for team chat, dropped inbound
federation for a homeserver.

| Term | What it answers | Why it is not knowledge |
|---|---|---|
| `resources.{cpu,memory}{Request,Limit}` | one cluster's share of a node | the same software is correctly sized at very different numbers on different hardware. Four named scalars, not a quantity map: nothing catalogued here burns a GPU, so nothing here can ask for one |
| `probeBudget.*` | how patient the probe is | the catalogue decides the probe's SHAPE — which endpoint, which port, whether to probe at all — and the budget is a fact about a disk. A budget given to a server the catalogue probes not at all is refused rather than promoted into a probe |
| `state.<name>.path` | where a projected credential lands | the software's requirement is that ONE named variable carry the file's path, not that the path be any particular string. The module renders that variable FROM the mount, so the location is written down exactly once |
| `state.<name>.volumeName`, `prestart.*.name` | what things are CALLED in a live pod | a volume name and a container name are part of the pod template rather than labels on it |
| `prestart.prepare.<name>.mountPath`, `prestart.databaseWait.notice` | what the helper steps do inside their own image | the helper image is the deployment's choice, so the path it mounts the tree at and the line it prints while waiting are the deployment's too |

WHETHER each of those happens at all still belongs to the catalogue: that a tree must be prepared,
that an engine must be waited for, that a credential arrives as a file, that this server is probed.
A declaration renames and retunes; it cannot add a step the catalogue did not ask for, and naming
one for a directory the catalogue does not prepare is an eval error.

The guards are the point. Backing a directory the server does not write, or leaving one it does
write unbacked, is an eval error. So is backing durable history with a Secret, or a projected
credential with a node path. So is omitting the database a server cannot start without, or the
environment variable it can never change afterwards. And so is telling any of them to idle: messaging
is a push medium, so a scaled-to-zero server does not delay the message that would have woken it, it
drops it — the catalogue records that as a property of the software and the module refuses on it.

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
