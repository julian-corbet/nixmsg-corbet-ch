# Reads the tier's promises back off the RENDERED BYTES, not off the options that produced them.
#
# The eval check proves the module resolves and refuses. This one proves the manifests that come out
# say what the module claims — which is a different question, and the only one a cluster ever sees.
# An option can be correct and the rendering still wrong.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  env = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule (import values) ];
  };
in
pkgs.runCommand "nixmsg-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  echo "== the environment renders both workloads and nothing else =="
  rendered=$(ls "$manifests" | sort | tr '\n' ' ' | sed 's/ $//')
  check "rendered servers" "apps example-homeserver example-team-chat" "$rendered"

  chat="$manifests/example-team-chat"
  home="$manifests/example-homeserver"
  chatd="$chat/Deployment-example-team-chat.yaml"
  homed="$home/Deployment-example-homeserver.yaml"

  echo "== the catalogue's ports reach the containers, and neither declaration stated one =="
  check "chat port" "8065" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $chatd)"
  check "homeserver ports" "8008 8448" "$(y '[.spec.template.spec.containers[0].ports[].containerPort] | join(" ")' $homed)"

  # THE NEGATIVE HALF of the adoption term, and it has to be asserted somewhere: `adopt` renders
  # server-side apply and diff onto the Application, and a translator that leaked it onto every
  # workload would still pass the adopted surface's check. Greenfield objects do not exist yet, so
  # there is nothing to take over and nothing here may say otherwise.
  echo "== nothing is adopted here, so no Application asks to take anything over =="
  for a in $manifests/apps/Application-example-team-chat.yaml $manifests/apps/Application-example-homeserver.yaml; do
    check "$(basename $a) no server-side apply" "null" "$(y '.spec.syncPolicy.syncOptions' $a)"
    check "$(basename $a) no server-side diff" "null" "$(y '.metadata.annotations' $a)"
  done

  echo "== a messaging server is a single writer, so neither Deployment may roll =="
  check "chat strategy" "Recreate" "$(y '.spec.strategy.type' $chatd)"
  check "homeserver strategy" "Recreate" "$(y '.spec.strategy.type' $homed)"
  # A COUNT IS STAMPED HERE, and it has to be, which is the flip side of the same fact. The grammar
  # renders `replicas` for an always-on workload and omits it for one that idles, so a server this
  # catalogue permits to exist ALWAYS carries a number — and one is the only number durable state
  # allows, because the second copy would share the first's database with no coordination.
  check "chat replicas" "1" "$(y '.spec.replicas' $chatd)"
  check "homeserver replicas" "1" "$(y '.spec.replicas' $homed)"

  echo "== one tree, six views of it: six mounts out of a single volume, not six volumes =="
  check "chat volumes" "1" "$(y '.spec.template.spec.volumes | length' $chatd)"
  check "chat mounts" "6" "$(y '.spec.template.spec.containers[0].volumeMounts | length' $chatd)"
  check "chat first mount" "/mattermost/config" "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $chatd)"
  check "chat first subPath" "config" "$(y '.spec.template.spec.containers[0].volumeMounts[0].subPath' $chatd)"
  check "chat mounts share one volume" "1" "$(y '[.spec.template.spec.containers[0].volumeMounts[].name] | unique | length' $chatd)"

  echo "== a history that comes up empty is a different server, so the node path must already exist =="
  check "chat hostPath type" "Directory" "$(y '.spec.template.spec.volumes[0].hostPath.type' $chatd)"
  check "homeserver hostPath type" "Directory" "$(y '.spec.template.spec.volumes[] | select(.name == "database") | .hostPath.type' $homed)"

  echo "== the credential is a FILE, projected one key wide, not a whole Secret over a directory =="
  check "projected key"  "example-bind-password" "$(y '.spec.template.spec.volumes[] | select(.name == "ldap-password") | .secret.items[0].key' $homed)"
  check "projected path" "example-bind-password"    "$(y '.spec.template.spec.volumes[] | select(.name == "ldap-password") | .secret.items[0].path' $homed)"
  check "projected count" "1" "$(y '[.spec.template.spec.volumes[] | select(.name == "ldap-password") | .secret.items[]] | length' $homed)"
  check "landed as a file" "example-bind-password" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "ldap-password") | .subPath' $homed)"
  # THE PATH IS THE DECLARATION'S AND THE VARIABLE IS DERIVED FROM IT. Read back off the manifest
  # rather than off the options, because "the file is where the process was told" is a property of
  # two fields in two different places, and this is the only place both of them exist at once.
  check "landed where the declaration said" "/run/secrets/example-bind-password" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "ldap-password") | .mountPath' $homed)"
  check "and where it is read" "/run/secrets/example-bind-password" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TUWUNEL_LDAP__BIND_PASSWORD_FILE") | .value' $homed)"

  echo "== the other key of the same Secret is a variable, referenced and never carried =="
  check "token by reference" "example-homeserver-secrets" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TUWUNEL_REGISTRATION_TOKEN") | .valueFrom.secretKeyRef.name' $homed)"
  check "token has no value" "null" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TUWUNEL_REGISTRATION_TOKEN") | .value' $homed)"
  check "chat env is a whole Secret" "example-team-chat-env" "$(y '.spec.template.spec.containers[0].envFrom[0].secretRef.name' $chatd)"

  echo "== the catalogue tells the homeserver where its own database is, and it is where it is mounted =="
  check "database path told"   "/var/lib/tuwunel" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TUWUNEL_DATABASE_PATH") | .value' $homed)"
  check "database path mounted" "/var/lib/tuwunel" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "database") | .mountPath' $homed)"

  echo "== what has to happen first happens first, and only where it is needed =="
  check "chat init order" "prepare-data wait-for-database" "$(y '[.spec.template.spec.initContainers[].name] | join(" ")' $chatd)"
  check "chat waits by name, never by address" "true" "$(y '.spec.template.spec.initContainers[] | select(.name == "wait-for-database") | .command[-1]' $chatd | grep -q 'nc -z example-database 5432' && echo true || echo false)"
  check "homeserver has nothing to wait for" "null" "$(y '.spec.template.spec.initContainers' $homed)"

  echo "== the probe budget is the catalogue's until a deployment retunes it, and none is invented =="
  check "chat probe path" "/api/v4/system/ping" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $chatd)"
  check "chat probe patience" "18" "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $chatd)"
  check "chat probe delay" "20" "$(y '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds' $chatd)"
  check "homeserver readiness" "null" "$(y '.spec.template.spec.containers[0].readinessProbe' $homed)"
  check "homeserver liveness" "null" "$(y '.spec.template.spec.containers[0].livenessProbe' $homed)"

  echo "== a hardware budget nobody declared is a hardware budget nobody renders =="
  check "chat resources" "null" "$(y '.spec.template.spec.containers[0].resources' $chatd)"
  check "homeserver resources" "null" "$(y '.spec.template.spec.containers[0].resources' $homed)"

  echo "== a role resolves to a number one layer down, and no number was ever written up here =="
  check "homeserver runAsUser" "4242" "$(y '.spec.template.spec.securityContext.runAsUser' $homed)"

  echo "== the image is a tag when a version was given and a whole reference when one was =="
  check "homeserver image" "ghcr.io/matrix-construct/tuwunel:0.0.0" "$(y '.spec.template.spec.containers[0].image' $homed)"
  check "chat digest-pinned" "true" "$(y '.spec.template.spec.containers[0].image' $chatd | grep -q '@sha256:' && echo true || echo false)"

  echo "== no address is invented here: every Service is a plain ClusterIP with nothing pinned =="
  for f in $chat/Service-example-team-chat.yaml $home/Service-example-homeserver.yaml; do
    check "$(basename $f) type" "ClusterIP" "$(y '.spec.type' $f)"
    check "$(basename $f) no pinned IP" "null" "$(y '.spec.clusterIP' $f)"
    check "$(basename $f) no nodePort" "null" "$(y '.spec.ports[0].nodePort' $f)"
  done

  # `-L` is load-bearing: the rendered tree is SYMLINKS into the store, so a plain `-type f` matches
  # nothing and returns a confident zero. A count that can only ever be zero is worse than no check,
  # because it passes the moment somebody expects zero.
  echo "== two servers that do not share an outage anchor two namespaces, one each =="
  check "namespaces rendered" "2" "$(find -L $manifests -name 'Namespace-*.yaml' -type f | wc -l)"
  check "chat namespace" "example-team-chat" "$(y '.metadata.name' $chat/Namespace-example-team-chat.yaml)"
  check "homeserver namespace" "example-matrix" "$(y '.metadata.name' $home/Namespace-example-matrix.yaml)"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the tier's promises" >&2
    exit 1
  fi
  echo "nixmsg: the rendered tree matches every promise asserted here"
  touch $out
''
