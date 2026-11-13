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

@test "etcd data and config directories cannot overlap" {
  sed 's#ETCD_CONFIG_DIR=/etc/etcd#ETCD_CONFIG_DIR=/var/lib/etcd/config#' "$TMP" > "$BATS_TEST_TMPDIR/overlap.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/overlap.env"
  [ "$status" -ne 0 ]
}
@test "etcd backup cannot be inside public artifact root" {
  sed 's#ETCD_BACKUP_DIR=/var/backups/etcd#ETCD_BACKUP_DIR=/var/lib/k8s-deploy-shell/artifacts/cache/backup#' "$TMP" > "$BATS_TEST_TMPDIR/public-backup.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/public-backup.env"
  [ "$status" -ne 0 ]
}

@test "control plane endpoint cannot overlap the Pod CIDR" {
  sed 's#CONTROL_PLANE_ENDPOINT=192.0.2.100#CONTROL_PLANE_ENDPOINT=10.244.0.1#' "$TMP" > "$BATS_TEST_TMPDIR/bad-endpoint.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/bad-endpoint.env"
  [ "$status" -ne 0 ]
}
@test "control plane port must be a valid TCP port" {
  sed 's#CONTROL_PLANE_PORT=6443#CONTROL_PLANE_PORT=65536#' "$TMP" > "$BATS_TEST_TMPDIR/bad-port.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/bad-port.env"
  [ "$status" -ne 0 ]
}

@test "control-plane ports must be unique on Master nodes" {
  sed 's#SCHEDULER_PORT=10259#SCHEDULER_PORT=6443#' "$TMP" > "$BATS_TEST_TMPDIR/port-collision.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/port-collision.env"
  [ "$status" -ne 0 ]
}

@test "NodeLocal DNS address must be in the link-local range" {
  sed 's#NODELOCAL_DNS_IP=169.254.20.10#NODELOCAL_DNS_IP=10.96.0.20#' "$TMP" > "$BATS_TEST_TMPDIR/bad-nodelocal.env"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$BATS_TEST_TMPDIR/bad-nodelocal.env"
  [ "$status" -ne 0 ]
}
