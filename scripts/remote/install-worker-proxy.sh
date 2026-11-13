#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 18)) || { echo 'Expected 18 worker-proxy arguments' >&2; exit 2; }
NGINX_VERSION=$1; ARCHIVE_NAME=$2; ARCHIVE_SHA=$3; HTTP_URL=$4
NGINX_BIN=$5; CONFIG_DIR=$6; LOG_DIR=$7; PID_FILE=$8
API_PORT=$9; MASTER_ADDRS=${10}; WORKER_CONNECTIONS=${11}; CONNECT_TIMEOUT=${12}
PROXY_TIMEOUT=${13}; MAX_FAILS=${14}; FAIL_TIMEOUT=${15}; NEXT_TRIES=${16}
NEXT_TIMEOUT=${17}; NODE_NAME=${18}
if [[ $EUID -ne 0 ]]; then command -v sudo >/dev/null 2>&1 || { echo 'sudo is required for non-root SSH users' >&2; exit 127; }; exec sudo -n bash "$0" "$@"; fi
for cmd in curl sha256sum tar install systemctl cmp mktemp rm awk grep stat sed tr id useradd ss ldd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing remote command: $cmd" >&2; exit 127; }
done
[[ -r /etc/os-release ]] || exit 2
remote_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
remote_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $remote_os == rocky && ${remote_version%%.*} == 9 && $(uname -m) == x86_64 ]] || { echo 'Target must be Rocky Linux 9 / x86_64' >&2; exit 2; }
[[ $NGINX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ $ARCHIVE_NAME == "nginx-stream-$NGINX_VERSION-linux-amd64.tar.gz" ]] || exit 2
[[ $ARCHIVE_SHA =~ ^[a-fA-F0-9]{64}$ ]] || exit 2
[[ $HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
[[ $API_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$API_PORT > 0 && 10#$API_PORT < 65536)) || exit 2
[[ $WORKER_CONNECTIONS =~ ^[0-9]+$ ]] && ((10#$WORKER_CONNECTIONS >= 256 && 10#$WORKER_CONNECTIONS <= 65535)) || exit 2
[[ $MAX_FAILS =~ ^[0-9]+$ ]] && ((10#$MAX_FAILS >= 1 && 10#$MAX_FAILS <= 10)) || exit 2
[[ $NEXT_TRIES =~ ^[0-9]+$ ]] && ((10#$NEXT_TRIES >= 1 && 10#$NEXT_TRIES <= 10)) || exit 2
for duration in "$CONNECT_TIMEOUT" "$PROXY_TIMEOUT" "$FAIL_TIMEOUT" "$NEXT_TIMEOUT"; do [[ $duration =~ ^[1-9][0-9]*(ms|s|m|h)$ ]] || exit 2; done
[[ $NODE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
for path in "$NGINX_BIN" "$CONFIG_DIR" "$LOG_DIR" "$PID_FILE"; do
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *'/../'* && $path != */.. && $path != / ]] || exit 2
done
[[ ! -L $NGINX_BIN && ! -L $CONFIG_DIR && ! -L $LOG_DIR && ! -L $PID_FILE ]] || { echo 'Symlinked Nginx path rejected' >&2; exit 2; }
IFS=, read -r -a MASTER_IPS <<< "$MASTER_ADDRS"
(("${#MASTER_IPS[@]}" >= 1 && "${#MASTER_IPS[@]}" <= 9)) || exit 2
for ip in "${MASTER_IPS[@]}"; do
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 2
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || exit 2; done
done
for ((i=0; i<${#MASTER_IPS[@]}; i++)); do
  for ((j=i+1; j<${#MASTER_IPS[@]}; j++)); do [[ ${MASTER_IPS[i]} != "${MASTER_IPS[j]}" ]] || exit 2; done
done
CONFIG_FILE=$CONFIG_DIR/nginx.conf
UNIT_FILE=/etc/systemd/system/k8s-api-proxy.service
BIN_DIR=$(dirname -- "$NGINX_BIN")
PID_DIR=$(dirname -- "$PID_FILE")
for path in "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"; do [[ ! -L $path ]] || { echo "Symlinked directory rejected: $path" >&2; exit 2; }; done
if ! id nginx >/dev/null 2>&1; then useradd -r -M -s /sbin/nologin nginx; fi
WORK=$(mktemp -d /var/tmp/ks-worker-proxy.XXXXXX)
cleanup() { rm -rf -- "$WORK"; rm -f -- "$0"; }
trap cleanup EXIT
curl --fail --silent --show-error --location --proto '=http' --proto-redir '=http' --max-time 600 --output "$WORK/$ARCHIVE_NAME" "$HTTP_URL/$ARCHIVE_NAME"
printf '%s  %s\n' "$ARCHIVE_SHA" "$WORK/$ARCHIVE_NAME" | sha256sum -c -
tar -tvzf "$WORK/$ARCHIVE_NAME" | awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' || { echo 'Nginx bundle contains a link or special file' >&2; exit 2; }
while IFS= read -r entry; do
  case $entry in ./|./bin/|./bin/nginx|./build-info.txt) ;;
    *) echo "Unexpected Nginx bundle path: $entry" >&2; exit 2 ;;
  esac
done < <(tar -tzf "$WORK/$ARCHIVE_NAME")
tar -xzf "$WORK/$ARCHIVE_NAME" --no-same-owner --no-same-permissions -C "$WORK"
[[ -f $WORK/bin/nginx && -x $WORK/bin/nginx && -f $WORK/build-info.txt && ! -L $WORK/bin/nginx ]] || exit 2
grep -Fq "nginx_version=$NGINX_VERSION" "$WORK/build-info.txt"
"$WORK/bin/nginx" -v 2>&1 | grep -Fq "nginx/$NGINX_VERSION"
"$WORK/bin/nginx" -V 2>&1 | grep -Fq -- '--with-stream'
"$WORK/bin/nginx" -V 2>&1 | grep -Fq -- '--without-http'
ldd "$WORK/bin/nginx" > "$WORK/ldd.txt"
! grep -Fq 'not found' "$WORK/ldd.txt" || { echo 'Nginx bundle has unresolved shared libraries' >&2; exit 2; }

config_tmp=$WORK/nginx.conf
{
  printf '# Managed by ks-deploy-shell. TCP passthrough only; API TLS terminates on kube-apiserver.\n'
  printf 'user nginx;\nworker_processes auto;\nerror_log %s/error.log warn;\npid %s;\n' "$LOG_DIR" "$PID_FILE"
  printf 'events {\n  worker_connections %s;\n}\n' "$WORKER_CONNECTIONS"
  printf 'stream {\n  upstream kube_apiserver {\n    least_conn;\n'
  for ip in "${MASTER_IPS[@]}"; do
    printf '    server %s:%s max_fails=%s fail_timeout=%s;\n' "$ip" "$API_PORT" "$MAX_FAILS" "$FAIL_TIMEOUT"
  done
  printf '  }\n  server {\n    listen 127.0.0.1:%s;\n' "$API_PORT"
  printf '    proxy_connect_timeout %s;\n    proxy_timeout %s;\n' "$CONNECT_TIMEOUT" "$PROXY_TIMEOUT"
  printf '    proxy_next_upstream on;\n    proxy_next_upstream_tries %s;\n    proxy_next_upstream_timeout %s;\n' "$NEXT_TRIES" "$NEXT_TIMEOUT"
  printf '    proxy_socket_keepalive on;\n    proxy_pass kube_apiserver;\n  }\n}\n'
} > "$config_tmp"
install -d -o root -g root -m 0755 "$BIN_DIR"
install -d -o root -g root -m 0750 "$CONFIG_DIR"
install -d -o nginx -g nginx -m 0750 "$LOG_DIR"
[[ -d $PID_DIR ]] || install -d -o root -g root -m 0755 "$PID_DIR"
"$WORK/bin/nginx" -t -c "$config_tmp"
unit_tmp=$WORK/k8s-api-proxy.service
cat > "$unit_tmp" <<UNIT
[Unit]
Description=Kubernetes API local TCP proxy (Nginx stream)
Documentation=https://kubernetes.io/docs/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=forking
PIDFile=$PID_FILE
ExecStartPre=$NGINX_BIN -t -c $CONFIG_FILE
ExecStart=$NGINX_BIN -c $CONFIG_FILE
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
if [[ -e $NGINX_BIN ]]; then
  [[ -f $NGINX_BIN && ! -L $NGINX_BIN ]] || exit 2
  cmp -s "$WORK/bin/nginx" "$NGINX_BIN" || { echo 'Existing Nginx binary differs; refusing replacement' >&2; exit 73; }
fi
if [[ -e $CONFIG_FILE ]]; then
  [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || exit 2
  cmp -s "$config_tmp" "$CONFIG_FILE" || { echo 'Existing Nginx config differs; refusing overwrite' >&2; exit 73; }
fi
if [[ -e $UNIT_FILE ]]; then
  [[ -f $UNIT_FILE && ! -L $UNIT_FILE ]] || exit 2
  cmp -s "$unit_tmp" "$UNIT_FILE" || { echo 'Existing Nginx systemd unit differs; refusing overwrite' >&2; exit 73; }
fi
if ss -lntH | awk -v endpoint="127.0.0.1:$API_PORT" '$4 == endpoint { found=1 } END { exit !found }'; then
  systemctl is-active --quiet k8s-api-proxy.service || { echo 'Local API port is already occupied by another process' >&2; exit 73; }
fi
[[ -e $NGINX_BIN ]] || install -o root -g root -m 0755 "$WORK/bin/nginx" "$NGINX_BIN"
[[ -e $CONFIG_FILE ]] || install -o root -g root -m 0640 "$config_tmp" "$CONFIG_FILE"
[[ -e $UNIT_FILE ]] || install -o root -g root -m 0644 "$unit_tmp" "$UNIT_FILE"
if command -v restorecon >/dev/null 2>&1; then restorecon -RF "$NGINX_BIN" "$CONFIG_DIR" "$LOG_DIR"; fi
"$NGINX_BIN" -t -c "$CONFIG_FILE"
systemctl daemon-reload
if ! systemctl enable --now k8s-api-proxy.service; then
  systemctl disable --now k8s-api-proxy.service >/dev/null 2>&1 || true
  echo 'Failed to enable/start k8s-api-proxy.service' >&2
  exit 1
fi
systemctl is-active --quiet k8s-api-proxy.service || exit 1
ss -lntH | awk -v endpoint="127.0.0.1:$API_PORT" '$4 == endpoint { found=1 } END { exit !found }' || { echo 'Nginx did not bind the local API endpoint' >&2; exit 1; }
echo "Nginx $NGINX_VERSION stream proxy is active on 127.0.0.1:$API_PORT for $NODE_NAME; upstream TLS remains end-to-end"
