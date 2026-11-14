#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}
@test "kubelet and kube-proxy dry-run works without PKI or cached binaries" {
  run "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh" --config "$ROOT/cluster.env.example" --dry-run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://127.0.0.1:6443"* ]]
}
@test "worker kubeconfigs are generated against loopback API endpoint" {
  grep -Fq 'https://127.0.0.1:$CONTROL_PLANE_PORT' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
  ! grep -Fq 'https://$CONTROL_PLANE_ENDPOINT' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
}
@test "kubelet security settings are explicit" {
  grep -Fq 'readOnlyPort: 0' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
  grep -Fq 'authorization:' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
  grep -Fq 'mode: Webhook' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
  grep -Fq 'cgroupDriver: systemd' "$ROOT/scripts/07-deploy-kubelet-kubeproxy.sh"
}
@test "kubelet and kube-proxy services are not enabled during installation" {
  grep -Fq 'services were not started' "$ROOT/scripts/remote/install-kubelet-kubeproxy.sh"
  ! grep -E 'systemctl enable|systemctl start' "$ROOT/scripts/remote/install-kubelet-kubeproxy.sh"
}
@test "PKI distribution honors configured kubelet data directory" {
  grep -Fq '$KUBELET_DATA_DIR/pki' "$ROOT/scripts/03-distribute-pki.sh"
}

@test "remote kubelet and proxy installers serialize node mutations" {
  grep -Fq 'flock -n 9' "$ROOT/scripts/remote/install-kubelet-kubeproxy.sh"
  grep -Fq 'ks-deploy-shell-kubelet-proxy.lock' "$ROOT/scripts/remote/install-kubelet-kubeproxy.sh"
  grep -Fq 'flock -n 9' "$ROOT/scripts/remote/install-worker-proxy.sh"
  grep -Fq 'ks-deploy-shell-worker-proxy.lock' "$ROOT/scripts/remote/install-worker-proxy.sh"
}
