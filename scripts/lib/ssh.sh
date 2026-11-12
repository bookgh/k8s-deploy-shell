#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_ssh() {
  local host=${1:?host required}; shift
  local known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
  [[ -r $known_hosts ]] || { ks_log ERROR "Known hosts file missing: $known_hosts"; return 2; }
  local -a args=(-p "${SSH_PORT:-22}" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}" -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  if ks_is_true "${KS_DRY_RUN:-false}"; then
    printf '[dry-run] ssh'; printf ' %q' "${args[@]}" "${SSH_USER:-root}@$host" "$@"; printf '\n'; return 0
  fi
  ks_retry "${SSH_RETRIES:-3}" "${SSH_BACKOFF_SECONDS:-2}" ssh "${args[@]}" "${SSH_USER:-root}@$host" -- "$@"
}
