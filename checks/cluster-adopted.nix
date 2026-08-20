# Proves the deployment-side terms actually LAND, read off the rendered bytes.
#
# `cluster-render.nix` renders the greenfield surface and proves the catalogue's own answers reach a
# manifest. This one renders `examples/adopted/values.nix` and proves the other half: that a
# workload whose live objects were written before this vocabulary existed can be re-declared in it
# WITHOUT the manifest moving. Every value asserted below is one the catalogue does not hold and
# could not have guessed — a container name, a helper's own mount path, a projected credential's
# location, a hardware share, a probe's patience.
#
# WHY IT IS A SEPARATE SURFACE RATHER THAN MORE LINES IN THE OTHER ONE. The two files test opposite
# defaults. Folding the overrides into the greenfield surface would leave the defaults untested —
# and the defaults are what anybody declaring one of these servers for the first time gets.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  env = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule (import values) ];
  };
in
pkgs.runCommand "nixmsg-cluster-adopted"
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

  chatd="$manifests/example-chat/Deployment-example-chat.yaml"
  homed="$manifests/example-home/Deployment-example-home.yaml"
  chata="$manifests/apps/Application-example-chat.yaml"
  homea="$manifests/apps/Application-example-home.yaml"

  # THE ONE ASSERTION HERE THAT IS NOT ABOUT THE POD. Everything else below proves the pod template
  # did not move; this proves the Application is allowed to take the object over at all. Without
  # server-side apply and diff Argo compares a client-side reconstruction against what is live, sees
  # a diff neither side asked for, and syncs it — which for these two workloads is `Recreate`, and
  # `Recreate` is the outage the whole file exists to avoid.
  echo "== an adopted workload takes objects over: server-side apply, server-side diff =="
  check "chat SSA" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $chata)"
  check "chat SSD" "ServerSideDiff=true" "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $chata)"
  check "homeserver SSA" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $homea)"
  check "homeserver SSD" "ServerSideDiff=true" "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $homea)"

  echo "== the steps that run first keep the names the live pod holds, in the order they ran =="
  check "init order" "fix-perms wait-for-db" "$(y '[.spec.template.spec.initContainers[].name] | join(" ")' $chatd)"

  echo "== the ownership fix walks the path the helper mounts, and both come from one answer =="
  check "helper mount" "/data" "$(y '.spec.template.spec.initContainers[] | select(.name == "fix-perms") | .volumeMounts[0].mountPath' $chatd)"
  check "chown target" "chown -R 4243:4243 /data" "$(y '.spec.template.spec.initContainers[] | select(.name == "fix-perms") | .command[-1]' $chatd)"
  check "helper sees the app's own volume" "data" "$(y '.spec.template.spec.initContainers[] | select(.name == "fix-perms") | .volumeMounts[0].name' $chatd)"

  echo "== the wait names the engine in the operator's vocabulary, and knocks by name =="
  check "wait notice" "waiting-for-example-engine" "$(y '.spec.template.spec.initContainers[] | select(.name == "wait-for-db") | .command[-1]' $chatd | sed -n 's/.*echo \([^;]*\);.*/\1/p')"
  check "wait target" "true" "$(y '.spec.template.spec.initContainers[] | select(.name == "wait-for-db") | .command[-1]' $chatd | grep -q 'nc -z example-engine 5432' && echo true || echo false)"

  echo "== one cluster's share of a node, and only the halves that were answered =="
  check "cpu request" "200m" "$(y '.spec.template.spec.containers[0].resources.requests.cpu' $chatd)"
  check "memory request" "512Mi" "$(y '.spec.template.spec.containers[0].resources.requests.memory' $chatd)"
  check "memory limit" "2Gi" "$(y '.spec.template.spec.containers[0].resources.limits.memory' $chatd)"
  check "no cpu ceiling" "null" "$(y '.spec.template.spec.containers[0].resources.limits.cpu' $chatd)"

  echo "== the probe's patience is this cluster's, its shape is still the catalogue's =="
  check "retuned patience" "24" "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $chatd)"
  check "untouched period" "10" "$(y '.spec.template.spec.containers[0].readinessProbe.periodSeconds' $chatd)"
  check "untouched endpoint" "/api/v4/system/ping" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $chatd)"
  # The grammar resolves the catalogue's port NAME to the catalogue's port NUMBER; what matters here
  # is that a budget did not move it.
  check "untouched port" "8065" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.port' $chatd)"

  echo "== the credential keeps the volume name it was born with, and the durable one keeps its own =="
  check "renamed volume" "example-bindpw" "$(y '.spec.template.spec.volumes[] | select(.secret != null) | .name' $homed)"
  check "catalogue name kept" "database" "$(y '.spec.template.spec.volumes[] | select(.hostPath != null) | .name' $homed)"
  check "no catalogue name left over" "0" "$(y '[.spec.template.spec.volumes[] | select(.name == "ldap-password")] | length' $homed)"

  echo "== the file lands where the declaration said, and the server is told that same path once =="
  check "mounted at" "/run/secrets/example_bind_password" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "example-bindpw") | .mountPath' $homed)"
  check "landed as a file" "example_bind_password" "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "example-bindpw") | .subPath' $homed)"
  check "projected under" "example_bind_password" "$(y '.spec.template.spec.volumes[] | select(.name == "example-bindpw") | .secret.items[0].path' $homed)"
  check "told where to read" "/run/secrets/example_bind_password" "$(y '.spec.template.spec.containers[0].env[] | select(.name == "TUWUNEL_LDAP__BIND_PASSWORD_FILE") | .value' $homed)"

  echo "== nothing a deployment answered leaked into the server that answered nothing =="
  check "homeserver resources" "null" "$(y '.spec.template.spec.containers[0].resources' $homed)"
  check "homeserver init" "null" "$(y '.spec.template.spec.initContainers' $homed)"
  check "homeserver readiness" "null" "$(y '.spec.template.spec.containers[0].readinessProbe' $homed)"

  if [ "$fail" -ne 0 ]; then
    echo "an adopted declaration does not reproduce the object it was written for" >&2
    exit 1
  fi
  echo "nixmsg: every deployment-side answer reaches the manifest that was asked for"
  touch $out
''
