#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/ssh.sh"
  mkdir -p "$BATS_TEST_TMPDIR/ssh" "$BATS_TEST_TMPDIR/bin"
  : > "$BATS_TEST_TMPDIR/ssh/known_hosts"
  printf 'private test material\n' > "$BATS_TEST_TMPDIR/ssh/key"
  chmod 0600 "$BATS_TEST_TMPDIR/ssh/key"
  SSH_KNOWN_HOSTS_FILE="$BATS_TEST_TMPDIR/ssh/known_hosts"
  SSH_USER=root
  SSH_PORT=22
  KS_DRY_RUN=true
  export SSH_CAPTURE="$BATS_TEST_TMPDIR/ssh-capture"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
: > "$SSH_CAPTURE"
printf '%s\n' "$@" >> "$SSH_CAPTURE"
SH
  chmod 0755 "$BATS_TEST_TMPDIR/bin/ssh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH
}
@test "SSH private-key delivery dry-run does not connect or modify remote state" {
  run ks_ssh_install_file 192.0.2.11 "$BATS_TEST_TMPDIR/ssh/key" /etc/kubernetes/pki/test.key 0600
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/ssh/key")" = 600 ]
  [ ! -e "$SSH_CAPTURE" ]
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
@test "SSH rejects a symlinked known_hosts file before invoking ssh" {
  ln -s "$BATS_TEST_TMPDIR/ssh/known_hosts" "$BATS_TEST_TMPDIR/ssh/known_hosts-link"
  SSH_KNOWN_HOSTS_FILE="$BATS_TEST_TMPDIR/ssh/known_hosts-link"
  KS_DRY_RUN=false
  run ks_ssh 192.0.2.11 uname -m
  [ "$status" -eq 2 ]
  [ ! -e "$SSH_CAPTURE" ]
}
@test "SSH rejects an invalid port before invoking ssh" {
  SSH_PORT='22 -oProxyCommand=touch /tmp/pwned'
  KS_DRY_RUN=false
  run ks_ssh 192.0.2.11 uname -m
  [ "$status" -eq 2 ]
  [ ! -e "$SSH_CAPTURE" ]
}
@test "SSH rejects an invalid user before invoking ssh" {
  SSH_USER='root;touch'
  KS_DRY_RUN=false
  run ks_ssh 192.0.2.11 uname -m
  [ "$status" -eq 2 ]
  [ ! -e "$SSH_CAPTURE" ]
}
@test "SSH applies strict host-key options to a valid connection" {
  KS_DRY_RUN=false
  run ks_ssh 192.0.2.11 uname -m
  [ "$status" -eq 0 ]
  grep -Fq 'StrictHostKeyChecking=yes' "$SSH_CAPTURE"
  grep -Fq "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE" "$SSH_CAPTURE"
  grep -Fq 'root@192.0.2.11' "$SSH_CAPTURE"
}
