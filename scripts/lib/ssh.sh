#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ks_ssh_validate_parameters() {
  local port=${SSH_PORT:-22} user=${SSH_USER:-root}
  local timeout=${SSH_CONNECT_TIMEOUT:-8} retries=${SSH_RETRIES:-3}
  local backoff=${SSH_BACKOFF_SECONDS:-2}

  [[ $user =~ ^[a-z_][a-zA-Z0-9_-]*[$]?$ ]] || {
    ks_log ERROR 'Invalid SSH user'
    return 2
  }
  [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || {
    ks_log ERROR 'SSH port must be an integer from 1 to 65535'
    return 2
  }
  [[ $timeout =~ ^[0-9]+$ ]] && ((10#$timeout >= 1 && 10#$timeout <= 120)) || {
    ks_log ERROR 'SSH connect timeout must be from 1 to 120 seconds'
    return 2
  }
  [[ $retries =~ ^[0-9]+$ ]] && ((10#$retries >= 1 && 10#$retries <= 10)) || {
    ks_log ERROR 'SSH retries must be from 1 to 10'
    return 2
  }
  [[ $backoff =~ ^[0-9]+$ ]] && ((10#$backoff <= 30)) || {
    ks_log ERROR 'SSH backoff must be from 0 to 30 seconds'
    return 2
  }
}

ks_ssh_validate_known_hosts() {
  local known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
  [[ -f $known_hosts && ! -L $known_hosts && -r $known_hosts ]] || {
    ks_log ERROR "Known hosts must be a readable regular file, not a symlink: $known_hosts"
    return 2
  }
}

ks_ssh() {
  local host=${1:?host required}; shift
  local known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
  local remote_command='' arg
  [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { ks_log ERROR 'Invalid SSH host token'; return 2; }
  (($# > 0)) || { ks_log ERROR 'Remote command required'; return 2; }
  ks_ssh_validate_parameters || return $?
  for arg in "$@"; do
    [[ $arg =~ ^[A-Za-z0-9_./:=,@+%-]+$ ]] || { ks_log ERROR 'Unsafe remote argument; only restricted tokens are accepted'; return 2; }
    remote_command+="$arg "
  done
  remote_command=${remote_command% }
  local -a args=(-p "${SSH_PORT:-22}" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}" -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  if ks_is_true "${KS_DRY_RUN:-false}"; then
    printf '[dry-run] ssh'; printf ' %q' "${args[@]}" "${SSH_USER:-root}@$host" "$remote_command"; printf '\n'
    return 0
  fi
  ks_ssh_validate_known_hosts || return $?
  ks_retry "${SSH_RETRIES:-3}" "${SSH_BACKOFF_SECONDS:-2}" ssh "${args[@]}" "${SSH_USER:-root}@$host" "$remote_command"
}

ks_ssh_install_file() {
  local host=${1:?host required} source_file=${2:?source file required} destination=${3:?destination required} mode=${4:?mode required}
  local known_hosts=${SSH_KNOWN_HOSTS_FILE:-$HOME/.ssh/known_hosts}
  local remote_command remote_tmp local_sha remote_sha source_mode remote_dir target
  local attempt attempts delay rc=0
  local -a ssh_args=()
  [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { ks_log ERROR 'Invalid SSH host token'; return 2; }
  [[ -f $source_file && ! -L $source_file && -r $source_file ]] || { ks_log ERROR "Source file must be a readable regular file: $source_file"; return 2; }
  [[ $destination =~ ^/[A-Za-z0-9._/-]+$ && $destination != / && $destination != *'/../'* && $destination != */.. ]] || { ks_log ERROR "Unsafe remote destination: $destination"; return 2; }
  [[ $mode == 0600 || $mode == 0644 ]] || { ks_log ERROR 'Only remote modes 0600 and 0644 are supported'; return 2; }
  ks_ssh_validate_parameters || return $?
  source_mode=$(stat -c '%a' "$source_file")
  if [[ $mode == 0600 && $source_mode != 600 && $source_mode != 400 ]]; then
    ks_log ERROR 'Private-key source file must already be mode 0600 or 0400'
    return 2
  fi
  remote_tmp=$destination.ksdeploy.$BASHPID
  remote_dir=${destination%/*}
  [[ -n $remote_dir ]] || { ks_log ERROR "Remote destination must include a directory: $destination"; return 2; }
  local_sha=$(ks_sha256_file "$source_file")
  if ks_is_true "$KS_DRY_RUN"; then
    ks_log INFO "DRY-RUN: would stream $source_file over strict SSH to $host:$destination mode=$mode sha256=$local_sha"
    return 0
  fi
  ks_ssh_validate_known_hosts || return $?
  ssh_args=(-p "${SSH_PORT:-22}" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-8}" -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  if [[ ${SSH_USER:-root} == root ]]; then
    ks_ssh "$host" install -d -o root -g root -m 0700 "$remote_dir"
    remote_command="install -D -o root -g root -m $mode /dev/stdin $remote_tmp"
  else
    ks_ssh "$host" sudo -n install -d -o root -g root -m 0700 "$remote_dir"
    remote_command="sudo -n install -D -o root -g root -m $mode /dev/stdin $remote_tmp"
  fi
  attempts=${SSH_RETRIES:-3}; delay=${SSH_BACKOFF_SECONDS:-2}
  target=${SSH_USER:-root}@$host
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if ssh "${ssh_args[@]}" "$target" "$remote_command" < "$source_file"; then
      rc=0; break
    else
      rc=$?
    fi
    ((attempt == attempts)) && break
    ks_log WARN "SSH stream attempt $attempt/$attempts failed; retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay < 30 ? delay * 2 : 30 ))
  done
  ((rc == 0)) || return "$rc"
  if [[ ${SSH_USER:-root} == root ]]; then
    remote_sha=$(ks_ssh "$host" sha256sum "$remote_tmp" | awk '{print $1}')
  else
    remote_sha=$(ks_ssh "$host" sudo -n sha256sum "$remote_tmp" | awk '{print $1}')
  fi
  if [[ $remote_sha != "$local_sha" ]]; then
    if [[ ${SSH_USER:-root} == root ]]; then ks_ssh "$host" rm -f "$remote_tmp" || true; else ks_ssh "$host" sudo -n rm -f "$remote_tmp" || true; fi
    ks_log ERROR "SSH stream SHA256 mismatch for $destination"
    return 1
  fi
  if [[ ${SSH_USER:-root} == root ]]; then
    ks_ssh "$host" mv -f "$remote_tmp" "$destination"
    remote_sha=$(ks_ssh "$host" sha256sum "$destination" | awk '{print $1}')
  else
    ks_ssh "$host" sudo -n mv -f "$remote_tmp" "$destination"
    remote_sha=$(ks_ssh "$host" sudo -n sha256sum "$destination" | awk '{print $1}')
  fi
  [[ $remote_sha == "$local_sha" ]] || { ks_log ERROR "Remote file verification failed after atomic rename: $destination"; return 1; }
  ks_log INFO "Secure SSH file delivery verified: $host:$destination"
}
