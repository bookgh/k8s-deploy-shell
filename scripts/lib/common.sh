#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
KS_LOG_FILE=${KS_LOG_FILE:-}
KS_DRY_RUN=${KS_DRY_RUN:-false}

ks_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

ks_log() {
  local level=${1:?level required}; shift
  local line
  printf -v line '[%s] %-5s %s' "$(ks_timestamp)" "$level" "$*"
  printf '%s\n' "$line" >&2
  if [[ -n $KS_LOG_FILE ]] && ! ks_is_true "$KS_DRY_RUN"; then
    printf '%s\n' "$line" >> "$KS_LOG_FILE"
  fi
}

ks_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { ks_log ERROR "Required command missing: $1"; return 127; }
}

ks_is_true() { [[ ${1,,} == true || ${1} == 1 || ${1,,} == yes ]]; }

ks_run() {
  if ks_is_true "$KS_DRY_RUN"; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

ks_mkdir() {
  if ks_is_true "$KS_DRY_RUN"; then
    printf '[dry-run] mkdir -p'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  mkdir -p -- "$@"
}

ks_sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }

ks_verify_sha256() {
  local file=$1 expected=$2 actual
  [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || { ks_log ERROR "Invalid SHA256: $file"; return 2; }
  actual=$(ks_sha256_file "$file")
  [[ ${actual,,} == "${expected,,}" ]] || { ks_log ERROR "SHA256 mismatch: $file"; return 1; }
}

ks_atomic_write() {
  local target=$1 mode=${2:-0600} dir tmp
  if ks_is_true "$KS_DRY_RUN"; then
    ks_log INFO "DRY-RUN: would atomically write $target mode=$mode"
    return 0
  fi
  dir=$(dirname -- "$target")
  mkdir -p -- "$dir"
  tmp=$(mktemp "${dir}/.tmp.XXXXXX")
  chmod "$mode" "$tmp"
  if ! cat > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$target"
}

ks_backup_file() {
  local source=$1 backup_dir=$2 stamp destination
  [[ -e $source ]] || return 0
  if ks_is_true "$KS_DRY_RUN"; then
    ks_log INFO "DRY-RUN: would back up $source to $backup_dir"
    return 0
  fi
  stamp=$(date -u '+%Y%m%dT%H%M%SZ')
  mkdir -p -- "$backup_dir"
  destination=$backup_dir/$(basename -- "$source").$stamp
  cp -a -- "$source" "$destination"
  printf '%s\n' "$destination"
}

ks_retry() {
  local attempts=$1 delay=$2; shift 2
  local n rc=0
  ((attempts >= 1 && attempts <= 10 && delay >= 0 && delay <= 30)) || return 2
  for ((n=1; n<=attempts; n++)); do
    "$@" && return 0 || rc=$?
    (( n == attempts )) && break
    ks_log WARN "Attempt $n/$attempts failed; retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay < 30 ? delay * 2 : 30 ))
  done
  return "$rc"
}

ks_with_lock() {
  local lockfile=$1; shift
  if ks_is_true "$KS_DRY_RUN"; then
    ks_log INFO "DRY-RUN: would acquire lock $lockfile"
    "$@"
    return
  fi
  ks_require_cmd flock
  mkdir -p -- "$(dirname -- "$lockfile")"
  exec {lock_fd}>"$lockfile"
  flock -n "$lock_fd" || { ks_log ERROR "Operation already locked: $lockfile"; return 75; }
  "$@"
}

ks_on_error() {
  local rc=$? line=${1:-unknown} cmd=${2:-unknown}
  ks_log ERROR "Failure rc=$rc line=$line command=$cmd"
  exit "$rc"
}
trap 'ks_on_error "$LINENO" "$BASH_COMMAND"' ERR
