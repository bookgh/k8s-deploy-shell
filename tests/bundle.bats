#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STAGE="$BATS_TEST_TMPDIR/ks-deploy-shell"
  mkdir -p "$STAGE"/{artifacts/cache,bin,scripts/lib,scripts}
  for file in ARCHITECTURE.md IMPLEMENTATION-PROMPT.md IMPLEMENTATION-PLAN.md README.md versions.yaml charts.yaml cluster.env.example; do
    : > "$STAGE/$file"
  done
  printf 'name\tversion\tarch\turl\tsha256\tfilename\n' > "$STAGE/artifacts/manifest.tsv"
  printf 'test-artifact.bin\n' > "$STAGE/artifacts/cache/test-artifact.bin"
  MANIFEST_SHA="$(sha256sum "$STAGE/artifacts/cache/test-artifact.bin" | awk '{print $1}')"
  printf 'test-artifact\t1.0.0\tamd64\thttps://example.invalid/test-artifact\t%s\ttest-artifact.bin\n' "$MANIFEST_SHA" >> "$STAGE/artifacts/manifest.tsv"
  printf 'name\treference\tdigest\tarchive\tarchive_sha256\tplatform\n' > "$STAGE/images.lock.tsv"
  printf 'fake image archive\n' > "$STAGE/artifacts/cache/test-image.tar"
  ARCHIVE_SHA="$(sha256sum "$STAGE/artifacts/cache/test-image.tar" | awk '{print $1}')"
  printf 'test-image\tdocker.io/library/busybox:1.37.0\tsha256:%064d\ttest-image.tar\t%s\tlinux/amd64\n' 0 "$ARCHIVE_SHA" >> "$STAGE/images.lock.tsv"
  cp "$ROOT/scripts/lib/common.sh" "$STAGE/scripts/lib/"
  cp "$ROOT/scripts/lib/manifest.sh" "$STAGE/scripts/lib/"
  cp "$ROOT/scripts/lib/addons.sh" "$STAGE/scripts/lib/"
  cp "$ROOT/scripts/16-verify-offline-bundle.sh" "$STAGE/scripts/"
  cp "$ROOT/bin/install.sh" "$STAGE/bin/"
  BUNDLE="$BATS_TEST_TMPDIR/test-bundle.tar.gz"
  tar -czf "$BUNDLE" -C "$BATS_TEST_TMPDIR" ks-deploy-shell
  (cd "$BATS_TEST_TMPDIR" && sha256sum test-bundle.tar.gz > test-bundle.tar.gz.sha256)
}
@test "offline bundle verifier accepts a sanitized bundle with valid archive checksums" {
  run "$ROOT/scripts/16-verify-offline-bundle.sh" "$BUNDLE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; false; }
}
@test "offline bundle verifier rejects secret key material" {
  mkdir -p "$STAGE/pki"
  printf 'not a real key\n' > "$STAGE/pki/ca.key"
  tar -czf "$BUNDLE" -C "$BATS_TEST_TMPDIR" ks-deploy-shell
  (cd "$BATS_TEST_TMPDIR" && sha256sum test-bundle.tar.gz > test-bundle.tar.gz.sha256)
  run "$ROOT/scripts/16-verify-offline-bundle.sh" "$BUNDLE"
  [ "$status" -ne 0 ]
}
@test "offline bundle verifier rejects checksum mismatch" {
  printf 'tamper' >> "$BUNDLE"
  run "$ROOT/scripts/16-verify-offline-bundle.sh" "$BUNDLE"
  [ "$status" -ne 0 ]
}
