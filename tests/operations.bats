#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CONFIG="$BATS_TEST_TMPDIR/cluster.env"
  cp "$ROOT/cluster.env.example" "$CONFIG"
}
@test "upgrade apply is fail-closed before any cluster connection" {
  run "$ROOT/scripts/14-upgrade.sh" --config "$CONFIG" --target-version v1.38.0 --apply
  [ "$status" -eq 78 ]
}
@test "cleanup data deletion is blocked" {
  run "$ROOT/scripts/13-clean-cluster.sh" --config "$CONFIG" delete-data
  [ "$status" -eq 78 ]
}
@test "offline bundle cannot be built without a complete image lock" {
  run "$ROOT/scripts/15-build-offline-bundle.sh" --config "$CONFIG" --apply build
  [ "$status" -eq 78 ]
}
