#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/cluster.env"
  cp "$ROOT/cluster.env.example" "$TMP"
}
@test "example configuration validates" {
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"; ks_config_validate' _ "$ROOT" "$TMP"
  [ "$status" -eq 0 ]
}
@test "unsafe shell substitution is rejected without execution" {
  printf '\nBAD=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >> "$TMP"
  run bash -c 'source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/config.sh"; ks_config_load "$2"' _ "$ROOT" "$TMP"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}
