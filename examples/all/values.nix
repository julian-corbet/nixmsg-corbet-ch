# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders the whole surface from here, so a module that stops evaluating, or that
# grows a required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, path, name, number, domain and image is invented for this
# file, and no credential appears in any form — only the NAME of a Secret that would hold one, and
# the NAME of a key inside it.
#
# The two declarations are chosen to cover the paths that differ in what gets RENDERED rather than
# merely in what evaluates:
#
#   - a team chat server that keeps one tree it cannot take ownership of, needs a database it does
#     not run, takes its whole configuration as a Secret, and is pinned by digest — which is what
#     the grammar asks for and what the second one deliberately does not do;
#   - a homeserver that IS its own database, runs as a named identity, needs one environment
#     variable it cannot start without, and reads a credential out of a Secret as a FILE rather than
#     as a variable.
#
# They anchor SEPARATE namespaces on purpose: two servers that do not share an outage do not share a
# namespace, and rendering two is what proves the anchor guard counts per namespace rather than once.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixmsg.clusterPlatform.project = "example-chat";

  # The role the second workload names. Which number a role IS belongs to whatever governs the
  # fleet's identities; this is a stand-in so the render has something to resolve.
  nixk3s.appPlatform.identities.example-homeserver = { uid = 4242; gid = 4242; };

  # Writes one tree in six views, so it may not roll. Backs it on a node path and answers the
  # ownership question the catalogue asks — without which the module refuses the declaration rather
  # than rendering a server that cannot create its own configuration file. Names no identity, so the
  # preparation step runs as its own image's user and can actually chown what it was asked to.
  nixmsg.servers.example-team-chat = {
    app = "mattermost";
    version = "0.0.0";
    image = "registry.example.com/example-org/example-team-chat:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    namespace = "example-team-chat";
    createNamespace = true;
    exposure = "public";
    slot = 40;

    helperImage = "registry.example.com/example-org/example-tools:0.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    database = { host = "example-database"; port = 5432; };

    state.data = {
      hostPath = "/example/state/team-chat";
      owner = { uid = 4243; gid = 4243; };
    };

    secrets.example-team-chat-env.envFrom = true;
  };

  # Runs its own database, so nothing waits in front of it and no helper image is needed — the
  # option is required only where the catalogue says something has to happen first. Carries a version
  # rather than a whole reference, which is the tag path, and the render check reads both back.
  nixmsg.servers.example-homeserver = {
    app = "tuwunel";
    version = "0.0.0";
    namespace = "example-matrix";
    createNamespace = true;
    exposure = "public";
    slot = 41;
    identity = "example-homeserver";

    env = {
      # The one the catalogue lists as required. Everything else here is this deployment's policy.
      TUWUNEL_SERVER_NAME = "example.com";
      TUWUNEL_WELL_KNOWN__SERVER = "matrix.example.com:443";
      TUWUNEL_WELL_KNOWN__CLIENT = "https://matrix.example.com";
      TUWUNEL_ALLOW_REGISTRATION = "false";
      TUWUNEL_ALLOW_FEDERATION = "true";
      TUWUNEL_LDAP__ENABLE = "true";
      TUWUNEL_LDAP__URI = "ldap://example-directory:389";
      TUWUNEL_LDAP__BASE_DN = "dc=example,dc=com";
      TUWUNEL_LDAP__BIND_DN = "cn=example-admin,ou=people,dc=example,dc=com";
    };

    # The directory it must already own, and the credential it reads as a file. One Secret, consumed
    # two ways: a key projected into the volume, and a different key bound to a variable.
    state.database.hostPath = "/example/state/homeserver";
    state.ldap-password = {
      secret = "example-homeserver-secrets";
      key = "example-bind-password";
    };

    secrets.example-homeserver-secrets.env.TUWUNEL_REGISTRATION_TOKEN = "example-registration-token";
  };
}
