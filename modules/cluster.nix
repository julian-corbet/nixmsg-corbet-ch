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
# THE SIX QUESTIONS ONLY A DECLARATION CAN ANSWER, listed once here because each of them looks at
# first like something a catalogue ought to know:
#
#   1. HOW MUCH CPU AND MEMORY (`resources`). A request is a claim on one cluster's hardware next to
#      whatever else it runs.
#   2. HOW PATIENT THE PROBE IS (`probeBudget`). The catalogue decides the probe's shape — which
#      endpoint, which port, whether to probe at all — and a budget is a fact about a disk.
#   3. WHERE A PROJECTED CREDENTIAL LANDS (`state.<name>.path`). The software's requirement is that
#      one named variable carry the file's path, not that the path be any particular string; the
#      module renders the variable FROM the mount so the two cannot disagree.
#   4. WHAT THINGS ARE CALLED IN A LIVE POD (`state.<name>.volumeName`, `prestart.*.name`). A volume
#      name and a container name are part of the pod template rather than labels on it, so a workload
#      adopted from an object that already exists has to be able to keep the names it has — renaming
#      one is a new template hash, which for these servers is an outage rather than a rename.
#   5. WHAT THE HELPER STEPS DO INSIDE THEIR OWN IMAGE (`prestart.prepare.<name>.mountPath`,
#      `prestart.databaseWait.notice`). The helper image is the deployment's choice, so the paths and
#      the log line inside it are too.
#   6. WHETHER THESE OBJECTS ALREADY EXIST (`adopt`). Not a fact about the pod at all — a fact about
#      one cluster's history, and the only reason it is a question is that the answer changes the
#      rendered Application: adopting one renders server-side apply and diff so Argo compares against
#      what the API server holds. The same server is adopted on the cluster that has run it for years
#      and created fresh on the one standing up beside it.
#
# None of the six is a passthrough of a nested attrset: each is a named scalar the module reads and
# renders somewhere specific, and the catalogue still decides WHETHER each thing happens at all.
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

  # THE NAME THE VOLUME CARRIES IN THE RENDERED POD. The catalogue's key for it by default, which is
  # what a workload declared from scratch wants and what keeps the two names from drifting. A
  # workload ADOPTED from an object that already exists overrides it, because a volume name is part
  # of the pod template: renaming one is not a rename, it is a new template hash and therefore a
  # restart of a server that stops before it starts again.
  volumeNameOf = key: backing: if backing.volumeName != null then backing.volumeName else key;

  # WHERE THE MOUNTS GO. For durable state the catalogue knows every path, because those paths are
  # the image's own and an image does not change its mind about them. For a projected credential it
  # knows none of them: a declaration says where the file lands, and the filename the key is
  # projected under is that path's BASENAME rather than a second answer to the same question — two
  # spellings of one path is exactly where a mount and a subPath disagree and the software reads a
  # directory where it expected a file.
  mountsOf = spec: backing:
    if spec.backing == "secret"
    then [{ mountPath = backing.path; subPath = baseNameOf backing.path; }]
    else spec.mounts;

  # The names of the steps that run before the process does, when a declaration does not rename
  # them. Written once here because both the option's own default and the fallback for a step no
  # declaration mentions have to be the same string, and two literals is where they stop being.
  defaultPrepareName = key: "prepare-${key}";
  defaultPrepareMountPath = "/state";
  prepareStepOf = w: key:
    if w.prestart.prepare ? ${key}
    then w.prestart.prepare.${key}
    else { name = defaultPrepareName key; mountPath = defaultPrepareMountPath; };

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
    lib.mapAttrs'
      (key: backing:
        let spec = entry.state.${key}; in
        lib.nameValuePair (volumeNameOf key backing) (
          { inherit (spec) readOnly; }
          // (if spec.backing == "secret"
          then
            lib.optionalAttrs (backing.secret != null && backing.key != null && backing.path != null)
              {
                mounts = mountsOf spec backing;
                secret = backing.secret;
                items = { ${backing.key} = baseNameOf backing.path; };
              }
          else
            { inherit (backing) claim hostPath; inherit (spec) mounts; }
            // lib.optionalAttrs (backing.hostPath != null) { hostPathType = "Directory"; }
            // lib.optionalAttrs (spec.prepare && backing.claim != null) { ownership = "kubelet"; })
        ))
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
        (key: backing:
          let step = prepareStepOf w key; in
          {
            inherit (step) name;
            image = w.helperImage;
            command = [
              "sh"
              "-c"
              "chown -R ${toString backing.owner.uid}:${toString backing.owner.gid} ${step.mountPath}"
            ];
            mounts.${volumeNameOf key backing} = [{ inherit (step) mountPath; }];
          })
        (preparedPaths entry w)
      ++ lib.optional (entry.externalDatabase && w.database != null) {
        inherit (w.prestart.databaseWait) name;
        image = w.helperImage;
        command = [
          "sh"
          "-c"
          ("until nc -z ${w.database.host} ${toString w.database.port}; "
          + "do echo ${w.prestart.databaseWait.notice}; sleep 2; done")
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

  # VARIABLES THE MODULE DERIVES RATHER THAN TAKES. For every projected credential whose catalogue
  # entry names the variable that must carry its path, that variable IS the mount path — computed
  # from the same value the volume is mounted at rather than written down a second time. A file
  # mounted at one path and a process told about another is an authentication failure with nothing
  # visibly wrong in the manifest, and it is the exact failure two independent strings produce.
  pathEnvOf = entry: w:
    lib.listToAttrs (lib.concatMap
      (key:
        let spec = entry.state.${key}; in
        lib.optional (spec ? pathEnv && w.state.${key}.path != null)
          (lib.nameValuePair spec.pathEnv w.state.${key}.path))
      (lib.attrNames (catalogued entry w)));

  envOf = entry: w: entry.env // w.env // pathEnvOf entry w;

  # ONE CLUSTER'S SHARE OF ITS HARDWARE. Four named scalars rather than the schema's free-form
  # quantity map, and the narrowness is the point: nothing this repository catalogues burns a GPU or
  # any other extended resource, so a surface that could ask for one would be a surface that lets a
  # chat server claim a card. What is left is what a messaging server actually competes for.
  resourcesOf = w:
    let
      drop = lib.filterAttrs (_: v: v != null);
      requests = drop { cpu = w.resources.cpuRequest; memory = w.resources.memoryRequest; };
      limits = drop { cpu = w.resources.cpuLimit; memory = w.resources.memoryLimit; };
    in
    lib.optionalAttrs (requests != { }) { inherit requests; }
    // lib.optionalAttrs (limits != { }) { inherit limits; };

  # Variable names this workload supplies from individual Secret keys. A required variable satisfied
  # this way is satisfied: what the software needs is the variable, not a particular way of getting
  # its value into the process.
  secretEnvNames = w: lib.concatMap (s: lib.attrNames s.env) (lib.attrValues w.secrets);

  # THE SHAPE IS THE CATALOGUE'S, THE BUDGET MAY BE A DEPLOYMENT'S. Which endpoint answers, on which
  # port, and whether this software should be probed at all, is knowledge and comes from the entry.
  # How many seconds a cold start may take before that endpoint not answering counts as a failure is
  # a fact about the disk underneath it, so the entry's numbers are a starting point and a
  # declaration may retune them — on a probe that exists. It may not add one where the catalogue
  # deliberately has none; see the guard.
  probesOf = entry: w:
    lib.optionalAttrs (entry.readiness != null) {
      readiness = { port = entry.primaryPort; }
        // entry.readiness
        // lib.filterAttrs (_: v: v != null) w.probeBudget;
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
      inherit (w) namespace createNamespace project exposure scaling adopt;
      image = imageOf entry w;
      ports = portsOf entry;
      state = stateOf entry w;
      secrets = secretsOf w;
      env = envOf entry w;
      args = entry.args ++ w.args;
      probes = probesOf entry w;
      resources = resourcesOf w;
      init = initOf entry w;
    }
    // lib.optionalAttrs (w.identity != null) { inherit (w) identity; }
    // addressingOf w;

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  # The catalogue checking itself. Every other guard here reads a declaration against the catalogue;
  # this one reads the catalogue against the model, so that an entry which cannot be translated is
  # caught where it is written rather than by whoever first declares it.
  #
  # A SECRET-BACKED VOLUME IS THE CASE WITH TWO WAYS TO BE WRONG. It must name the variable that
  # carries its path (`pathEnv`), because a credential the process is never told the location of is
  # a mount nothing reads; and it must catalogue no `mounts`, because a path written here is this
  # file guessing at somebody's container layout and then telling the software that guess as fact.
  catalogueAssertions = lib.concatMap
    (x:
      let inherit (x) entry w; in
      lib.mapAttrsToList
        (key: spec: {
          assertion =
            spec.backing != "secret"
            || ((spec.pathEnv or null) != null && (spec.mounts or [ ]) == [ ]);
          message =
            "nixmsg: catalogue entry `${w.app}` declares `state.${key}` as secret-backed, so it must name "
            + "the variable that carries the file's path (`pathEnv`) and must catalogue no mount of its "
            + "own. WHERE a projected credential lands is a deployment's choice; the catalogue's only "
            + "stake in it is that the process be told the same path the file was mounted at.";
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

        {
          # A projected credential with no path is a Secret mounted nowhere, and the software still
          # gets told a variable pointing at it — because the module derives that variable FROM the
          # path. There is nothing to derive, so this is refused rather than defaulted: any default
          # would be this repository picking a filesystem layout inside somebody else's container.
          assertion = lib.all
            (key:
              let backing = w.state.${key}; in
              (entry.state.${key}).backing != "secret"
              || (backing.path != null && lib.hasPrefix "/" backing.path && backing.path != "/"))
            (lib.attrNames (catalogued entry w));
          message =
            "nixmsg: server `${name}` projects a credential out of a Secret and does not say WHERE the "
            + "file lands, or says it with something that is not an absolute path to a file. The catalogue "
            + "cannot answer this one: it knows the process must be told the path, not which path a "
            + "particular container layout has room for.";
        }

        {
          # TWO DEFINERS OF ONE PATH IS WHERE THEY DISAGREE. The module writes the path variable from
          # the mount; a declaration that also writes it is declaring a second answer that silently
          # loses, and the loss is invisible because both spellings look correct in isolation.
          assertion = lib.all
            (key:
              let spec = entry.state.${key}; in
              !(spec ? pathEnv) || !(w.env ? ${spec.pathEnv}))
            (lib.attrNames (catalogued entry w));
          message =
            "nixmsg: server `${name}` sets an environment variable that names a projected credential's "
            + "path, and that variable is not a declaration's to write — the module renders it from the "
            + "mount so the file's location is stated exactly once. Move the value to `state.<name>.path`.";
        }

        {
          # A volume name is an identifier in the pod template. Two volumes on one name is not a
          # merge, it is one of them silently not existing.
          assertion =
            let names = lib.mapAttrsToList volumeNameOf (catalogued entry w); in
            lib.length (lib.unique names) == lib.length names;
          message =
            "nixmsg: server `${name}` renders two volumes under one name. A volume name is an identifier "
            + "inside the pod, not a label: the second definition does not merge with the first, it "
            + "replaces it, and one of the directories this server writes then does not exist.";
        }
      ])
    workloads;

  # ── The steps that run before the process, and the numbers a deployment tunes ─────────────────
  deploymentAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.all (key: (entry.state ? ${key}) && (entry.state.${key}).prepare)
            (lib.attrNames w.prestart.prepare);
          message =
            "nixmsg: server `${name}` names a preparation step for a directory the catalogue does not say "
            + "has to be prepared. The catalogue decides THAT a tree needs preparing — because the image "
            + "cannot take ownership of one it is handed — and a step named for anything else is a step "
            + "that would never be rendered, which is a typo rather than a declaration.";
        }

        {
          assertion =
            let names = map (i: i.name) (initOf entry w); in
            lib.length (lib.unique names) == lib.length names;
          message =
            "nixmsg: server `${name}` runs two pre-start steps under one name. The kubelet keys init "
            + "containers by name and so does every overlay written against them, so two of one name is "
            + "one step that runs and one that quietly does not.";
        }

        {
          # A budget is a retuning of a probe, never the invention of one. The catalogue says `null`
          # where it does not know how long a cold start takes, and guessing low there is a restart
          # loop on a database that was merely slow to open — the exact failure the null exists to
          # avoid. So a budget with no probe under it is refused rather than quietly ignored.
          assertion =
            entry.readiness != null
            || lib.all (v: v == null) (lib.attrValues w.probeBudget);
          message =
            "nixmsg: server `${name}` is given a probe budget and the catalogue gives it no probe. The "
            + "numbers retune a probe whose SHAPE the catalogue decided; they cannot conjure one where it "
            + "deliberately declined to guess, and a probe budget nobody has watched a cold start against "
            + "is how a slow-opening database becomes a restart loop that reads as the software failing.";
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

  # A Kubernetes quantity, spelled the way the API server spells one. Not `str`: "512 Mi", "2GB" and
  # "0,5" are all rejected by the API server at apply time, which is after a commit, after a render
  # and after a sync — and a request the scheduler never saw is an app placed as if it were free.
  quantityType = lib.types.strMatching "[0-9]+(\\.[0-9]+)?(m|k|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?";

  prepareStepType = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = defaultPrepareName name;
        defaultText = lib.literalExpression ''"prepare-<directory>"'';
        description = ''
          WHAT THIS STEP IS CALLED in the pod. A deployment's fact for the same reason a volume name
          is: a live pod holds the name it was born with, an overlay written against that pod keys on
          it, and renaming one is a new pod-template hash.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.str;
        default = defaultPrepareMountPath;
        description = ''
          WHERE THE TREE APPEARS INSIDE THE HELPER IMAGE while it is being prepared. Container-internal
          and nothing to do with the server: the helper is a small tool image the deployment chose, so
          where the deployment mounts the tree inside it is the deployment's too. The `chown` this
          module renders walks exactly this path.
        '';
      };
    };
  });

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

    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload's Application TAKES OVER objects that already exist in the cluster,
        rather than creating them. Passed straight through to the app grammar, which renders the
        Application with server-side apply and server-side diff so Argo CD compares against what the
        API server actually holds instead of against a client-side reconstruction of it.

        IT IS A DECLARATION TERM AND NOT A CATALOGUE ONE, and the reason is worth stating: whether an
        object already exists is that CLUSTER'S HISTORY, not a fact about the software. The same
        server, at the same version, out of the same catalogue entry, is adopted on the cluster that
        has run it for years and created fresh on the one standing up beside it — and it differs here
        and nowhere else.

        WHY IT MATTERS MORE HERE THAN ELSEWHERE. Both servers this repository catalogues declare
        durable state, which forces `Recreate`: the old pod is gone before the new one answers. A
        rendered spec is never byte-identical to the hand-written YAML it replaces, so a first sync
        without this is a diff, and a diff is an outage — chat down, inbound federation dropped. It
        does not make the diff zero. Render it, diff it against what is live, and decide knowingly.

        Defaults to false, matching the grammar: a greenfield declaration creates its objects and
        nothing about its Application changes for anyone who never writes this down.
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

          path = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/run/secrets/example-bind-password";
            description = ''
              WHERE the projected credential lands inside the container, for the volumes the catalogue
              says are a key out of a Secret rather than durable state. Required for those and
              meaningless for the rest.

              It is a deployment's answer and not the catalogue's, because the software's actual
              requirement is that ONE named variable carry this path — not that the path be any
              particular string. That variable is rendered FROM this value, so the file's location is
              written down exactly once and a mount and an environment cannot disagree about it.

              The filename the key is projected under is this path's BASENAME. Naming it separately
              would be a second answer to the same question, and the two would differ on the day
              somebody edited one of them.
            '';
          };

          volumeName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              THE NAME THIS VOLUME ALREADY CARRIES, for a workload adopted from an object that exists.
              Defaults to the catalogue's own key for the directory, which is what anything declared
              from scratch wants.

              It is here because a volume name is part of the pod template rather than a label on it:
              a live pod holds whichever name it was born with, and renaming one is a new template
              hash — which, for a server that must stop before it starts again, is an outage rather
              than a rename.
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

    prestart = {
      prepare = lib.mkOption {
        type = lib.types.attrsOf prepareStepType;
        default = { };
        description = ''
          The step that takes ownership of a tree the image cannot take ownership of itself, keyed by
          the SAME directory name the catalogue uses. THAT the step is needed is the catalogue's
          answer and cannot be overruled here; what it is CALLED and where it mounts the tree while it
          works are this deployment's, and naming a directory the catalogue does not prepare is an
          eval error rather than a step nothing renders.
        '';
      };

      databaseWait = lib.mkOption {
        default = { };
        description = ''
          The step that blocks the process until the SQL engine accepts connections, for the servers
          the catalogue says do not run one. WHETHER it is rendered follows from the catalogue and
          from `database`; what it is called and what it says while it waits are this deployment's.
        '';
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "wait-for-database";
              description = ''
                WHAT THIS STEP IS CALLED in the pod — the same adoption fact as every other container
                name, and the key any overlay written against the live object uses.
              '';
            };

            notice = lib.mkOption {
              type = lib.types.strMatching "[^[:space:]]+";
              default = "waiting-for-database";
              description = ''
                WHAT THE WAIT PRINTS on each attempt. One word, because it is echoed unquoted inside
                the loop, and it is a deployment's word: it is the line somebody reads in a pod's logs
                at the moment the engine is down, so it names the engine in whatever vocabulary that
                cluster's operator actually uses.
              '';
            };
          };
        };
      };
    };

    probeBudget = {
      initialDelaySeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = ''
          How long to wait before probing at all, overriding the catalogue's own number. `null` (the
          default) keeps it.

          THE SHAPE IS NOT HERE. Which endpoint answers, on which port, and whether this software
          should be probed at all, is true of the software everywhere and stays in the catalogue.
          These four numbers are the part that is about a disk: the same server is patient enough at
          very different budgets on different hardware. A budget given to a server the catalogue
          probes not at all is refused rather than promoted into a probe.
        '';
      };

      periodSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Interval between probes, overriding the catalogue's own number.";
      };

      failureThreshold = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = ''
          Consecutive failures tolerated, overriding the catalogue's own number. With
          `periodSeconds` this is the whole tolerated cold start, and it is the number that decides
          whether a slow first boot reads as a slow first boot or as a failure.
        '';
      };

      timeoutSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "How long one probe may take before it counts as failed.";
      };
    };

    resources = {
      cpuRequest = lib.mkOption {
        type = lib.types.nullOr quantityType;
        default = null;
        example = "200m";
        description = ''
          CPU the scheduler must find for this server. A claim on ONE cluster's hardware, next to
          whatever else that cluster runs — the same software is correctly sized at very different
          numbers on a small node and a real one — so it is a declaration's answer and the catalogue
          holds none.

          FOUR NAMED SCALARS AND NOT A QUANTITY MAP, deliberately. Nothing this repository catalogues
          burns a GPU or any other extended resource, and a free-form map would be a surface on which
          a chat server could claim a card.
        '';
      };

      memoryRequest = lib.mkOption {
        type = lib.types.nullOr quantityType;
        default = null;
        example = "512Mi";
        description = "Memory the scheduler must find for this server. A container with none is placed as if it were free.";
      };

      cpuLimit = lib.mkOption {
        type = lib.types.nullOr quantityType;
        default = null;
        description = ''
          Ceiling on CPU. A throttle rather than a kill, which is rarely what a chat server wants: a
          throttled process still holds every websocket it had, it just answers them late.
        '';
      };

      memoryLimit = lib.mkOption {
        type = lib.types.nullOr quantityType;
        default = null;
        example = "2Gi";
        description = ''
          Ceiling on memory, and a kill threshold rather than a throttle. On a server that may not
          idle it is the one number that can end a conversation mid-sentence, which is an argument for
          setting it deliberately rather than for leaving it off.
        '';
      };
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
          state.ldap-password = {
            secret = "example-homeserver-secrets";
            key = "example-bind-password";
            path = "/run/secrets/example-bind-password";
          };
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
      ++ deploymentAssertions
      ++ dependencyAssertions
      ++ idleAssertions
      ++ anchorAssertions
      ++ slotAssertions;
    nixidy.warnings = warnings;
  };
}
