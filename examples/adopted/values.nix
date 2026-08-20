# The same two servers, declared the way an ADOPTION has to declare them.
#
# `examples/all/values.nix` is the greenfield surface: nothing exists yet, so every name may be
# whatever the catalogue calls it and every number may be whatever the catalogue starts at. This
# file is the other case, and it is the one that decides whether this repository is usable at all —
# a cluster where these two servers ALREADY RUN, whose live objects were written by hand years
# before this vocabulary existed, and where the manifest that comes out has to match the manifest
# that is there.
#
# WHY THAT IS A HARD BAR RATHER THAN A TIDINESS ONE. A changed manifest is a diff, a diff is a sync,
# and a sync of either of these servers is a full stop-then-start: both declare durable state, which
# forces `Recreate`, so the old pod is gone before the new one answers. For team chat that is an
# outage; for a homeserver it is inbound federation dropped for the duration. So a re-declaration
# that renames a volume, renames an init container or reorders an environment is not a refactor. It
# is a deployment, and it has to be declared as one on purpose rather than arrived at by accident.
#
# EVERYTHING BELOW IS INVENTED. Every namespace, path, host, image, domain, name and number here is
# a stand-in; no real cluster, address or credential appears in any form. What is real is the SHAPE:
# each of these is a value some live object genuinely holds and no catalogue could have guessed.
#
# The five deployment-side answers, one at a time:
#
#   1. the steps that run first are CALLED what the live pod calls them (`prestart.*.name`), and the
#      ownership fix walks the path that pod's helper mounts (`prestart.prepare.<name>.mountPath`);
#   2. the wait says what that operator's own vocabulary says (`prestart.databaseWait.notice`);
#   3. the projected credential lands where that pod already puts it (`state.<name>.path`) and the
#      volume keeps the name it was born with (`state.<name>.volumeName`);
#   4. the hardware share is this cluster's (`resources`);
#   5. the probe's patience is this cluster's disk (`probeBudget`) — while its shape stays the
#      catalogue's, because which endpoint answers is not a cluster's opinion.
{
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixmsg.clusterPlatform.project = "example-media";

  # Team chat, adopted. The tree, the two steps in front of it, and one cluster's share of a node.
  nixmsg.servers.example-chat = {
    app = "mattermost";
    version = "0.0.0";
    image = "registry.example.com/example-org/example-team-chat:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    namespace = "example-chat";
    createNamespace = true;
    exposure = "public";

    helperImage = "registry.example.com/example-org/example-tools:0.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    database = { host = "example-engine"; port = 5432; };

    state.data = {
      hostPath = "/example/state/chat";
      owner = { uid = 4243; gid = 4243; };
    };

    # The names the live pod holds, and the path its helper mounts the tree at. None of the three is
    # the catalogue's to know, and all three are in the pod template — which is what makes them a
    # restart if they change rather than a rename.
    prestart.prepare.data = {
      name = "fix-perms";
      mountPath = "/data";
    };
    prestart.databaseWait = {
      name = "wait-for-db";
      notice = "waiting-for-example-engine";
    };

    secrets.example-chat-env.envFrom = true;

    resources = {
      cpuRequest = "200m";
      memoryRequest = "512Mi";
      memoryLimit = "2Gi";
      # No CPU ceiling on purpose: a throttled chat server still holds every socket it had, it just
      # answers them late, which is a worse failure than the one a ceiling prevents.
    };

    # Four minutes of tolerated cold start rather than the catalogue's three, because this cluster's
    # tree is bigger than the one the catalogue's number was measured against. The endpoint and the
    # port are untouched — those are the software's, not the disk's.
    probeBudget.failureThreshold = 24;
  };

  # The homeserver, adopted. Its own database, and a credential that already lands somewhere.
  nixmsg.servers.example-home = {
    app = "tuwunel";
    version = "0.0.0";
    namespace = "example-federation";
    createNamespace = true;
    exposure = "public";

    state.database.hostPath = "/example/state/homeserver/database";

    # The volume was born under a name this repository would not have chosen, and the file lands at a
    # path this repository could not have guessed. Both are kept; the variable that tells the server
    # where to read is rendered from the path rather than written beside it.
    state.ldap-password = {
      secret = "example-homeserver-secrets";
      key = "example_bind_password";
      path = "/run/secrets/example_bind_password";
      volumeName = "example-bindpw";
    };

    secrets.example-bindpw = {
      secret = "example-homeserver-secrets";
      env.TUWUNEL_REGISTRATION_TOKEN = "example_registration_token";
    };

    env = {
      TUWUNEL_SERVER_NAME = "example.com";
      TZ = "Etc/UTC";
      TUWUNEL_WELL_KNOWN__SERVER = "matrix.example.com:443";
      TUWUNEL_WELL_KNOWN__CLIENT = "https://matrix.example.com";
      TUWUNEL_ALLOW_REGISTRATION = "false";
      TUWUNEL_ALLOW_FEDERATION = "true";
      TUWUNEL_LDAP__ENABLE = "true";
      TUWUNEL_LDAP__URI = "ldap://example-directory:389";
      TUWUNEL_LDAP__BASE_DN = "dc=example,dc=com";
      TUWUNEL_LDAP__BIND_DN = "cn=example-admin,ou=people,dc=example,dc=com";
      TUWUNEL_LDAP__FILTER = "(objectClass=person)";
      TUWUNEL_LDAP__UID_ATTRIBUTE = "uid";
      TUWUNEL_LDAP__NAME_ATTRIBUTE = "cn";
      TUWUNEL_LDAP__MAIL_ATTRIBUTE = "mail";
    };
  };
}
