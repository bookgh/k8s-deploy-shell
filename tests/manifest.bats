#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/manifest.sh"
  TMP="$BATS_TEST_TMPDIR/manifest.tsv"
  HASH="$(printf x | sha256sum | awk '{print $1}')"
}
@test "manifest rejects non-HTTPS source" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttp://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest rejects unsafe filename" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\t../foo\n' "$HASH" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest rejects missing columns" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\n' "$HASH" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest rejects empty TSV field" {
  printf 'foo\t1.0\tamd64\t\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest rejects duplicate names and filenames" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\nfoo\t1.1\tamd64\thttps://example.invalid/foo2\t%s\tfoo2.tar.gz\n' "$HASH" "$HASH" > "$TMP"
  run ks_manifest_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "manifest dry-run does not create cache directory" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  KS_DRY_RUN=true
  run ks_manifest_fetch "$TMP" "$BATS_TEST_TMPDIR/no-cache"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/no-cache" ]
}
