#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/manifest.sh"
}
@test "Kubernetes v1.37.2 binaries are pinned in the manifest" {
  run ks_manifest_validate "$ROOT/artifacts/manifest.tsv"
  [ "$status" -eq 0 ]
  for name in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
    IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" "$name")
    [ "$version" = "v1.37.2" ]
    [ "$arch" = "amd64" ]
    [[ "$url" == https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/* ]]
    [[ "$sha" =~ ^[a-f0-9]{64}$ ]]
  done
}
@test "remote control-plane installer rejects missing arguments" {
  run bash "$ROOT/scripts/remote/install-control-plane.sh"
  [ "$status" -eq 2 ]
}
@test "control-plane script never uses file-copy SSH transports" {
  run grep -nE '(^|[[:space:]])(scp|sftp|rsync)([[:space:]]|$)' "$ROOT/scripts/05-deploy-control-plane.sh" "$ROOT/scripts/remote/install-control-plane.sh"
  [ "$status" -eq 1 ]
}

@test "remote control-plane installer serializes node mutations with flock" {
  grep -Fq 'flock -n 9' "$ROOT/scripts/remote/install-control-plane.sh"
  grep -Fq 'ks-deploy-shell-control-plane.lock' "$ROOT/scripts/remote/install-control-plane.sh"
  grep -Fq 'flock;' "$ROOT/scripts/remote/install-control-plane.sh"
}
