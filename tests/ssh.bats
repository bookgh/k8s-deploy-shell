#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/ssh.sh"
  mkdir -p "$BATS_TEST_TMPDIR/ssh"
  : > "$BATS_TEST_TMPDIR/ssh/known_hosts"
  printf 'private test material\n' > "$BATS_TEST_TMPDIR/ssh/key"
  chmod 0600 "$BATS_TEST_TMPDIR/ssh/key"
  SSH_KNOWN_HOSTS_FILE="$BATS_TEST_TMPDIR/ssh/known_hosts"
  SSH_USER=root
  SSH_PORT=22
  KS_DRY_RUN=true
}
@test "SSH private-key delivery dry-run does not connect or modify remote state" {
  run ks_ssh_install_file 192.0.2.11 "$BATS_TEST_TMPDIR/ssh/key" /etc/kubernetes/pki/test.key 0600
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/ssh/key")" = 600 ]
}
@test "SSH private-key delivery rejects a world-readable source" {
  chmod 0644 "$BATS_TEST_TMPDIR/ssh/key"
  run ks_ssh_install_file 192.0.2.11 "$BATS_TEST_TMPDIR/ssh/key" /etc/kubernetes/pki/test.key 0600
  [ "$status" -ne 0 ]
}
@test "SSH file delivery rejects path traversal" {
  run ks_ssh_install_file 192.0.2.11 "$BATS_TEST_TMPDIR/ssh/key" /etc/kubernetes/../shadow 0600
  [ "$status" -ne 0 ]
}
@test "SSH file delivery preview does not require a known_hosts file" {
  SSH_KNOWN_HOSTS_FILE="$BATS_TEST_TMPDIR/ssh/missing_known_hosts"
  run ks_ssh_install_file 192.0.2.11 "$BATS_TEST_TMPDIR/ssh/key" /etc/kubernetes/pki/test.key 0600
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
}
