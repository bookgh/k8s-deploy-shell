#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/config.sh"
  source "$ROOT/scripts/lib/nodes.sh"
  source "$ROOT/scripts/lib/etcd.sh"
  cp "$ROOT/cluster.env.example" "$BATS_TEST_TMPDIR/cluster.env"
  ks_config_load "$BATS_TEST_TMPDIR/cluster.env"
  ks_nodes_resolve_file "$NODE_INVENTORY_FILE"
  NODE_INVENTORY_FILE=$REPLY
}
@test "etcd cluster string maps configured members to peer addresses" {
  ks_etcd_cluster_string "$NODE_INVENTORY_FILE"
  [ "$REPLY" = "master-1=https://192.0.2.11:2380" ]
}
@test "etcd environment enables mTLS and localhost client access" {
  run ks_etcd_render_env master-1 192.0.2.11 master-1=https://192.0.2.11:2380
  [ "$status" -eq 0 ]
  [[ "$output" == *"ETCD_LISTEN_CLIENT_URLS=https://127.0.0.1:2379,https://192.0.2.11:2379"* ]]
  [[ "$output" == *"ETCD_CLIENT_CERT_AUTH=true"* ]]
  [[ "$output" == *"ETCD_PEER_CLIENT_CERT_AUTH=true"* ]]
  [[ "$output" == *"ETCD_INITIAL_CLUSTER_STATE=new"* ]]
}
@test "etcd systemd unit uses dedicated etcd identity and explicit TLS" {
  run ks_etcd_render_unit
  [ "$status" -eq 0 ]
  [[ "$output" == *"User=etcd"* ]]
  [[ "$output" == *'--client-cert-auth=${ETCD_CLIENT_CERT_AUTH}'* ]]
  [[ "$output" == *'--peer-client-cert-auth=${ETCD_PEER_CLIENT_CERT_AUTH}'* ]]
  [[ "$output" == *"EnvironmentFile=$ETCD_CONFIG_DIR/etcd.env"* ]]
  [[ "$output" == *"ReadWritePaths=$ETCD_DATA_DIR"* ]]
}
@test "etcd member names are checked against node inventory" {
  awk -F '\t' -v OFS='\t' 'NR == 1 { print; next } $1 == "master-1" { $1 = "worker-1"; $2 = "worker" } 1' "$NODE_INVENTORY_FILE" > "$BATS_TEST_TMPDIR/nodes.tsv"
  ETCD_NODES=worker-1
  run ks_etcd_cluster_string "$BATS_TEST_TMPDIR/nodes.tsv"
  [ "$status" -ne 0 ]
}
@test "etcd backup path is not under public artifact cache" {
  [[ $ETCD_BACKUP_DIR != "$ARTIFACT_HTTP_ROOT"* ]]
}

@test "remote etcd installer rejects missing arguments before any operation" {
  run bash "$ROOT/scripts/remote/install-etcd.sh"
  [ "$status" -eq 2 ]
}

@test "remote etcd installer serializes node mutations with flock" {
  grep -Fq 'flock -n 9' "$ROOT/scripts/remote/install-etcd.sh"
  grep -Fq 'ks-deploy-shell-etcd.lock' "$ROOT/scripts/remote/install-etcd.sh"
  grep -Fq 'flock;' "$ROOT/scripts/remote/install-etcd.sh"
}

@test "etcd snapshot requires explicit apply when DRY_RUN is false" {
  config="$BATS_TEST_TMPDIR/snapshot.env"
  known_hosts="$BATS_TEST_TMPDIR/known_hosts"
  fakebin="$BATS_TEST_TMPDIR/fakebin"
  capture="$BATS_TEST_TMPDIR/ssh-calls"
  cp "$ROOT/cluster.env.example" "$config"
  sed -i 's/^DRY_RUN=true$/DRY_RUN=false/' "$config"
  sed -i "s|^SSH_KNOWN_HOSTS_FILE=.*|SSH_KNOWN_HOSTS_FILE=$known_hosts|" "$config"
  : > "$known_hosts"
  mkdir -p "$fakebin"
  : > "$capture"
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CAPTURE"
exit 0
SH
  chmod 0755 "$fakebin/ssh"
  run env SSH_CAPTURE="$capture" PATH="$fakebin:$PATH" "$ROOT/scripts/04-deploy-etcd.sh" --config "$config" snapshot
  [ "$status" -eq 78 ]
  [[ "$output" == *"requires explicit --apply"* ]]
  [ ! -s "$capture" ]
}
