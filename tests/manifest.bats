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

@test "manifest lookup returns the pinned Caddy asset" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\ncaddy\t2.11.9\tamd64\thttps://github.com/caddyserver/caddy/releases/download/v2.11.9/caddy_2.11.9_linux_amd64.tar.gz\t%s\tcaddy.tar.gz\n' "$HASH" > "$TMP"
  run ks_manifest_lookup "$TMP" caddy
  [ "$status" -eq 0 ]
  [[ "$output" == *"caddy.tar.gz"* ]]
}
@test "cache verification detects missing or corrupted assets" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  mkdir -p "$BATS_TEST_TMPDIR/cache"
  printf x > "$BATS_TEST_TMPDIR/cache/foo.tar.gz"
  KS_DRY_RUN=false
  run ks_manifest_verify_cache "$TMP" "$BATS_TEST_TMPDIR/cache"
  [ "$status" -eq 0 ]
  printf y > "$BATS_TEST_TMPDIR/cache/foo.tar.gz"
  run ks_manifest_verify_cache "$TMP" "$BATS_TEST_TMPDIR/cache"
  [ "$status" -ne 0 ]
}

@test "project artifact manifest accepts pinned underscore filenames" {
  run ks_manifest_validate "$ROOT/artifacts/manifest.tsv"
  [ "$status" -eq 0 ]
}

@test "cache verification rejects a symlinked artifact even when its content hash matches" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  mkdir -p "$BATS_TEST_TMPDIR/cache"
  printf x > "$BATS_TEST_TMPDIR/outside-artifact"
  ln -s "$BATS_TEST_TMPDIR/outside-artifact" "$BATS_TEST_TMPDIR/cache/foo.tar.gz"
  run ks_manifest_verify_cache "$TMP" "$BATS_TEST_TMPDIR/cache"
  [ "$status" -ne 0 ]
}

@test "cache verification rejects a symlinked cache root" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  mkdir -p "$BATS_TEST_TMPDIR/real-cache"
  printf x > "$BATS_TEST_TMPDIR/real-cache/foo.tar.gz"
  ln -s "$BATS_TEST_TMPDIR/real-cache" "$BATS_TEST_TMPDIR/cache-link"
  run ks_manifest_verify_cache "$TMP" "$BATS_TEST_TMPDIR/cache-link"
  [ "$status" -ne 0 ]
}

@test "artifact fetch refuses a symlinked cache target before downloading" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  mkdir -p "$BATS_TEST_TMPDIR/cache"
  printf x > "$BATS_TEST_TMPDIR/outside-artifact"
  ln -s "$BATS_TEST_TMPDIR/outside-artifact" "$BATS_TEST_TMPDIR/cache/foo.tar.gz"
  KS_DRY_RUN=false
  run ks_manifest_fetch "$TMP" "$BATS_TEST_TMPDIR/cache"
  [ "$status" -ne 0 ]
  [ -L "$BATS_TEST_TMPDIR/cache/foo.tar.gz" ]
}

@test "artifact fetch refuses a symlinked cache root before downloading" {
  printf 'name\tversion\tarch\turl\tsha256\tfilename\nfoo\t1.0\tamd64\thttps://example.invalid/foo\t%s\tfoo.tar.gz\n' "$HASH" > "$TMP"
  mkdir -p "$BATS_TEST_TMPDIR/real-cache"
  ln -s "$BATS_TEST_TMPDIR/real-cache" "$BATS_TEST_TMPDIR/cache-link"
  KS_DRY_RUN=false
  run ks_manifest_fetch "$TMP" "$BATS_TEST_TMPDIR/cache-link"
  [ "$status" -ne 0 ]
}
