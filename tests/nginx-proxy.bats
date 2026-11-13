#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}
@test "Nginx stream build dry-run needs no source archive or compiler" {
  run "$ROOT/scripts/08-build-nginx-stream.sh" --config "$ROOT/cluster.env.example" --dry-run build
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.30.6"* ]]
  [[ "$output" == *"stream TCP proxy only"* ]]
}
@test "Worker proxy dry-run resolves Master and Worker inventory" {
  run "$ROOT/scripts/09-deploy-worker-proxy.sh" --config "$ROOT/cluster.env.example" --dry-run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:6443"* ]]
  [[ "$output" == *"worker-1"* ]]
  [[ "$output" == *"passive TCP failure handling only"* ]]
}
@test "Nginx proxy remains loopback-only and TCP passthrough" {
  grep -Fq 'listen 127.0.0.1:%s' "$ROOT/scripts/remote/install-worker-proxy.sh"
  grep -Fq 'proxy_pass kube_apiserver' "$ROOT/scripts/remote/install-worker-proxy.sh"
  grep -Fq 'proxy_next_upstream on' "$ROOT/scripts/remote/install-worker-proxy.sh"
  ! grep -E 'health_check' "$ROOT/scripts/remote/install-worker-proxy.sh"
}
@test "Nginx build requires static stream module and disables HTTP" {
  grep -Fq -- '--with-stream' "$ROOT/scripts/08-build-nginx-stream.sh"
  grep -Fq -- '--without-http' "$ROOT/scripts/08-build-nginx-stream.sh"
}
