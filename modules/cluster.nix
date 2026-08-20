#
# nixmsg's cluster surface: declare which messaging SERVERS run in the cluster, and render them.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE DESIGN ──────────────────────────
#
# A sibling repository's whole subject is the app grammar: a workload declares WHAT IT NEEDS — an
# image, ports, an exposure class, which directories it writes and what backs them, what has to
# happen before it starts — and that grammar renders the Argo CD Application, the Namespace, the
# Deployment and the Service. Everything expressible in those terms is expressed in them: this
# module DEFINES INTO `nixk3s.apps` and renders no Kubernetes object of its own.
#
# So it is a translator. What it adds is the one thing the grammar cannot know: what these
# particular servers ARE. Which of them is its own database and which needs somebody else's; which
# can create the directory it writes and which will silently come up empty if it does; how patient
# a probe has to be; and — the fact the whole domain shares — that none of them may be told to
# sleep, because messaging is pushed rather than pulled.
#
# IMPORT THE GRAMMAR ALONGSIDE IT. `nixk3s.apps` is declared there, not here, and a render that
# composes this module without it fails with "the option `nixk3s.apps' does not exist".
#
# ── THE KNOWLEDGE/VALUE SPLIT, ENFORCED RATHER THAN TRUSTED ────────────────────────────────────
#
# `lib/servers.nix` holds what is true of the software anywhere. A declaration holds what is true of
# one cluster. Neither side can supply the other's half, and the guards below are what make that a
# property rather than a promise: the catalogue says a directory is written and what KIND of thing
# may back it, only a declaration can say what actually does, and a mismatch between the two — a
# database backed by a Secret, a password file backed by a node path — is an eval error rather than
# a workload that starts and behaves strangely.
#
# ── WHY THERE IS NO SHARED NAMESPACE DEFAULT ───────────────────────────────────────────────────
#
# The sibling repository this module's shape is copied from defaults every workload into one
# namespace, because a developer's small tools genuinely share a fate. These do not. A team chat
# server and a Matrix homeserver have separate data, separate outages and separate audiences;
# putting them in one namespace means one bad manifest or one prune slip reaches both. So
# `namespace` is required per workload and defaulted nowhere — forgetting it fails eval, which is
# the honest outcome for a question this repository cannot answer on a consumer's behalf.
{ config, lib, ... }:

let
  cfg = config.nixmsg;
  platform = cfg.clusterPlatform;
  catalogue = (import ../lib/servers.nix { }).servers;

  declared = lib.filterAttrs (_: w: w.enable) cfg.servers;
  workloads = lib.mapAttrsToList (name: w: { inherit name w; entry = catalogue.${w.app}; }) declared;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks like.
  # The catalogue carries neither: a version is a deployment's choice and a digest is one
  # deployment's proof of what it is running.
  imageOf = entry: w: if w.image != null then w.image else "${entry.image}:${w.version}";

  portsOf = entry: lib.mapAttrs (_: number: { inherit number; }) entry.ports;

  # The filename a secret-backed volume projects, which is the basename the catalogue chose when it
  # decided the path the software reads. Taken from the mount rather than restated, so the two
  # cannot drift apart into a subPath that names a file the volume does not carry.
  projectedFileOf = spec: (lib.head spec.mounts).subPath;

  # THE SPLIT IN ONE FUNCTION: WHERE inside the container, and WHAT KIND of thing may back it, come
  # from the catalogue; WHAT ACTUALLY BACKS IT comes from the declaration.
  #
  # Two things are decided here rather than being offered as a choice. Every durable node path gets
  # the strict `Directory` form, because every server in this catalogue keeps a conversation history
  # and one that comes up against a freshly created empty directory has not failed to start, it has
  # silently become a different server. And a prepared volume on a CLAIM hands ownership to the
  # kubelet, which is the mechanism that exists for exactly that and does not exist for node paths —
  # those get a preparation step instead, below.
  # Keys the catalogue does not know are dropped rather than looked up: naming one is refused by an
  # assertion below, and an assertion is only reached by a module that did not throw first.
  catalogued = entry: w: lib.filterAttrs (key: _: entry.state ? ${key}) w.state;

  stateOf = entry: w:
    lib.mapAttrs
      (key: backing:
        let spec = entry.state.${key}; in
        { inherit (spec) mounts readOnly; }
        // (if spec.backing == "secret"
        then
          lib.optionalAttrs (backing.secret != null)
            {
              secret = backing.secret;
              items = { ${backing.key} = projectedFileOf spec; };
            }
        else
          { inherit (backing) claim hostPath; }
          // lib.optionalAttrs (backing.hostPath != null) { hostPathType = "Directory"; }
          // lib.optionalAttrs (spec.prepare && backing.claim != null) { ownership = "kubelet"; }))
      (catalogued entry w);

  # Node paths this workload writes that the software cannot take ownership of, and that a
  # declaration has answered with an owner. Both halves of the filter matter: the catalogue decides
  # THAT a tree needs preparing, the declaration decides WHO owns it, and a missing answer is
  # refused by an assertion rather than rendered as a step that chowns to nothing.
  preparedPaths = entry: w:
    lib.filterAttrs
      (key: backing:
        (entry.state.${key}).prepare && backing.hostPath != null && backing.owner != null)
      (catalogued entry w);

  # Init containers, IN ORDER, because the kubelet runs them in sequence and that order is the
  # semantics rather than a rendering detail: fix what the process cannot fix for itself, then wait
  # for what it cannot start without.
  #
  # Both are rendered only when the workload named a tool image to run them with. That image is a
  # deployment's choice — this repository has no business naming a busybox — so its absence is an
  # assertion below rather than a default nobody chose.
  initOf = entry: w:
    lib.optionals (w.helperImage != null) (
      lib.mapAttrsToList
        (key: backing: {
          name = "prepare-${key}";
          image = w.helperImage;
          command = [
            "sh"
            "-c"
            "chown -R ${toString backing.owner.uid}:${toString backing.owner.gid} /state"
          ];
          mounts.${key} = [{ mountPath = "/state"; }];
        })
        (preparedPaths entry w)
      ++ lib.optional (entry.externalDatabase && w.database != null) {
        name = "wait-for-database";
        image = w.helperImage;
        command = [
          "sh"
          "-c"
          "until nc -z ${w.database.host} ${toString w.database.port}; do echo waiting-for-database; sleep 2; done"
        ];
      }
    );

  # Secrets are NAMED and never carried. Nothing in this repository can express a secret's content,
  # which is what makes a declaration written against this module safe to publish even when the
  # Secret it names is not.
  secretsOf = w:
    lib.mapAttrs
      (name: s: {
        secret = if s.secret != null then s.secret else name;
        inherit (s) envFrom env;
      })
      w.secrets;

  envOf = entry: w: entry.env // w.env;

  # Variable names this workload supplies from individual Secret keys. A required variable satisfied
  # this way is satisfied: what the software needs is the variable, not a particular way of getting
  # its value into the process.
  secretEnvNames = w: lib.concatMap (s: lib.attrNames s.env) (lib.attrValues w.secrets);

  probesOf = entry:
    lib.optionalAttrs (entry.readiness != null) {
      readiness = { port = entry.primaryPort; } // entry.readiness;
    };

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op.
  addressingOf = w:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      inherit (w) slot;
    };

  mkApp = x:
    let inherit (x) entry w; in
    {
      inherit (w) namespace createNamespace project exposure scaling;
      image = imageOf entry w;
      ports = portsOf entry;
      state = stateOf entry w;
      secrets = secretsOf w;
      env = envOf entry w;
      args = entry.args ++ w.args;
      probes = probesOf entry;
      init = initOf entry w;
    }
    // lib.optionalAttrs (w.identity != null) { inherit (w) identity; }
    // addressingOf w;

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  # The catalogue checking itself. Every other guard here reads a declaration against the catalogue;
  # this one reads the catalogue against the model, so that an entry which cannot be translated is
  # caught where it is written rather than by whoever first declares it. A secret-backed volume whose
  # single mount has no subPath is the specific failure: the projection and the mount would then
  # disagree about the filename, and the software would find a directory where it expected a file.
  catalogueAssertions = lib.concatMap
    (x:
      let inherit (x) entry w; in
      lib.mapAttrsToList
        (key: spec: {
          assertion =
            spec.backing != "secret"
            || (lib.length spec.mounts == 1 && (lib.head spec.mounts).subPath != null);
          message =
            "nixmsg: catalogue entry `${w.app}` declares `state.${key}` as secret-backed, and a "
            + "secret-backed volume must have exactly ONE mount carrying a subPath. The subPath is the "
            + "filename the key is projected under; without it the mount covers a directory and the "
            + "software reads a directory where it expects a file.";
        })
        entry.state)
    workloads;

  stateAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixmsg: server `${name}` must back every directory it writes, and backs "
            + (if w.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else
              lib.concatStringsSep ", "
                (lib.mapAttrsToList (k: spec: "`${k}` at ${(lib.head spec.mounts).mountPath}") entry.state))
            + ".";
        }

        {
          assertion = lib.all
            (key:
              let backing = w.state.${key}; in
              lib.length (lib.filter (b: b != null) [ backing.claim backing.hostPath backing.secret ]) == 1)
            (lib.attrNames (catalogued entry w));
          message =
            "nixmsg: server `${name}` must back each directory with EXACTLY ONE of an existing claim, a "
            + "node path or an existing Secret — never two and never none. A directory with no backing is "
            + "a pod's own filesystem, which is discarded on the restart this workload's own database "
            + "guarantees.";
        }

        {
          # The KIND has to match, and this is the guard the whole `backing` field exists for. Both
          # directions are real failures rather than tidiness: a conversation history on a Secret is a
          # read-only tmpfs the server cannot write, and a bind password on a node path is a
          # credential lying in a directory somebody backs up.
          assertion = lib.all
            (key:
              let
                backing = w.state.${key};
                spec = entry.state.${key};
              in
              if spec.backing == "secret"
              then backing.secret != null && backing.key != null
              else backing.secret == null && backing.key == null)
            (lib.attrNames (catalogued entry w));
          message =
            "nixmsg: server `${name}` backs a directory with the wrong KIND of thing. The catalogue says "
            + "which of its directories are durable state and which are keys projected out of a Secret; a "
            + "durable one backed by a Secret is a history the server cannot write, and a projected one "
            + "backed by a claim or a node path is a credential on somebody's storage. A secret-backed "
            + "volume needs both `secret` and `key`.";
        }

        {
          assertion = lib.all
            (key:
              let
                backing = w.state.${key};
                spec = entry.state.${key};
              in
              !(spec.prepare && backing.hostPath != null) || backing.owner != null)
            (lib.attrNames (catalogued entry w));
          message =
            "nixmsg: server `${name}` writes a directory its own image cannot take ownership of, backed by "
            + "a node path, and names no owner. A node path comes back owned by root after a restore and "
            + "`fsGroup` is not applied to one at all, so nothing else will fix it — the process starts, "
            + "cannot create its own files, and fails in a way that reads as a bad command rather than a "
            + "permission denial.";
        }
      ])
    workloads;

  needsInit = x: preparedPaths x.entry x.w != { } || (x.entry.externalDatabase && x.w.database != null);

  dependencyAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = !entry.externalDatabase || w.database != null;
          message =
            "nixmsg: server `${name}` does not run its own database and no database was named. It opens the "
            + "engine at start and gives up after a few failed attempts rather than retrying, so a cluster "
            + "that restarts both together crash-loops this one for no reason of its own. Naming the engine "
            + "is what lets a wait be rendered in front of it.";
        }

        {
          assertion = !entry.secretEnv || lib.any (s: s.envFrom) (lib.attrValues w.secrets);
          message =
            "nixmsg: server `${name}` takes its whole configuration surface as credentials and no Secret is "
            + "loaded into its environment. The values it needs cannot be written in a rendered tree, so a "
            + "declaration that supplies none has not configured it — it has arranged for it to start "
            + "unconfigured.";
        }

        {
          assertion = lib.all
            (v: (envOf entry w) ? ${v} || lib.elem v (secretEnvNames w))
            entry.requiredEnv;
          message =
            "nixmsg: server `${name}` is missing an environment variable it cannot start without ("
            + lib.concatMapStringsSep ", "
              (v: "`${v}`")
              (lib.filter (v: !((envOf entry w) ? ${v}) && !(lib.elem v (secretEnvNames w))) entry.requiredEnv)
            + "). The catalogue lists these by name because a default would be a guess at somebody's own "
            + "domain or directory, and the guess is not correctable later.";
        }

        {
          assertion = !(needsInit x) || w.helperImage != null;
          message =
            "nixmsg: server `${name}` needs something done before its process starts — a tree prepared, an "
            + "engine waited for — and names no image to do it with. WHICH small tool image performs that "
            + "step is a deployment's choice, and pinning it by digest is what keeps two syncs of an "
            + "identical rendered tree running identical code.";
        }
      ])
    workloads;

  # THE DOMAIN'S SHARED FACT, enforced. Every entry in this catalogue carries `mayIdle = false` for
  # the same reason, and it is not a preference a deployment gets to overrule: a scaled-to-zero
  # messaging server does not delay the message that would have woken it, it drops it. This is a
  # refusal rather than a warning precisely because there is no wake front that could make it right.
  idleAssertions = map
    (x:
      let inherit (x) name w entry; in
      {
        assertion = entry.mayIdle || w.scaling == "always";
        message =
          "nixmsg: server `${name}` is declared `scaling = \"${w.scaling}\"`, and this one may not idle. "
          + "Messaging is a push medium: work arrives from outside — a federated event, a websocket frame, "
          + "a mobile poll — whether or not anybody has just opened a tab. At zero replicas the request "
          + "that would have woken it is the request that was supposed to be delivered.";
      })
    workloads;

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not a
  # merge, it is two Namespace objects Argo will fight over.
  anchorAssertions =
    let
      anchors = lib.filter (x: x.w.createNamespace) workloads;
      byNs = lib.groupBy (x: x.w.namespace) anchors;
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixmsg: namespace `${ns}` is anchored by ${toString (lib.length xs)} servers ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one workload may create a namespace.";
      })
      byNs;

  slotAssertions =
    let
      claimed = lib.filter (x: x.w.slot != null) workloads;
      bySlot = lib.groupBy (x: toString x.w.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixmsg: slot ${slot} is claimed by ${toString (lib.length xs)} servers ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two workloads on one number is "
          + "two workloads on one address.";
      })
      bySlot;

  # A warning is `{ when; message; }` — the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  warnings = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          # NOT a refusal, because the fix is real and lives one layer down. An init container has no
          # identity of its own in this vocabulary — a per-container uid is a GRANT relative to the pod
          # — so the step that chowns the tree inherits the identity that cannot chown it. Somebody has
          # to grant it uid 0 on the rendered object, on purpose, where it can be counted.
          when = w.identity != null && preparedPaths entry w != { };
          message =
            "nixmsg: server `${name}` runs as a named identity AND prepares a node path it does not own. "
            + "The preparing step inherits the pod's identity, so as declared it cannot chown a tree that "
            + "is owned by somebody else — grant that one container uid 0 on the rendered object. This "
            + "vocabulary has no term for it by construction: a per-container identity grants rather than "
            + "restricts.";
        }
        {
          when = w.slot != null && platform.origin == null;
          message =
            "nixmsg: server `${name}` claims slot ${toString w.slot}, and `nixmsg.clusterPlatform.origin` "
            + "is unset — so the number is checked for collisions inside this repository and by nothing "
            + "for which RANGE it may come from.";
        }
      ])
    workloads;

  ownerOptions = lib.types.submodule {
    options = {
      uid = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "Numeric user id that must own the tree. A fleet fact; nothing here has a default for one.";
      };
      gid = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "Numeric group id that must own the tree.";
      };
    };
  };

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        Namespace this server lands in. REQUIRED and defaulted nowhere — see the header: these
        servers do not share a fate, so a shared default would be a decision this repository is not
        entitled to make on a consumer's behalf.
      '';
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its namespace. Defaults to false because a namespace usually
        outlives whatever first put a workload in it; exactly one workload may own one.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixmsg.clusterPlatform.project";
      description = "Delivery project this workload's Application belongs to.";
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address — the
        layers underneath map it into however many address spaces the fleet keeps, which is why
        nothing here moves one. The VALUE is a fleet fact and belongs to the consumer.
      '';
    };

    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        Who can reach it, as a CLASS rather than an address. Defaults to the closed answer: a server
        nobody has thought about is not on the internet. A homeserver that federates needs the open
        one, and that is a decision somebody makes rather than inherits.
      '';
    };

    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = ''
        Whether the workload may idle to zero replicas.

        Every server this repository catalogues answers no, for one reason: messaging is pushed, not
        pulled. The value is still writable so that the refusal is a stated guard with a message
        rather than an option nobody can find — and there is deliberately no `wake` term beside it,
        because a wake front for a workload that may not sleep would be an answer to a question this
        catalogue never asks.
      '';
    };

    identity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        WHICH IDENTITY this server runs as, named as a ROLE rather than a number. "It runs as an
        unprivileged user" is a fact about the software; which unprivileged user is a fact about the
        fleet, so the name is passed through to whatever resolves it and no number appears here.
      '';
    };

    helperImage = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The small tool image that runs this workload's preparation and wait steps — a shell, a
        `chown`, an `nc`. Required whenever the catalogue says something has to happen before the
        process starts, and defaulted nowhere: naming a particular busybox is a deployment's choice,
        and pinning it by digest is what keeps two syncs of an identical tree running identical code.
      '';
    };

    database = lib.mkOption {
      default = null;
      description = ''
        WHERE the SQL engine this server needs can be reached, for the servers the catalogue says do
        not run one. Required for those and meaningless for the rest.

        A NAME, never an address: the guard underneath refuses an address literal anywhere in a
        rendered command, which is not pedantry — an engine reached by IP is one that cannot be moved
        without editing every app that talks to it.
      '';
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "DNS name of the engine. Waited for before the server's own process starts.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "Port the engine accepts connections on. No default: which engine it is decides it.";
          };
        };
      });
    };

    state = lib.mkOption {
      default = { };
      description = ''
        What backs each directory the catalogue says this server writes, keyed by the SAME names.
        Backing a directory the server does not write, leaving one it does write unbacked, or backing
        one with the wrong KIND of thing is an eval error rather than a surprise at runtime.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          claim = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "An existing PersistentVolumeClaim, by name. Nothing here creates one.";
          };
          hostPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              A directory on the node. Pins the workload to whichever node holds it, and is always
              mounted in the form that REFUSES to start on a missing directory — see the module
              header for why an empty one is worse than no start at all.
            '';
          };
          secret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              An existing Secret, by name, for the volumes the catalogue says are a projected key
              rather than durable state. Named and never carried.
            '';
          };
          key = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              WHICH key of that Secret this volume projects. Required beside `secret` and refused
              without it: projecting every key would put unrelated credentials on a tmpfs inside the
              container, invisibly, because the mount looked narrow.
            '';
          };
          owner = lib.mkOption {
            type = lib.types.nullOr ownerOptions;
            default = null;
            description = ''
              WHO must own this tree, for the directories the catalogue says the image cannot take
              ownership of itself. Required when such a directory is backed by a node path, because
              that is the case nothing else fixes.
            '';
          };
        };
      });
    };

    secrets = lib.mkOption {
      default = { };
      description = ''
        Secrets this workload consumes, keyed by a local name. Each entry says HOW: the whole Secret
        loaded into the environment, or named keys bound to named variables — the two forms exist
        because the servers here genuinely use both, one holding a configuration surface that is
        credentials end to end and the other needing two specific values out of one Secret.

        Named rather than carried: nothing in this repository can hold a secret's contents, which is
        what makes a declaration written here publishable.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          secret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The Secret's own name. Defaults to the local name it is keyed by.";
          };
          envFrom = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Load every key in the Secret into the environment.";
          };
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Individual keys bound to variables, as `<VARIABLE> = \"<key in the Secret>\"`.";
          };
        };
      });
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Environment this deployment adds, merged over whatever the catalogue sets. Values only —
        anything secret belongs in a Secret and arrives through `secrets`.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to whatever the catalogue sets.";
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A whole image reference, overriding the catalogue's repository and this workload's version.
        This is where a digest pin goes, and pinning by digest is what makes two syncs of an identical
        rendered tree run identical code — which matters more here than usual, because both servers
        catalogued migrate their own schema when the version moves.
      '';
    };
  };
in
{
  options.nixmsg.clusterPlatform = {
    project = lib.mkOption {
      type = lib.types.str;
      default = "chat";
      description = "Delivery project these servers' Applications belong to unless a declaration says otherwise.";
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        THE IDENTITY THIS REPOSITORY'S SERVERS ARE ADDRESSED UNDER, when the render composes the band
        model. A repository naming itself is not a fleet fact; which band that name binds is, and it
        lives in whatever repository owns the fleet. Left null, slots are still checked for collisions
        here and by nothing for range.
      '';
    };
  };

  options.nixmsg.servers = lib.mkOption {
    default = { };
    description = ''
      The messaging servers that run in the cluster, keyed by a name of your choosing.

      THE ENUM IS THE HOUSE RULE. It is built from `lib/servers.nix`, so a server this repository
      does not catalogue is not a refused value here — it is not a value at all. What belongs in that
      catalogue is software whose job is carrying messages between people; the clients that read
      those messages are the other file's subject.
    '';
    example = lib.literalExpression ''
      {
        example-homeserver = {
          app = "tuwunel";
          version = "0.0.0";
          namespace = "example-matrix";
          createNamespace = true;
          exposure = "public";
          env.TUWUNEL_SERVER_NAME = "example.com";
          state.database.hostPath = "/example/state/homeserver";
          state.ldap-password = { secret = "example-homeserver-secrets"; key = "example-bind-password"; };
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = commonOptions // {
        app = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue);
          description = "Which server, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue)}.";
        };

        version = lib.mkOption {
          type = lib.types.str;
          description = "Which version this workload runs, used as the image tag. Required, and defaulted nowhere.";
        };
      };
    }));
  };

  # ── Computed, read-only ───────────────────────────────────────────────────────────────────────
  options.nixmsg.clusterSlots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name x.w.slot) (lib.filter (x: x.w.slot != null) workloads));
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Nothing is rendered from it here: what an address looks
      like is the private layer's business, and this is what that layer reads to build one.
    '';
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);
    nixidy.assertions =
      catalogueAssertions
      ++ stateAssertions
      ++ dependencyAssertions
      ++ idleAssertions
      ++ anchorAssertions
      ++ slotAssertions;
    nixidy.warnings = warnings;
  };
}
