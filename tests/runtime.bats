#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}
@test "pinned runtime artifacts validate in the project manifest" {
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/manifest.sh"; ks_manifest_validate "$1/artifacts/manifest.tsv"' _ "$ROOT"
  [ "$status" -eq 0 ]
}
@test "runtime versions and sandbox image resolve from versions.yaml" {
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/manifest.sh"; test "$(ks_yaml_scalar "$1/versions.yaml" containerd version)" = 2.3.7 && test "$(ks_yaml_scalar "$1/versions.yaml" runc version)" = 1.5.2 && test "$(ks_yaml_scalar "$1/versions.yaml" cni_plugins version)" = 1.10.0 && test "$(ks_yaml_scalar "$1/versions.yaml" sandbox_image repository):$(ks_yaml_scalar "$1/versions.yaml" sandbox_image tag)" = registry.k8s.io/pause:3.10.1' _ "$ROOT"
  [ "$status" -eq 0 ]
}
@test "containerd config selects systemd cgroups and configured CNI paths" {
  grep -Fq 'SystemdCgroup = true' "$ROOT/scripts/remote/install-container-runtime.sh"
  grep -Fq 'bin_dirs = ["$CNI_BIN_DIR"]' "$ROOT/scripts/remote/install-container-runtime.sh"
  grep -Fq 'sandbox = "$SANDBOX_IMAGE"' "$ROOT/scripts/remote/install-container-runtime.sh"
}
@test "runtime dry-run prints plan without requiring cached archives" {
  run "$ROOT/scripts/06-deploy-container-runtime.sh" --config "$ROOT/cluster.env.example" --dry-run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}
