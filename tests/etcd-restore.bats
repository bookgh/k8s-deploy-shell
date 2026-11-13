#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/etcd-restore.sh"
  snapshot="$BATS_TEST_TMPDIR/snapshot.db"
  manifest="$BATS_TEST_TMPDIR/restore.manifest"
  printf 'synthetic-etcd-snapshot-fixture\n' > "$snapshot"
  snapshot_sha=$(ks_sha256_file "$snapshot")
  snapshot_size=$(stat -c '%s' "$snapshot")
  write_manifest() {
    cat > "$manifest" <<EOF
schema_version	1
cluster_name	test-cluster
etcd_version	3.7.3
snapshot_sha256	$snapshot_sha
snapshot_revision	42
snapshot_hash	0123456789abcdef
snapshot_total_keys	17
snapshot_total_size	$snapshot_size
cluster_id	0123456789abcdef
members	master-1=https://192.0.2.11:2380
created_at_utc	2026-11-13T00:00:00Z
EOF
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
  sed -i 's/^snapshot_total_size\t[0-9]*/snapshot_total_size\t1/' "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -eq 1 ]
}

@test "restore manifest rejects group or world writable metadata" {
  chmod 0660 "$manifest"
  run ks_etcd_restore_manifest_validate "$manifest" "$snapshot" test-cluster 3.7.3 'master-1=https://192.0.2.11:2380'
  [ "$status" -ne 0 ]
}
