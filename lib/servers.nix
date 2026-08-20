#
# The cluster catalogue: what nixmsg's SERVERS are.
#
# ── WHY THIS FILE IS NOT lib/catalogue.nix ─────────────────────────────────────────────────────
#
# `lib/catalogue.nix` names messenger CLIENTS: the thing on a desk that reads somebody else's
# messages, resolved to a package name per distribution channel. This file names the other half of
# the same subject — the servers those clients talk TO, which do not get installed on a host at all
# but run in a cluster. One repository, one subject, two planes; merging them would produce entries
# where half the fields are meaningless, which is how a catalogue starts lying.
#
# ── WHAT BELONGS HERE ──────────────────────────────────────────────────────────────────────────
#
# A server whose job is to CARRY MESSAGES BETWEEN PEOPLE. Team chat and a Matrix homeserver pass
# that test. A mail server does not (mail is its own repository's subject), a notification sender
# does not — delivering an alert you generated is a different problem from relaying a conversation
# somebody else is having — and a video-conferencing bridge would need a real argument rather than
# an association.
#
# ── WHAT IS KNOWLEDGE AND WHAT IS A VALUE ──────────────────────────────────────────────────────
#
# Everything in this file is true of the software wherever anyone runs it: the port it listens on,
# the directories it writes, whether it can be told to sleep, whether it can create its own state,
# the SHAPE of the probe that decides whether it is up. Nothing here names an address, a node, a
# hostname, a namespace, a uid or a secret — those are one deployment's facts and they arrive from a
# declaration. The split is enforced rather than trusted: `state` here says WHERE inside the
# container a durable directory lives and what KIND of thing may back it, and only a declaration can
# say WHAT actually does.
#
# THREE THINGS THAT LOOK LIKE KNOWLEDGE AND ARE NOT, named here so the reader does not go looking
# for them below:
#
#   - HOW MUCH CPU AND MEMORY. A request is a claim on one cluster's hardware, next to whatever else
#     that cluster runs; the same software is right at very different numbers on a laptop-sized node
#     and on a real one. It is a declaration's, and this file carries none.
#   - THE PROBE'S BUDGET. WHICH endpoint answers, and whether the software should be probed at all,
#     is knowledge and is here. How many seconds a cold start may take before that endpoint not
#     answering counts as a failure is a fact about the disk underneath it, so the numbers below are
#     a starting point a declaration may retune — and may not invent where there is no probe.
#   - WHERE A PROJECTED CREDENTIAL LANDS. That the software reads a password out of a FILE, and that
#     one named variable has to carry that file's path, is knowledge. The path itself is a
#     container-layout choice; see `state.ldap-password` below.
#
# ── THE DOMAIN'S ONE SHARED FACT: NOTHING HERE MAY IDLE ────────────────────────────────────────
#
# Every server in this catalogue carries `mayIdle = false`, and it is the same reason twice rather
# than a coincidence worth generalising later. Messaging is a PUSH medium. Work arrives from
# outside — a federated event from another homeserver, a websocket frame, a mobile push poll — and
# it arrives whether or not anybody has just opened a browser tab. A workload scaled to zero holds
# no socket, answers no key probe and delivers nothing until something wakes it, so there is no
# wake front that could be right: the request that would have woken it is the one that was
# supposed to be delivered. That is a fact about the software's role, so it lives here, and the
# cluster module refuses `scaling = "scale-to-zero"` on the strength of it.
{}:
{
  servers = {
    mattermost = {
      # Docker Hub, publisher `mattermost`, team edition. No tag and no digest: a version is a
      # deployment's choice and a digest is one deployment's proof of what it is running.
      image = "mattermost/mattermost-team-edition";
      ports.http = 8065;
      primaryPort = "http";

      mayIdle = false;

      # IT DOES NOT RUN ITS OWN DATABASE, and it does not tolerate the absence of one. Mattermost
      # opens the SQL engine at start, and gives up after a few failed connection attempts rather
      # than retrying forever — so a cluster that restarts the engine and the server together
      # crash-loops the server for no reason of its own. That is why a declaration has to name the
      # engine's address: the module renders a wait in front of the process, and the wait needs
      # somewhere to knock.
      externalDatabase = true;

      # THE WHOLE CONFIGURATION SURFACE IS A CREDENTIAL. The database connection string carries a
      # password, so the environment that carries it cannot be a value in a rendered tree — it has
      # to arrive as a whole Secret, which is why the module refuses a declaration that names none.
      secretEnv = true;

      # Nothing is required by NAME, because everything arrives through that Secret and this
      # repository cannot see inside one. The note says which keys matter.
      requiredEnv = [ ];

      env = { };
      args = [ ];

      # ONE TREE, SIX VIEWS OF IT. The app keeps six directories, and they are six mounts out of a
      # single volume rather than six volumes: the tree is one curated directory, and anything that
      # walks it (a restore, an ownership fix) has to see it as one.
      #
      # And six rather than one mount at `/mattermost`, which is the parent of all six: mounting the
      # state root there buries the image's own binary and webapp, and the container does not start.
      state.data = {
        backing = "durable";

        # THE IMAGE RUNS AS A FIXED NON-ROOT USER and cannot take ownership of a directory it is
        # handed. On a node path that matters twice: such a tree comes back owned by root after a
        # restore, and `fsGroup` — the mechanism that would otherwise fix it — is not applied to
        # hostPath volumes at all. So somebody has to chown it before the process starts, every
        # start, and the module renders that. WHICH user is a deployment's fact and is not here.
        prepare = true;

        readOnly = false;
        mounts = [
          { mountPath = "/mattermost/config"; subPath = "config"; }
          { mountPath = "/mattermost/data"; subPath = "data"; }
          { mountPath = "/mattermost/logs"; subPath = "logs"; }
          { mountPath = "/mattermost/plugins"; subPath = "plugins"; }
          { mountPath = "/mattermost/client/plugins"; subPath = "client/plugins"; }
          { mountPath = "/mattermost/bleve-indexes"; subPath = "bleve-indexes"; }
        ];
      };

      # THE API'S OWN PING ENDPOINT, AND A DELIBERATELY PATIENT ONE: eighteen failures at ten
      # seconds after a twenty-second delay is three minutes of tolerated start, because a cold
      # server opens the database, replays migrations and builds its search index before it answers
      # anything. Readiness only — no liveness probe is catalogued, and its absence is the point: the
      # same slow start under a liveness probe is a restart loop that reads as the app's fault.
      readiness = {
        path = "/api/v4/system/ping";
        initialDelaySeconds = 20;
        periodSeconds = 10;
        failureThreshold = 18;
      };

      note = ''
        Team chat: channels, threads, files and search, self-hosted. A Go server bundled with a
        React webapp — one image holding both, serving the API and the UI on one port.

        THE DATABASE IS SOMEBODY ELSE'S. It speaks to an external PostgreSQL (or MySQL, if the
        connection string says so) and this catalogue neither runs one nor names one. Two
        consequences a deployment has to answer: the engine's address, so the module can wait for
        it, and a Secret holding at least the connection string and the public site URL. The site
        URL is not cosmetic — get it wrong and every link in every notification points somewhere
        that is not this server.

        THE VERSION MIGRATES THE SCHEMA. Moving the image forward runs migrations on first start,
        against data that is already there, with no diff to review afterwards. That is the whole
        argument for pinning by digest rather than by tag: two syncs of an identical rendered tree
        then run identical code, and a migration only happens when somebody moved the pin on
        purpose.

        IT CANNOT ROLL AND IT CANNOT SCALE. Six directories with one writer, plus a configuration
        file the server rewrites in place, means two live copies is corruption rather than capacity.
        The rollout strategy follows from declaring durable state and is not a preference; the
        replica count follows from the same fact.

        IT MAY NOT SLEEP. See the domain note at the top of this file: chat is pushed, not pulled.
      '';
    };

    tuwunel = {
      # GitHub Container Registry, publisher `matrix-construct`. A Conduit/conduwuit fork.
      image = "ghcr.io/matrix-construct/tuwunel";

      # TWO APIS, TWO PORTS, and the names are load-bearing rather than decorative: a Service targets
      # a port by name and a probe names a port rather than a number, so renaming one here renames it
      # everywhere it is referred to.
      ports.client = 8008; # client-server API: what a Matrix client talks to
      ports.federation = 8448; # server-server API: what other homeservers talk to
      primaryPort = "client";

      mayIdle = false;

      # IT IS ITS OWN DATABASE. One embedded RocksDB tree, no engine to reach, nothing to wait for.
      externalDatabase = false;

      # Its configuration is ordinary values, not credentials — the two secret things it needs are
      # named individually below rather than swept up in a whole-Secret environment.
      secretEnv = false;

      # THE ONE VARIABLE IT CANNOT BE STARTED WITHOUT. `server_name` is the domain that becomes the
      # suffix of every user id this homeserver ever mints, and it is not changeable afterwards
      # without abandoning every identity on it. A default would be a guess at somebody's domain, so
      # there is none and a declaration that omits it fails eval.
      requiredEnv = [ "TUWUNEL_SERVER_NAME" ];

      # Only what this catalogue itself decides. The database path is the directory `state` backs;
      # the port is the number `ports.client` declares. Everything else — the server name, the
      # delegation targets, the directory it authenticates against, whether registration is open —
      # is one deployment's policy and arrives from the declaration.
      #
      # THE BIND-PASSWORD PATH IS NOT HERE and used to be. It named a file at a path this catalogue
      # picked, which is a guess at somebody else's filesystem layout: the software's actual
      # requirement is that ONE variable carry the path the file is mounted at, not that the path be
      # any particular string. That requirement is recorded as `pathEnv` on the volume below and the
      # module derives the variable from the mount, so the two can no longer be written down twice
      # and disagree.
      #
      # `["0.0.0.0"]` is a bind-any address: a fact about a container rather than about a network,
      # which is why it is knowledge and a routable address would not be.
      env = {
        TUWUNEL_DATABASE_PATH = "/var/lib/tuwunel";
        TUWUNEL_ADDRESS = ''["0.0.0.0"]'';
        TUWUNEL_PORT = "8008";
      };

      args = [ ];

      state.database = {
        backing = "durable";

        # NOTHING CHOWNS THIS TREE. RocksDB rewrites its own .sst files, MANIFEST, CURRENT and LOCK
        # in place, so the directory has to be owned by the identity the pod runs as BEFORE the pod
        # starts — and a recursive chown of a live database tree on every start is a cost nobody
        # wants to pay. The directory is curated outside the cluster; the module renders no
        # preparation step for it and lets nothing else claim ownership either.
        prepare = false;

        readOnly = false;
        mounts = [{ mountPath = "/var/lib/tuwunel"; }];
      };

      # A SECRET CONSUMED AS A FILE, which is a different noun from a secret consumed as an
      # environment variable and gets a different term here. The LDAP bind password is read from a
      # PATH the server is told, so what the software needs is a FILE at that exact path — not a
      # directory, which is what mounting a whole Secret at it would produce, and which fails as an
      # LDAP bind rather than as a mount error.
      #
      # WHAT IS KNOWLEDGE HERE IS THE COUPLING, NOT THE PATH. That the file's location has to be
      # handed to the process in `TUWUNEL_LDAP__BIND_PASSWORD_FILE` is true of this software
      # everywhere, so `pathEnv` names that variable and the module renders it FROM the mount. WHICH
      # path — and therefore which filename the key is projected under — is one deployment's choice,
      # is not written here, and is refused unless a declaration answers it. That is also why this
      # entry catalogues no `mounts`: a path this file picked would be this file guessing at
      # somebody's container layout, and the guess would then be told to the software as fact.
      state.ldap-password = {
        backing = "secret";
        prepare = false;
        readOnly = true;
        pathEnv = "TUWUNEL_LDAP__BIND_PASSWORD_FILE";
      };

      # NO PROBE, DELIBERATELY. A homeserver opens a multi-hundred-megabyte RocksDB before it
      # answers anything, and the cost of guessing that budget wrong is a restart loop that looks
      # like the software failing. `null` is this catalogue saying it does not know how long, rather
      # than inventing a number — and see the disagreement recorded at the bottom of this entry.
      readiness = null;

      note = ''
        A Matrix homeserver: accounts, rooms, and federation with every other homeserver on the
        network. One process, two APIs, one embedded database.

        FEDERATION IS WHY IT MAY NOT SLEEP, and it is a sharper case than chat's. Events from other
        servers are PUSHED here; a remote server that cannot reach this one does not queue politely
        forever, and the key probes federation depends on have to be answered when they are asked.
        Idling this workload does not delay delivery, it drops it.

        IT IS A SINGLE WRITER over an embedded key-value store. Two pods against one RocksDB tree is
        corruption, so a rolling update is not merely undesirable but a correctness failure — which
        is exactly what declaring durable state prevents, by stopping the old pod before starting
        the new one.

        AND THE DIRECTORY MUST ALREADY EXIST. A backing that creates a missing directory is how a
        homeserver silently comes up brand new: same server name, same address, none of the history,
        and every remote server that federated with it now disagrees with it about what happened.
        The module gives every durable node path the strict form for that reason.

        THE VERSION MIGRATES THE SCHEMA on a mismatch, in place, with no diff afterwards — the same
        argument for a digest pin that team chat makes, for the same reason.

        TWO SECRET THINGS, CONSUMED TWO WAYS. A registration token is an environment variable; the
        directory bind password is a file. This catalogue names neither, carries neither, and does
        not decide where the file lands either — only that the process must be told where it did.

        A DISAGREEMENT LEFT UNRESOLVED. The recipe this entry was mined from declares an HTTP
        readiness probe on `/`; the deployment it was mined from deliberately has none. The
        catalogue follows the running system, because a probe budget nobody has watched a cold start
        against is a guess, and the failure mode of guessing low here is a restart loop on a
        database that was only slow to open.
      '';
    };
  };
}
