#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "M5-M7 remote installers acquire shared node lock before component lock" {
  for script in \
    "$ROOT/scripts/remote/install-etcd.sh" \
    "$ROOT/scripts/remote/install-control-plane.sh" \
    "$ROOT/scripts/remote/install-container-runtime.sh" \
    "$ROOT/scripts/remote/install-kubelet-kubeproxy.sh" \
    "$ROOT/scripts/remote/install-worker-proxy.sh"; do
    node_open=$(grep -nF 'exec 8>/run/lock/ks-deploy-shell-node.lock' "$script" | cut -d: -f1)
    node_lock=$(grep -nF 'flock -n 8' "$script" | cut -d: -f1)
    component_open=$(grep -nE 'exec 9>/run/lock/[^ ]+\.lock' "$script" | cut -d: -f1)
    component_lock=$(grep -nF 'flock -n 9' "$script" | cut -d: -f1)
    [ "$node_open" -lt "$node_lock" ]
    [ "$node_lock" -lt "$component_open" ]
    [ "$component_open" -lt "$component_lock" ]
  done
}
