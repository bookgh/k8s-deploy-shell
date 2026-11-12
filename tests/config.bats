#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/cluster.env"
  cp "$ROOT/cluster.env.example" "$TMP"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/config.sh"
}
@test "example configuration validates and honors dry-run" {
  ks_config_load "$TMP"
  [ "$KS_DRY_RUN" = true ]
  run ks_config_validate
  [ "$status" -eq 0 ]
}
@test "unsafe shell substitution is rejected without execution" {
  printf '\nBAD=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >> "$TMP"
  run ks_config_load "$TMP"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}
@test "unknown environment keys are rejected" {
  printf '\nPATH=/tmp/attacker-bin\n' >> "$TMP"
  run ks_config_load "$TMP"
  [ "$status" -ne 0 ]
}
@test "duplicate config keys are rejected" {
  printf '\nCLUSTER_NAME=second\n' >> "$TMP"
  run ks_config_load "$TMP"
  [ "$status" -ne 0 ]
}
@test "overlapping Pod and Service CIDRs are rejected" {
  sed -i 's#SERVICE_CIDR=10.96.0.0/12#SERVICE_CIDR=10.244.0.0/16#' "$TMP"
  run ks_config_load "$TMP"; [ "$status" -eq 0 ]
  run ks_config_validate; [ "$status" -ne 0 ]
}
@test "Cluster DNS outside Service CIDR is rejected" {
  sed -i 's#CLUSTER_DNS=10.96.0.10#CLUSTER_DNS=10.97.0.10#' "$TMP"
  run ks_config_load "$TMP"; [ "$status" -eq 0 ]
  run ks_config_validate; [ "$status" -ne 0 ]
}
@test "duplicate and cross-role nodes are rejected" {
  sed -i 's#MASTERS=master-1#MASTERS=master-1,master-1#' "$TMP"
  run ks_config_load "$TMP"; [ "$status" -eq 0 ]
  run ks_config_validate; [ "$status" -ne 0 ]
  cp "$ROOT/cluster.env.example" "$TMP"
  sed -i 's#WORKERS=worker-1#WORKERS=master-1#' "$TMP"
  run ks_config_load "$TMP"; [ "$status" -eq 0 ]
  run ks_config_validate; [ "$status" -ne 0 ]
}
@test "even etcd membership is rejected" {
  sed -i 's#ETCD_NODES=master-1#ETCD_NODES=master-1,master-2#' "$TMP"
  sed -i 's#MASTERS=master-1#MASTERS=master-1,master-2#' "$TMP"
  run ks_config_load "$TMP"; [ "$status" -eq 0 ]
  run ks_config_validate; [ "$status" -ne 0 ]
}
@test "dry-run atomic write and lock do not create files" {
  KS_DRY_RUN=true
  run ks_atomic_write "$BATS_TEST_TMPDIR/not-created" 0600 <<< 'secret'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/not-created" ]
  run ks_with_lock "$BATS_TEST_TMPDIR/not-created.lock" true
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/not-created.lock" ]
}
@test "CIDR overlap helper distinguishes disjoint networks" {
  run ks_cidr_overlaps 10.244.0.0/16 10.96.0.0/12
  [ "$status" -eq 1 ]
  run ks_cidr_overlaps 10.96.0.0/12 10.96.0.0/16
  [ "$status" -eq 0 ]
}

@test "Kubernetes API service IP outside Service CIDR is rejected" {
  sed -i 's#KUBERNETES_SERVICE_IP=10.96.0.1#KUBERNETES_SERVICE_IP=10.112.0.1#' "$TMP"
  ks_config_load "$TMP"
  run ks_config_validate
  [ "$status" -ne 0 ]
}
