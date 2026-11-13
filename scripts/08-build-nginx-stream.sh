#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/manifest.sh"

CONFIG="$ROOT/cluster.env"
COMMAND=
APPLY=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; shift ;;
    --help|-h) printf 'Usage: %s [--config FILE] [--dry-run] [--apply] build\n' "$0"; exit 0 ;;
    build) [[ -z $COMMAND ]] || exit 2; COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ $COMMAND == build ]] || { ks_log ERROR 'Command required: build'; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate
NGINX_VERSION=$(ks_yaml_scalar "$ROOT/versions.yaml" nginx version)
SOURCE_URL="https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
IFS=$'\t' read -r SOURCE_FILE SOURCE_SHA SOURCE_VERSION SOURCE_ARCH SOURCE_MANIFEST_URL < <(
  ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" nginx-source
)
[[ $SOURCE_VERSION == "$NGINX_VERSION" && $SOURCE_ARCH == noarch && $SOURCE_MANIFEST_URL == "$SOURCE_URL" ]] || {
  ks_log ERROR 'Nginx source manifest does not match versions.yaml'
  exit 2
}
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO "DRY-RUN: build Nginx $NGINX_VERSION from the pinned official source archive"
  ks_log INFO 'Required local build tools: gcc, make, tar, gzip; target compatibility: Rocky Linux 9 x86_64'
  ks_log INFO 'Build profile: stream TCP proxy only; HTTP, mail and PCRE are disabled'
  exit 0
fi

for command_name in gcc make tar gzip sha256sum awk ldd realpath mktemp install cp rm getconf grep sed chmod mv cat head tr uname flock; do ks_require_cmd "$command_name"; done
[[ -r /etc/os-release ]] || { ks_log ERROR 'Missing /etc/os-release'; exit 2; }
os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $os_id == rocky && ${os_version%%.*} == 9 && $(uname -m) == x86_64 ]] || {
  ks_log ERROR 'Nginx stream binary must be built on Rocky Linux 9 x86_64'
  exit 78
}
[[ -x $(command -v gcc) && -x $(command -v make) ]] || { ks_log ERROR 'gcc and make are required; install build tools on the installation node first'; exit 127; }

if [[ $ARTIFACT_HTTP_ROOT == /* ]]; then CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT"); else CACHE_ROOT=$(realpath -m -- "$ROOT/$ARTIFACT_HTTP_ROOT"); fi
SOURCE_PATH=$CACHE_ROOT/$SOURCE_FILE
[[ -f $SOURCE_PATH && ! -L $SOURCE_PATH ]] || { ks_log ERROR 'Pinned Nginx source archive is missing or unsafe'; exit 2; }
ks_verify_sha256 "$SOURCE_PATH" "$SOURCE_SHA"
STATE_DIR=$ROOT/state
STATE_FILE=$STATE_DIR/generated-artifacts.tsv
ARCHIVE_NAME=nginx-stream-$NGINX_VERSION-linux-amd64.tar.gz
ARCHIVE_PATH=$CACHE_ROOT/$ARCHIVE_NAME
WORK=
tmp_archive=
tmp_state=
cleanup() {
  [[ -z $WORK || ! -d $WORK ]] || rm -rf -- "$WORK"
  [[ -z $tmp_archive || ! -e $tmp_archive ]] || rm -f -- "$tmp_archive"
  [[ -z $tmp_state || ! -e $tmp_state ]] || rm -f -- "$tmp_state"
}
trap cleanup EXIT

build_nginx_stream() {
  local existing='' existing_count=0 jobs archive_sha build_dir stage_dir
  install -d -m 0700 "$STATE_DIR"
  [[ ! -L $STATE_FILE ]] || { ks_log ERROR 'Generated-artifacts state file must not be a symlink'; return 2; }
  if [[ -f $STATE_FILE ]]; then
    existing=$(awk -F '\t' -v name=nginx-stream -v version="$NGINX_VERSION" 'NR > 1 && $1 == name && $2 == version { print; count++ } END { if (count > 1) exit 2 }' "$STATE_FILE") || return 2
    [[ -z $existing ]] || existing_count=1
  fi
  if ((existing_count == 1)); then
    IFS=$'\t' read -r _ existing_version existing_arch existing_file existing_sha existing_source_sha <<< "$existing"
    [[ $existing_version == "$NGINX_VERSION" && $existing_arch == amd64 && $existing_file == "$ARCHIVE_NAME" && $existing_source_sha == "$SOURCE_SHA" ]] || {
      ks_log ERROR 'Existing Nginx generated-artifact record conflicts with the pinned source'
      return 73
    }
    [[ -f $ARCHIVE_PATH && ! -L $ARCHIVE_PATH ]] || { ks_log ERROR 'Recorded Nginx archive is missing or unsafe'; return 2; }
    ks_verify_sha256 "$ARCHIVE_PATH" "$existing_sha"
    ks_log INFO "Nginx $NGINX_VERSION binary archive already built and verified"
    return 0
  fi
  [[ ! -L $ARCHIVE_PATH && ! -e $ARCHIVE_PATH ]] || { ks_log ERROR 'Unrecorded Nginx archive already exists; refusing to trust or overwrite it'; return 73; }

  WORK=$(mktemp -d "$STATE_DIR/.nginx-build.XXXXXX")
  build_dir=$WORK/source
  stage_dir=$WORK/stage
  install -d -m 0700 "$build_dir" "$stage_dir/bin"

  tar -tvzf "$SOURCE_PATH" | awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' || {
    ks_log ERROR 'Nginx source archive contains a link or special file'
    return 2
  }
  while IFS= read -r entry; do
    [[ $entry == "nginx-$NGINX_VERSION/" || $entry == "nginx-$NGINX_VERSION/"* ]] || {
      ks_log ERROR "Unexpected Nginx source archive path: $entry"
      return 2
    }
    [[ $entry != /* && $entry != *'../'* && $entry != *'/..' ]] || return 2
  done < <(tar -tzf "$SOURCE_PATH")
  tar -xzf "$SOURCE_PATH" --no-same-owner --no-same-permissions -C "$build_dir"
  cd "$build_dir/nginx-$NGINX_VERSION"
  ./configure \
    --prefix="$NGINX_PREFIX" \
    --sbin-path="$NGINX_BIN" \
    --conf-path="$NGINX_CONFIG_DIR/nginx.conf" \
    --pid-path="$NGINX_PID_FILE" \
    --error-log-path="$NGINX_LOG_DIR/error.log" \
    --without-http \
    --without-mail \
    --without-pcre \
    --with-stream
  jobs=$(getconf _NPROCESSORS_ONLN || printf '1')
  [[ $jobs =~ ^[0-9]+$ ]] || jobs=1
  ((jobs > 8)) && jobs=8
  make -j "$jobs"
  [[ -f objs/nginx && -x objs/nginx ]] || { ks_log ERROR 'Nginx build did not produce objs/nginx'; return 1; }
  objs/nginx -V 2>&1 | grep -Fq -- '--with-stream' || { ks_log ERROR 'Built Nginx binary lacks the stream module'; return 1; }
  objs/nginx -V 2>&1 | grep -Fq -- '--without-http' || { ks_log ERROR 'Built Nginx binary unexpectedly includes HTTP'; return 1; }
  ldd objs/nginx > "$WORK/ldd.txt"
  ! grep -Fq 'not found' "$WORK/ldd.txt" || { ks_log ERROR 'Nginx binary has unresolved shared libraries'; return 1; }
  install -m 0755 objs/nginx "$stage_dir/bin/nginx"
  {
    printf 'nginx_version=%s\n' "$NGINX_VERSION"
    printf 'source_url=%s\n' "$SOURCE_URL"
    printf 'source_sha256=%s\n' "$SOURCE_SHA"
    printf 'configure_flags=--prefix=%s --sbin-path=%s --conf-path=%s --pid-path=%s --error-log-path=%s --without-http --without-mail --without-pcre --with-stream\n' "$NGINX_PREFIX" "$NGINX_BIN" "$NGINX_CONFIG_DIR/nginx.conf" "$NGINX_PID_FILE" "$NGINX_LOG_DIR/error.log"
    printf 'compiler=%s\n' "$(gcc --version | head -n 1)"
    printf 'linkage:\n'
    cat "$WORK/ldd.txt"
    printf 'build_options:\n'
    "$stage_dir/bin/nginx" -V 2>&1
  } > "$stage_dir/build-info.txt"
  tmp_archive=$(mktemp "$CACHE_ROOT/.nginx-stream.XXXXXX")
  tar -cf - --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$stage_dir" . | gzip -n > "$tmp_archive"
  archive_sha=$(ks_sha256_file "$tmp_archive")
  [[ $archive_sha =~ ^[a-fA-F0-9]{64}$ ]] || return 2

  tmp_state=$(mktemp "$STATE_DIR/.generated-artifacts.XXXXXX")
  if [[ -f $STATE_FILE ]]; then
    cat "$STATE_FILE" > "$tmp_state"
  else
    printf 'name\tversion\tarch\tfilename\tsha256\tsource_sha256\n' > "$tmp_state"
  fi
  printf 'nginx-stream\t%s\tamd64\t%s\t%s\t%s\n' "$NGINX_VERSION" "$ARCHIVE_NAME" "$archive_sha" "$SOURCE_SHA" >> "$tmp_state"
  chmod 0600 "$tmp_state"
  chmod 0644 "$tmp_archive"
  mv -f -- "$tmp_archive" "$ARCHIVE_PATH"
  tmp_archive=
  mv -f -- "$tmp_state" "$STATE_FILE"
  tmp_state=
  ks_log INFO "Built and recorded $ARCHIVE_NAME (SHA256 $archive_sha)"
}
ks_with_lock "$STATE_DIR/nginx-build.lock" build_nginx_stream
