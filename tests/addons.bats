#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/config.sh"
  source "$ROOT/scripts/lib/manifest.sh"
  source "$ROOT/scripts/lib/addons.sh"
  TMP="$BATS_TEST_TMPDIR/images.tsv"
}
@test "image lock rejects empty fields" {
  printf 'name\treference\tdigest\tarchive\tarchive_sha256\tplatform\nfoo\tfoo/bar:1\tsha256:%064d\t\t%s\tlinux/amd64\n' 0 "$(printf x | sha256sum | awk '{print $1}')" > "$TMP"
  run ks_images_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "image lock rejects non-digest reference" {
  printf 'name\treference\tdigest\tarchive\tarchive_sha256\tplatform\nfoo\tfoo/bar:1\tlatest\tfoo.tar\t%s\tlinux/amd64\n' "$(printf x | sha256sum | awk '{print $1}')" > "$TMP"
  run ks_images_validate "$TMP"
  [ "$status" -ne 0 ]
}
@test "image lock rejects unsafe archive paths" {
  printf 'name\treference\tdigest\tarchive\tarchive_sha256\tplatform\nfoo\tfoo/bar:1\tsha256:%064d\t../foo.tar\t%s\tlinux/amd64\n' 0 "$(printf x | sha256sum | awk '{print $1}')" > "$TMP"
  run ks_images_validate "$TMP"
  [ "$status" -ne 0 ]
}
