#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
}

@test "dry-run lock wrapper never invokes mutating callback or creates lock" {
  export KS_DRY_RUN=true
  marker="$BATS_TEST_TMPDIR/callback-ran"
  lockfile="$BATS_TEST_TMPDIR/operation.lock"

  run ks_with_lock "$lockfile" touch "$marker"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN: would acquire lock"* ]]
  [ ! -e "$marker" ]
  [ ! -e "$lockfile" ]
}

@test "non-dry-run lock wrapper executes callback while holding lock" {
  export KS_DRY_RUN=false
  marker="$BATS_TEST_TMPDIR/callback-ran"
  lockfile="$BATS_TEST_TMPDIR/operation.lock"

  run ks_with_lock "$lockfile" touch "$marker"

  [ "$status" -eq 0 ]
  [ -f "$marker" ]
  [ -f "$lockfile" ]
}
