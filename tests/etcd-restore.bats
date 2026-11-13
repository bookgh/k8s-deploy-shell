#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/config.sh"
  source "$ROOT/scripts/lib/nodes.sh"
  source "$ROOT/scripts/lib/etcd.sh"
  source "$ROOT/scripts/lib/manifest.sh"
  source "$ROOT/scripts/lib/etcd-restore.sh"
  cp "$ROOT/cluster.env.example" "$BATS_TEST_TMPDIR/cluster.env"
  ks_config_load "$BATS_TEST_TMPDIR/cluster.env"
  ks_nodes_resolve_file "$NODE_INVENTORY_FILE"
  NODE_INVENTORY_FILE=$REPLY
  ks_etcd_cluster_string "$NODE_INVENTORY_FILE"
  cluster_members=$REPLY
  etcd_version=$(awk '$1 == "etcd" { print $3 }' "$ROOT/artifacts/manifest.tsv")
  snapshot="$BATS_TEST_TMPDIR/snapshot.db"
  manifest="$BATS_TEST_TMPDIR/restore.manifest"
  printf 'synthetic-etcd-snapshot-fixture\n' > "$snapshot"
  snapshot_sha=$(ks_sha256_file "$snapshot")
  snapshot_size=$(stat -c '%s' "$snapshot")
  write_manifest() {
    printf '%s\t%s\n' \
      schema_version 1 \
      cluster_name test-cluster \
      etcd_version 3.7.3 \
      snapshot_sha256 "$snapshot_sha" \
      snapshot_revision 42 \
      snapshot_hash 0123456789abcdef \
      snapshot_total_keys 17 \
      snapshot_total_size 4096 \
      snapshot_file_size "$snapshot_size" \
      cluster_id 0123456789abcdef \
      members 'master-1=https://192.0.2.11:2380' \
      created_at_utc 2026-11-13T00:00:00Z > "$manifest"
    chmod 0600 "$manifest"
  }
  write_manifest
}

@test "restore manifest accepts matching snapshot and topology without mutation" {
  before=$(sha256sum "$manifest" "$snapshot")
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -eq 0 ]
  after=$(sha256sum "$manifest" "$snapshot")
  [ "$before" = "$after" ]
}

@test "restore manifest rejects a snapshot SHA256 mismatch" {
  printf 'tampered' >> "$snapshot"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -eq 1 ]
}

@test "restore manifest rejects a configured cluster mismatch" {
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" other-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}

@test "restore manifest rejects an inventory topology mismatch" {
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-2=https://192.0.2.12:2380'
  [ "$status" -ne 0 ]
}

@test "restore manifest rejects duplicate keys" {
  printf 'cluster_name\ttest-cluster\n' >> "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}

@test "restore manifest rejects unknown fields" {
  printf 'unexpected\tvalue\n' >> "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}

@test "restore manifest rejects symlink manifest and snapshot inputs" {
  ln -s "$manifest" "$BATS_TEST_TMPDIR/manifest-link"
  run ks_etcd_restore_manifest_validate "$BATS_TEST_TMPDIR/manifest-link" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
  ln -s "$snapshot" "$BATS_TEST_TMPDIR/snapshot-link"
  run ks_etcd_restore_manifest_validate "$manifest" "$BATS_TEST_TMPDIR/snapshot-link" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}

@test "restore manifest rejects a file size mismatch" {
  sed -i 's/^snapshot_file_size\t[0-9]*/snapshot_file_size\t1/' "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -eq 1 ]
}

@test "restore manifest rejects group or world writable metadata" {
  chmod 0660 "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}

@test "restore-preflight CLI validates local metadata without applying" {
  cli_manifest="$BATS_TEST_TMPDIR/cli.manifest"
  printf '%s\t%s\n' schema_version 1 cluster_name "$CLUSTER_NAME" etcd_version "$etcd_version" snapshot_sha256 "$snapshot_sha" snapshot_revision 42 snapshot_hash 0123456789abcdef snapshot_total_keys 17 snapshot_total_size 4096 snapshot_file_size "$snapshot_size" cluster_id 0123456789abcdef members "$cluster_members" created_at_utc 2026-11-13T00:00:00Z > "$cli_manifest"
  chmod 0600 "$cli_manifest"
  run "$ROOT/scripts/04-deploy-etcd.sh" --config "$BATS_TEST_TMPDIR/cluster.env" restore-preflight --snapshot "$snapshot" --manifest "$cli_manifest"
  [ "$status" -eq 0 ]
}

@test "restore-preflight CLI rejects apply mode" {
  run "$ROOT/scripts/04-deploy-etcd.sh" --config "$BATS_TEST_TMPDIR/cluster.env" --apply restore-preflight --snapshot "$snapshot" --manifest "$manifest"
  [ "$status" -eq 2 ]
}
