#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_ssh() {
  local host=${1:?host required}; shift
  local known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
  local remote_command='' arg
  [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { ks_log ERROR 'Invalid SSH host token'; return 2; }
  [[ -r $known_hosts ]] || { ks_log ERROR "Known hosts file missing: $known_hosts"; return 2; }
  (($# > 0)) || { ks_log ERROR 'Remote command required'; return 2; }
  for arg in "$@"; do
    [[ $arg =~ ^[A-Za-z0-9_./:=,@+-]+$ ]] || { ks_log ERROR 'Unsafe remote argument; only restricted tokens are accepted'; return 2; }
    remote_command+="$arg "
  done
  remote_command=${remote_command% }
  local -a args=(-p "${SSH_PORT:-22}" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}" -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  if ks_is_true "${KS_DRY_RUN:-false}"; then
    printf '[dry-run] ssh'; printf ' %q' "${args[@]}" "${SSH_USER:-root}@$host" "$remote_command"; printf '\n'
    return 0
  fi
  ks_retry "${SSH_RETRIES:-3}" "${SSH_BACKOFF_SECONDS:-2}" ssh "${args[@]}" "${SSH_USER:-root}@$host" "$remote_command"
}
