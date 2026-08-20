# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render — without it, a typo in the shared base would make every other case "pass" for the
# wrong reason.
#
# THREE OF THE REFUSALS ARE NOT GUARDS AT ALL. Naming a server the catalogue does not hold, leaving
# out the version, and leaving out the namespace fail as a type error and as missing required
# options — not as assertions. That is the stronger kind: a boundary nobody has to remember, because
# it is unwritable rather than refused. `tryEval` cannot tell those apart from a guard, so the ones
# that ARE guards additionally have their message asserted by content.
#
# AND ONE SECTION IS ABOUT THE CATALOGUE RATHER THAN THE MODULE. Several values in `lib/servers.nix`
# have to agree with each other or the software is misconfigured in a way no Kubernetes object is
# wrong about: the homeserver is TOLD which directory its database lives in, and that string has to
# be the directory the catalogue actually backs. Those agreements are asserted here because nothing
# else in the world would notice them breaking.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  base = import values;
  servers = (import ../lib/servers.nix { }).servers;

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  # An assertion fired, AND it is the one meant: a refusal that happens for an unrelated reason is a
  # false pass, which is exactly the failure this repository's checks exist to make impossible.
  failsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (mkEnv v).config.nixidy.assertions);
    in
    r.success && r.value;

  # A surface with nothing declared at all, to prove the module is inert until something asks.
  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  goodCfg = (mkEnv base).config;
  chat = goodCfg.nixk3s.apps.example-team-chat;
  home = goodCfg.nixk3s.apps.example-homeserver;

  with' = f: lib.recursiveUpdate base f;

  # A minimal otherwise-valid declaration, for the cases where the thing being left out is required
  # by the option itself and cannot be removed from a complete one.
  minimal = extra: {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixmsg.servers.x = extra;
  };

  results = {
    # ── The control, and the floor ────────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared surface renders no servers at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "both declared workloads reach the grammar" =
      lib.sort (a: b: a < b) (lib.attrNames goodCfg.nixk3s.apps)
      == [ "example-homeserver" "example-team-chat" ];

    "the catalogue supplies every port, and the declaration never states one" =
      chat.ports.http.number == 8065
      && home.ports.client.number == 8008
      && home.ports.federation.number == 8448;

    "a version becomes the tag, and a whole reference overrides it" =
      home.image == "ghcr.io/matrix-construct/tuwunel:0.0.0"
      && lib.hasInfix "@sha256:" chat.image;

    # ── The split: WHERE from the catalogue, WHAT BACKS IT from the declaration ───────────────
    "the catalogue supplies WHERE a directory lives and the declaration supplies WHAT BACKS IT" =
      (lib.head chat.state.data.mounts).mountPath == "/mattermost/config"
      && chat.state.data.hostPath == "/example/state/team-chat";

    "one tree, six views of it -- six mounts out of a single volume rather than six volumes" =
      lib.length chat.state.data.mounts == 6
      && lib.attrNames chat.state == [ "data" ];

    "every durable node path is mounted in the form that refuses to start on a missing directory" =
      chat.state.data.hostPathType == "Directory"
      && home.state.database.hostPathType == "Directory";

    "a secret-backed volume projects the ONE key the declaration named, under the filename its path ends in" =
      home.state.ldap-password.items == { example-bind-password = "example-bind-password"; }
      && home.state.ldap-password.secret == "example-homeserver-secrets"
      && home.state.ldap-password.readOnly;

    "the filename is the path's basename rather than a second answer to the same question" =
      (lib.head home.state.ldap-password.mounts).subPath
      == baseNameOf (lib.head home.state.ldap-password.mounts).mountPath;

    "a Secret is named and never carried, in both consumption forms" =
      chat.secrets.example-team-chat-env.envFrom
      && home.secrets.example-homeserver-secrets.env.TUWUNEL_REGISTRATION_TOKEN
      == "example-registration-token";

    # ── What the catalogue decides, and what a deployment adds on top ─────────────────────────
    "the catalogue's own environment reaches the app and the declaration merges over it" =
      home.env.TUWUNEL_DATABASE_PATH == "/var/lib/tuwunel"
      && home.env.TUWUNEL_SERVER_NAME == "example.com";

    "the homeserver is told to use the directory the catalogue actually backs" =
      servers.tuwunel.env.TUWUNEL_DATABASE_PATH
      == (lib.head servers.tuwunel.state.database.mounts).mountPath;

    "the homeserver is told to listen on the port the catalogue actually declares" =
      servers.tuwunel.env.TUWUNEL_PORT == toString servers.tuwunel.ports.client;

    "the catalogue names the variable the bind password's path must arrive in, and no path of its own" =
      servers.tuwunel.state.ldap-password.pathEnv == "TUWUNEL_LDAP__BIND_PASSWORD_FILE"
      && !(servers.tuwunel.env ? TUWUNEL_LDAP__BIND_PASSWORD_FILE)
      && !(servers.tuwunel.state.ldap-password ? mounts);

    "the path a declaration chose is the path the server is told about, from one value not two" =
      home.env.TUWUNEL_LDAP__BIND_PASSWORD_FILE == "/run/secrets/example-bind-password"
      && (lib.head home.state.ldap-password.mounts).mountPath == "/run/secrets/example-bind-password";

    # ── What has to happen before the process starts ──────────────────────────────────────────
    "preparation and waiting are rendered in that order, and only for the server that needs them" =
      map (i: i.name) chat.init == [ "prepare-data" "wait-for-database" ]
      && home.init == [ ];

    "the wait knocks on the engine the declaration named, by name" =
      lib.hasInfix "example-database 5432" (lib.last (lib.last chat.init).command);

    # ── Probes ────────────────────────────────────────────────────────────────────────────────
    "a catalogued probe names the primary port and keeps its patience" =
      chat.probes.readiness.port == "http"
      && chat.probes.readiness.path == "/api/v4/system/ping"
      && chat.probes.readiness.failureThreshold == 18;

    "a server the catalogue gives no probe gets none invented for it" =
      home.probes.readiness == null;

    "a deployment may retune the budget and may not touch the shape" =
      let
        retuned = (mkEnv (with' {
          nixmsg.servers.example-team-chat.probeBudget = {
            failureThreshold = 30;
            timeoutSeconds = 3;
          };
        })).config.nixk3s.apps.example-team-chat.probes.readiness;
      in
      retuned.failureThreshold == 30
      && retuned.timeoutSeconds == 3
      && retuned.periodSeconds == 10
      && retuned.path == "/api/v4/system/ping"
      && retuned.port == "http";

    # ── What one cluster gives it, which is nothing until somebody says ──────────────────────
    # The grammar's own term is always present with empty halves; what matters is that nothing
    # this module wrote put anything in them, which is what the render check reads back as an
    # absent `resources:` block on both containers.
    "a hardware budget nobody declared puts nothing in either half" =
      chat.resources.requests == { } && chat.resources.limits == { }
      && home.resources.requests == { } && home.resources.limits == { };

    "each half is rendered only where it was answered" =
      let
        sized = (mkEnv (with' {
          nixmsg.servers.example-team-chat.resources = {
            cpuRequest = "200m";
            memoryRequest = "512Mi";
            memoryLimit = "2Gi";
          };
        })).config.nixk3s.apps.example-team-chat.resources;
      in
      sized.requests == { cpu = "200m"; memory = "512Mi"; }
      && sized.limits == { memory = "2Gi"; };

    "a quantity the API server would reject is not a value this option has" =
      !renders (with' { nixmsg.servers.example-team-chat.resources.memoryRequest = "512 Mi"; });

    "the resource surface is four named scalars, so nothing declared here can ask for a card" =
      lib.sort (a: b: a < b) (lib.attrNames goodCfg.nixmsg.servers.example-team-chat.resources)
      == [ "cpuLimit" "cpuRequest" "memoryLimit" "memoryRequest" ];

    # ── Unwritable, not merely refused ────────────────────────────────────────────────────────
    "a server the catalogue does not hold is not a value this option has" =
      !renders (with' { nixmsg.servers.example-homeserver.app = "nonesuch"; });

    "a workload with no version is refused, because a floating tag is not a default anyone can pick" =
      !renders (minimal { app = "tuwunel"; namespace = "example-x"; });

    "a workload with no namespace is refused, because these servers share no fate and so share no default" =
      !renders (minimal { app = "tuwunel"; version = "0.0.0"; });

    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "backing a directory the server does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixmsg.servers.example-team-chat.state.nonesuch.hostPath = "/example/nope"; });

    "leaving a directory the server DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (lib.recursiveUpdate base { nixmsg.servers.example-team-chat.state = lib.mkForce { }; });

    "a directory backed by two things at once is refused" =
      failsWith "EXACTLY ONE of an existing claim"
        (with' { nixmsg.servers.example-homeserver.state.database.claim = "example-claim"; });

    "backing durable state with a Secret is refused -- it is a history the server cannot write" =
      failsWith "wrong KIND of thing"
        (lib.recursiveUpdate base {
          nixmsg.servers.example-team-chat.state.data = lib.mkForce {
            secret = "example-team-chat-env";
            key = "example-key";
          };
        });

    "backing a projected credential with a node path is refused -- it is a password on somebody's storage" =
      failsWith "wrong KIND of thing"
        (lib.recursiveUpdate base {
          nixmsg.servers.example-homeserver.state.ldap-password = lib.mkForce {
            hostPath = "/example/nope";
          };
        });

    "a tree the image cannot take ownership of, on a node path, with no owner named, is refused" =
      failsWith "names no owner"
        (lib.recursiveUpdate base {
          nixmsg.servers.example-team-chat.state.data = lib.mkForce {
            hostPath = "/example/state/team-chat";
          };
        });

    "a server that does not run its own database and names none is refused" =
      failsWith "does not run its own database"
        (lib.recursiveUpdate base { nixmsg.servers.example-team-chat.database = lib.mkForce null; });

    "a server whose configuration surface is credentials, declared with no Secret, is refused" =
      failsWith "takes its whole configuration surface as credentials"
        (lib.recursiveUpdate base { nixmsg.servers.example-team-chat.secrets = lib.mkForce { }; });

    "a missing environment variable the catalogue lists as required is refused, and named" =
      failsWith "TUWUNEL_SERVER_NAME"
        (lib.recursiveUpdate base { nixmsg.servers.example-homeserver.env = lib.mkForce { }; });

    "a workload that needs something done before it starts, and names no image to do it with, is refused" =
      failsWith "names no image to do it with"
        (lib.recursiveUpdate base { nixmsg.servers.example-team-chat.helperImage = lib.mkForce null; });

    "telling a messaging server to sleep is refused rather than warned about" =
      failsWith "may not idle"
        (with' { nixmsg.servers.example-homeserver.scaling = "scale-to-zero"; });

    "two workloads anchoring one namespace is refused" =
      failsWith "Exactly one workload may create a namespace"
        (with' { nixmsg.servers.example-homeserver.namespace = "example-team-chat"; });

    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 servers"
        (with' { nixmsg.servers.example-homeserver.slot = 40; });

    # ── The guards on what only a deployment can answer ───────────────────────────────────────
    "a projected credential with nowhere to land is refused rather than defaulted" =
      failsWith "does not say WHERE the file lands"
        (lib.recursiveUpdate base {
          nixmsg.servers.example-homeserver.state.ldap-password = lib.mkForce {
            secret = "example-homeserver-secrets";
            key = "example-bind-password";
          };
        });

    "a relative path for a projected credential is refused -- the kubelet reads it as neither" =
      failsWith "does not say WHERE the file lands"
        (with' { nixmsg.servers.example-homeserver.state.ldap-password.path = "run/secrets/x"; });

    "writing the path variable a second time, beside the mount, is refused" =
      failsWith "not a declaration's to write"
        (with' {
          nixmsg.servers.example-homeserver.env.TUWUNEL_LDAP__BIND_PASSWORD_FILE = "/run/secrets/elsewhere";
        });

    "two volumes rendered under one name is refused" =
      failsWith "two volumes under one name"
        (with' { nixmsg.servers.example-homeserver.state.ldap-password.volumeName = "database"; });

    "naming a preparation step for a directory the catalogue does not prepare is refused" =
      failsWith "does not say has to be prepared"
        (with' { nixmsg.servers.example-team-chat.prestart.prepare.nonesuch.name = "example-step"; });

    "two pre-start steps under one name is refused" =
      failsWith "under one name"
        (with' {
          nixmsg.servers.example-team-chat.prestart.prepare.data.name = "example-step";
          nixmsg.servers.example-team-chat.prestart.databaseWait.name = "example-step";
        });

    "a probe budget for a server the catalogue probes not at all is refused, not promoted into a probe" =
      failsWith "the catalogue gives it no probe"
        (with' { nixmsg.servers.example-homeserver.probeBudget.failureThreshold = 30; });

    "a wait notice with a space in it is not a value this option has -- it is echoed unquoted" =
      !renders (with' { nixmsg.servers.example-team-chat.prestart.databaseWait.notice = "waiting for it"; });

    # ── The warning that is not a refusal ─────────────────────────────────────────────────────
    # A preparation step inherits the pod's identity, so as declared it cannot chown a tree owned by
    # somebody else. It is still not an eval error: the fix is a uid-0 grant on the rendered object,
    # which this vocabulary has no term for BY CONSTRUCTION, and refusing the combination would be
    # refusing a configuration that works the moment the layer below says one word.
    "an identity beside a tree that must be prepared warns rather than refuses" =
      let cfg = (mkEnv (with' { nixmsg.servers.example-team-chat.identity = "example-homeserver"; })).config;
      in lib.any (w: w.when && lib.hasInfix "inherits the pod's identity" w.message) cfg.nixidy.warnings;
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in
pkgs.runCommand "nixmsg-cluster-eval" { } (
  if failed == [ ]
  then ''
    echo "nixmsg: all ${toString (lib.length (lib.attrNames results))} cluster-eval properties hold"
    touch $out
  ''
  else ''
    echo "nixmsg cluster-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):" >&2
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}" >&2'') failed}
    exit 1
  ''
)
