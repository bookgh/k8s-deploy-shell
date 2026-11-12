#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/manifest.sh"
  TMP="$BATS_TEST_TMPDIR/manifest.tsv"
}
@test "manifest rejects non-HTTPS source" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttp://example.invalid/foo\t%s\tfoo.tar.gz\n' "$(printf x | sha256sum | awk '{print $1}')" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest rejects unsafe filename" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\t../foo\n' "$(printf x | sha256sum | awk '{print $1}')" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
