#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/config.sh"
  source "$ROOT/scripts/lib/nodes.sh"
  cp "$ROOT/cluster.env.example" "$BATS_TEST_TMPDIR/cluster.env"
  ks_config_load "$BATS_TEST_TMPDIR/cluster.env"
}
@test "example node inventory validates" {
  run ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"
  [ "$status" -eq 0 ]
}
@test "node lookup returns role address user and port" {
  run ks_node_lookup "$NODE_INVENTORY_FILE" master-1
  [ "$status" -eq 0 ]
  [ "$output" = $'master\t192.0.2.11\troot\t22' ]
}
@test "node inventory rejects duplicate IPs" {
  cp "$ROOT/config/nodes.tsv.example" "$BATS_TEST_TMPDIR/nodes.tsv"
  sed -i 's#192.0.2.21#192.0.2.11#' "$BATS_TEST_TMPDIR/nodes.tsv"
  run ks_nodes_validate "$BATS_TEST_TMPDIR/nodes.tsv" "$MASTERS" "$WORKERS"
  [ "$status" -ne 0 ]
}
@test "node inventory rejects role mismatch" {
  cp "$ROOT/config/nodes.tsv.example" "$BATS_TEST_TMPDIR/nodes.tsv"
  sed -i 's#worker-1\tworker#worker-1\tmaster#' "$BATS_TEST_TMPDIR/nodes.tsv"
  run ks_nodes_validate "$BATS_TEST_TMPDIR/nodes.tsv" "$MASTERS" "$WORKERS"
  [ "$status" -ne 0 ]
}
