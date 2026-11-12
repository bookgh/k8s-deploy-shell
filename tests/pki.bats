#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP_CONFIG="$BATS_TEST_TMPDIR/cluster.env"
  cp "$ROOT/cluster.env.example" "$TMP_CONFIG"
}
@test "PKI dry-run creates no keys or directories" {
  sed -i "s#PKI_ROOT=./pki#PKI_ROOT=$BATS_TEST_TMPDIR/pki#" "$TMP_CONFIG"
  run "$ROOT/scripts/02-gen-ca-and-certs.sh" --config "$TMP_CONFIG"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pki" ]
}
@test "PKI apply generates three independent 100-year CA roots and ServiceAccount keys" {
  [ -s /var/lib/k8s-deploy-shell/artifacts/cache/cfssl_1.7.1_linux_amd64 ]
  [ -s /var/lib/k8s-deploy-shell/artifacts/cache/cfssljson_1.7.1_linux_amd64 ]
  sed -i "s#PKI_ROOT=./pki#PKI_ROOT=$BATS_TEST_TMPDIR/pki#; s#DRY_RUN=true#DRY_RUN=false#" "$TMP_CONFIG"
  run "$ROOT/scripts/02-gen-ca-and-certs.sh" --config "$TMP_CONFIG" --apply
  [ "$status" -eq 0 ]
  for name in kubernetes etcd front-proxy; do
    [ -s "$BATS_TEST_TMPDIR/pki/$name/ca.pem" ]
    [ -s "$BATS_TEST_TMPDIR/pki/$name/ca-key.pem" ]
    [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/pki/$name/ca-key.pem")" = 600 ]
    run openssl x509 -in "$BATS_TEST_TMPDIR/pki/$name/ca.pem" -noout -text
    [ "$status" -eq 0 ]
    [[ "$output" == *"CA:TRUE"* ]]
  done
  [ -s "$BATS_TEST_TMPDIR/pki/service-account/sa.key" ]
  [ -s "$BATS_TEST_TMPDIR/pki/service-account/sa.pub" ]
  [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/pki/service-account/sa.key")" = 600 ]
}
@test "PKI apply refuses to overwrite existing content" {
  mkdir -p "$BATS_TEST_TMPDIR/existing-pki"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/existing-pki/marker"
  sed -i "s#PKI_ROOT=./pki#PKI_ROOT=$BATS_TEST_TMPDIR/existing-pki#; s#DRY_RUN=true#DRY_RUN=false#" "$TMP_CONFIG"
  run "$ROOT/scripts/02-gen-ca-and-certs.sh" --config "$TMP_CONFIG" --apply
  [ "$status" -ne 0 ]
  [ -f "$BATS_TEST_TMPDIR/existing-pki/marker" ]
}
