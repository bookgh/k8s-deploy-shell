#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
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
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    --help|-h) printf 'Usage: %s [--config FILE] [--dry-run] [--apply] preflight|verify-cache|caddy\n' "$0"; exit 0 ;;
    preflight|verify-cache|caddy) [[ -z $COMMAND ]] || exit 2; COMMAND=$1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n $COMMAND ]] || { printf 'Command required\n' >&2; exit 2; }
ks_config_load "$CONFIG"
ks_config_validate

ks_cache_root() {
  local path=$ARTIFACT_HTTP_ROOT
  [[ $path == /* ]] || path=$ROOT/$path
  ks_require_cmd realpath
  path=$(realpath -m -- "$path")
  [[ $path == /var/lib/k8s-deploy-shell/artifacts/* ]] || { ks_log ERROR "Caddy root must be under /var/lib/k8s-deploy-shell/artifacts/: $path"; return 2; }
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *'/../'* && $path != */.. ]] || { ks_log ERROR "Artifact root contains unsafe path characters: $path"; return 2; }
  REPLY=$path
}

ks_preflight_install_node() {
  local os_id os_version free_kb listeners
  [[ -r /etc/os-release ]] || { ks_log ERROR '/etc/os-release missing'; return 2; }
  os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  [[ $os_id == rocky && ${os_version%%.*} == 9 ]] || { ks_log ERROR "Expected Rocky Linux 9, found $os_id $os_version"; return 2; }
  [[ $(uname -m) == x86_64 ]] || { ks_log ERROR 'Expected x86_64 architecture'; return 2; }
  for cmd in bash curl tar sha256sum awk ssh flock systemctl ss realpath install useradd groupadd getent id chgrp chmod find mktemp cp mv rm; do ks_require_cmd "$cmd"; done
  ((ARTIFACT_HTTP_PORT >= 1024 && ARTIFACT_HTTP_PORT <= 65535)) || { ks_log ERROR 'Caddy port must be in range 1024-65535'; return 2; }
  listeners=$(ss -H -ltn "sport = :$ARTIFACT_HTTP_PORT")
  [[ -z $listeners ]] || { ks_log ERROR "TCP port $ARTIFACT_HTTP_PORT is already listening"; return 1; }
  free_kb=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
  [[ $free_kb =~ ^[0-9]+$ ]] && ((free_kb >= 1048576)) || { ks_log ERROR 'At least 1 GiB free disk space is required'; return 1; }
  ks_log INFO 'Install-node preflight passed (Rocky 9 / x86_64)'
}

ks_caddy_render() {
  local root=$1 port=$2
  printf '{\n  admin 127.0.0.1:2019\n}\n\n'
  printf ':%s {\n' "$port"
  printf '  root * %s\n' "$root"
  printf '  @sensitive path *.key *.pem *.crt *.kubeconfig *.token *.log */.*\n'
  printf '  respond @sensitive 404\n'
  printf '  header {\n    X-Content-Type-Options nosniff\n    Cache-Control "no-store"\n  }\n'
  printf '  log {\n    output stdout\n    format console\n  }\n'
  printf '  file_server\n}\n'
}

ks_caddy_unit() {
  cat <<'UNIT'
[Unit]
Description=Caddy artifact distribution server for ks-deploy-shell
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/data
Environment=XDG_CONFIG_HOME=/var/lib/caddy/config
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/caddy
StateDirectory=caddy
StateDirectoryMode=0750
RuntimeDirectory=caddy
RuntimeDirectoryMode=0750
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
}

ks_caddy_apply() {
  local cache_root=$1 manifest=$2 file sha version arch url archive tempdir backup_dir
  local old_bin='' old_conf='' old_unit='' candidate_bin candidate_conf candidate_unit
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$manifest" caddy)
  archive=$cache_root/$file
  ks_verify_sha256 "$archive" "$sha"
  [[ $arch == amd64 || $arch == x86_64 ]] || { ks_log ERROR 'Caddy artifact architecture mismatch'; return 2; }
  [[ $EUID -eq 0 ]] || { ks_log ERROR 'Caddy installation requires root'; return 77; }
  [[ -d $cache_root ]] || { ks_log ERROR "Artifact cache missing: $cache_root"; return 2; }
  if find "$cache_root" -type l -print -quit | grep -q .; then
    ks_log ERROR 'Artifact cache must not contain symbolic links'; return 2
  fi
  if find "$cache_root" -type f \( -name '*.key' -o -name '*.pem' -o -name '*.crt' -o -name '*.kubeconfig' -o -name '*.token' -o -name '*.log' \) -print -quit | grep -q .; then
    ks_log ERROR 'Sensitive file found in public artifact cache'; return 2
  fi
  tempdir=$(mktemp -d)
  if ! tar -tzf "$archive" > "$tempdir/archive.list" || ! grep -Fxq caddy "$tempdir/archive.list"; then
    rm -rf -- "$tempdir"
    ks_log ERROR 'Caddy archive does not contain the expected root-level caddy binary'
    return 2
  fi
  if ! tar -xOzf "$archive" caddy > "$tempdir/caddy"; then
    rm -rf -- "$tempdir"; return 1
  fi
  chmod 0755 "$tempdir/caddy"
  "$tempdir/caddy" version >/dev/null
  ks_caddy_render "$cache_root" "$ARTIFACT_HTTP_PORT" > "$tempdir/Caddyfile"
  "$tempdir/caddy" validate --config "$tempdir/Caddyfile" --adapter caddyfile
  ks_caddy_unit > "$tempdir/caddy.service"

  if ! getent group caddy >/dev/null 2>&1; then groupadd --system caddy; fi
  if ! id caddy >/dev/null 2>&1; then useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /sbin/nologin caddy; fi
  install -d -o root -g caddy -m 0750 /etc/caddy /var/lib/k8s-deploy-shell /var/lib/k8s-deploy-shell/artifacts
  install -d -o root -g caddy -m 0750 "$cache_root"
  chgrp -R caddy "$cache_root"
  find "$cache_root" -type d -exec chmod 0750 {} +
  find "$cache_root" -type f -exec chmod 0640 {} +

  backup_dir=/var/backups/k8s-deploy-shell/caddy
  old_bin=$(ks_backup_file /usr/local/bin/caddy "$backup_dir" || true)
  old_conf=$(ks_backup_file /etc/caddy/Caddyfile "$backup_dir" || true)
  old_unit=$(ks_backup_file /etc/systemd/system/caddy.service "$backup_dir" || true)
  candidate_bin=$(mktemp /usr/local/bin/.caddy.XXXXXX)
  candidate_conf=$(mktemp /etc/caddy/.Caddyfile.XXXXXX)
  candidate_unit=$(mktemp /etc/systemd/system/.caddy.service.XXXXXX)
  install -m 0755 "$tempdir/caddy" "$candidate_bin"
  install -o root -g caddy -m 0640 "$tempdir/Caddyfile" "$candidate_conf"
  install -o root -g root -m 0644 "$tempdir/caddy.service" "$candidate_unit"
  mv -f -- "$candidate_bin" /usr/local/bin/caddy
  mv -f -- "$candidate_conf" /etc/caddy/Caddyfile
  mv -f -- "$candidate_unit" /etc/systemd/system/caddy.service
  systemctl daemon-reload
  if ! systemctl enable caddy.service || ! systemctl restart caddy.service; then
    [[ -z $old_bin ]] && rm -f /usr/local/bin/caddy || cp -a "$old_bin" /usr/local/bin/caddy
    [[ -z $old_conf ]] && rm -f /etc/caddy/Caddyfile || cp -a "$old_conf" /etc/caddy/Caddyfile
    [[ -z $old_unit ]] && rm -f /etc/systemd/system/caddy.service || cp -a "$old_unit" /etc/systemd/system/caddy.service
    systemctl daemon-reload
    if [[ -z $old_unit ]]; then systemctl disable caddy.service >/dev/null 2>&1 || true; fi
    systemctl restart caddy.service || true
    rm -rf -- "$tempdir"
    ks_log ERROR 'Caddy service activation failed; previous files restored'
    return 1
  fi
  if ! systemctl is-active --quiet caddy.service || ! curl --fail --silent --show-error --max-time 5 --output /dev/null "http://127.0.0.1:$ARTIFACT_HTTP_PORT/$file"; then
    [[ -z $old_bin ]] && rm -f /usr/local/bin/caddy || cp -a "$old_bin" /usr/local/bin/caddy
    [[ -z $old_conf ]] && rm -f /etc/caddy/Caddyfile || cp -a "$old_conf" /etc/caddy/Caddyfile
    [[ -z $old_unit ]] && rm -f /etc/systemd/system/caddy.service || cp -a "$old_unit" /etc/systemd/system/caddy.service
    systemctl daemon-reload
    if [[ -z $old_unit ]]; then systemctl disable caddy.service >/dev/null 2>&1 || true; fi
    systemctl restart caddy.service || true
    rm -rf -- "$tempdir"
    ks_log ERROR 'Caddy health check failed; previous files restored'
    return 1
  fi
  rm -rf -- "$tempdir"
  ks_log INFO "Caddy artifact server is active on TCP $ARTIFACT_HTTP_PORT"
}

case $COMMAND in
  preflight) ks_preflight_install_node ;;
  verify-cache)
    ks_cache_root
    ks_manifest_verify_cache "$ROOT/artifacts/manifest.tsv" "$REPLY"
    ;;
  caddy)
    ks_cache_root
    CACHE_ROOT=$REPLY
    MANIFEST=$ROOT/artifacts/manifest.tsv
    IFS=$'\t' read -r FILE SHA VERSION ARCH URL < <(ks_manifest_lookup "$MANIFEST" caddy)
    if [[ $APPLY == true && ${KS_DRY_RUN:-true} == false ]]; then
      ks_with_lock /run/lock/ks-deploy-shell-caddy.lock ks_caddy_apply "$CACHE_ROOT" "$MANIFEST"
    else
      ks_log INFO 'Caddy preview only; no files, users, permissions or services changed'
      printf 'Artifact: caddy %s (%s)\nFile: %s\nURL: %s\nSHA256: %s\nCache: %s\nListen: :%s\n' "$VERSION" "$ARCH" "$FILE" "$URL" "$SHA" "$CACHE_ROOT" "$ARTIFACT_HTTP_PORT"
    fi
    ;;
esac
