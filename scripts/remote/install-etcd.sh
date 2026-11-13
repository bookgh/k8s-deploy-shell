#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 15)) || { echo 'Expected 15 validated deployment arguments' >&2; exit 2; }
ETCD_VERSION=$1
ETCD_FILE=$2
ETCD_SHA=$3
ETCD_HTTP_URL=$4
ETCD_DATA_DIR=$5
ETCD_CONFIG_DIR=$6
ETCD_BACKUP_DIR=$7
ETCD_NAME=$8
ETCD_ADDRESS=$9
ETCD_INITIAL_CLUSTER=${10}
ETCD_CLIENT_PORT=${11}
ETCD_PEER_PORT=${12}
ETCD_INITIAL_CLUSTER_TOKEN=${13}
ETCD_LOG_LEVEL=${14}
ETCD_AUTO_COMPACTION_RETENTION=${15}

[[ $EUID -eq 0 ]] || exec sudo -n bash "$0" "$@"
for command_name in curl tar sha256sum systemctl install find cmp stat id getent useradd groupadd chown chmod mv cp mktemp date grep sed tr bash; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Missing remote command: $command_name" >&2; exit 127; }
done
[[ $ETCD_VERSION == 3.7.3 && $ETCD_FILE == "etcd-v$ETCD_VERSION-linux-amd64.tar.gz" ]] || exit 2
[[ $ETCD_SHA =~ ^[a-fA-F0-9]{64}$ ]] || exit 2
[[ $ETCD_HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
[[ $ETCD_DATA_DIR =~ ^/[A-Za-z0-9._/-]+$ && $ETCD_DATA_DIR != *'/../'* && $ETCD_DATA_DIR != */.. ]] || exit 2
[[ $ETCD_CONFIG_DIR =~ ^/[A-Za-z0-9._/-]+$ && $ETCD_CONFIG_DIR != *'/../'* && $ETCD_CONFIG_DIR != */.. ]] || exit 2
[[ $ETCD_BACKUP_DIR =~ ^/[A-Za-z0-9._/-]+$ && $ETCD_BACKUP_DIR != *'/../'* && $ETCD_BACKUP_DIR != */.. ]] || exit 2
[[ $ETCD_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
[[ $ETCD_ADDRESS =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 2
[[ $ETCD_CLIENT_PORT =~ ^[0-9]{1,5}$ && $ETCD_PEER_PORT =~ ^[0-9]{1,5}$ ]] || exit 2
((10#$ETCD_CLIENT_PORT > 0 && 10#$ETCD_CLIENT_PORT < 65536 && 10#$ETCD_PEER_PORT > 0 && 10#$ETCD_PEER_PORT < 65536 && ETCD_CLIENT_PORT != ETCD_PEER_PORT)) || exit 2
[[ $ETCD_INITIAL_CLUSTER_TOKEN =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || exit 2
[[ $ETCD_LOG_LEVEL == info || $ETCD_LOG_LEVEL == warn || $ETCD_LOG_LEVEL == error || $ETCD_LOG_LEVEL == debug ]] || exit 2
[[ $ETCD_AUTO_COMPACTION_RETENTION =~ ^[0-9]+[hms]$ ]] || exit 2
[[ $ETCD_INITIAL_CLUSTER =~ ^[A-Za-z0-9._-]+=(https://[0-9.]+:[0-9]+)(,[A-Za-z0-9._-]+=(https://[0-9.]+:[0-9]+))*$ ]] || exit 2
[[ -r /etc/os-release ]] || exit 2
remote_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
remote_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $remote_os == rocky && ${remote_version%%.*} == 9 && $(uname -m) == x86_64 ]] || { echo 'Target must be Rocky Linux 9 / x86_64' >&2; exit 2; }

ETCD_ENV_FILE=$ETCD_CONFIG_DIR/etcd.env
ETCD_UNIT_FILE=/etc/systemd/system/etcd.service
ETCD_SERVER_KEY=$ETCD_CONFIG_DIR/pki/server.key
ETCD_PEER_KEY=$ETCD_CONFIG_DIR/pki/peer.key
ETCD_ENV_CONTENT=$(cat <<ENV
ETCD_NAME=$ETCD_NAME
ETCD_DATA_DIR=$ETCD_DATA_DIR
ETCD_LISTEN_PEER_URLS=https://$ETCD_ADDRESS:$ETCD_PEER_PORT
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$ETCD_ADDRESS:$ETCD_PEER_PORT
ETCD_LISTEN_CLIENT_URLS=https://127.0.0.1:$ETCD_CLIENT_PORT,https://$ETCD_ADDRESS:$ETCD_CLIENT_PORT
ETCD_ADVERTISE_CLIENT_URLS=https://$ETCD_ADDRESS:$ETCD_CLIENT_PORT
ETCD_INITIAL_CLUSTER=$ETCD_INITIAL_CLUSTER
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$ETCD_INITIAL_CLUSTER_TOKEN
ETCD_CERT_FILE=$ETCD_CONFIG_DIR/pki/server.crt
ETCD_KEY_FILE=$ETCD_CONFIG_DIR/pki/server.key
ETCD_TRUSTED_CA_FILE=$ETCD_CONFIG_DIR/pki/ca.crt
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CERT_FILE=$ETCD_CONFIG_DIR/pki/peer.crt
ETCD_PEER_KEY_FILE=$ETCD_CONFIG_DIR/pki/peer.key
ETCD_PEER_TRUSTED_CA_FILE=$ETCD_CONFIG_DIR/pki/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
ETCD_LOG_LEVEL=$ETCD_LOG_LEVEL
ETCD_LOG_OUTPUTS=stderr
ETCD_AUTO_COMPACTION_MODE=periodic
ETCD_AUTO_COMPACTION_RETENTION=$ETCD_AUTO_COMPACTION_RETENTION
ENV
)
ETCD_UNIT_CONTENT=$(cat <<UNIT
[Unit]
Description=etcd distributed key-value store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
Group=etcd
EnvironmentFile=$ETCD_ENV_FILE
ExecStart=/usr/local/bin/etcd \\
  --name=${ETCD_NAME} \\
  --data-dir=${ETCD_DATA_DIR} \\
  --listen-peer-urls=${ETCD_LISTEN_PEER_URLS} \\
  --initial-advertise-peer-urls=${ETCD_INITIAL_ADVERTISE_PEER_URLS} \\
  --listen-client-urls=${ETCD_LISTEN_CLIENT_URLS} \\
  --advertise-client-urls=${ETCD_ADVERTISE_CLIENT_URLS} \\
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \\
  --initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE} \\
  --initial-cluster-token=${ETCD_INITIAL_CLUSTER_TOKEN} \\
  --cert-file=${ETCD_CERT_FILE} \\
  --key-file=${ETCD_KEY_FILE} \\
  --trusted-ca-file=${ETCD_TRUSTED_CA_FILE} \\
  --client-cert-auth=${ETCD_CLIENT_CERT_AUTH} \\
  --peer-cert-file=${ETCD_PEER_CERT_FILE} \\
  --peer-key-file=${ETCD_PEER_KEY_FILE} \\
  --peer-trusted-ca-file=${ETCD_PEER_TRUSTED_CA_FILE} \\
  --peer-client-cert-auth=${ETCD_PEER_CLIENT_CERT_AUTH} \\
  --logger=zap \\
  --log-level=${ETCD_LOG_LEVEL} \\
  --log-outputs=${ETCD_LOG_OUTPUTS} \\
  --auto-compaction-mode=${ETCD_AUTO_COMPACTION_MODE} \\
  --auto-compaction-retention=${ETCD_AUTO_COMPACTION_RETENTION}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=$ETCD_DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT
)

if [[ -L $ETCD_DATA_DIR || -L $ETCD_CONFIG_DIR || -L $ETCD_CONFIG_DIR/pki ]]; then echo 'Symlinked etcd path rejected' >&2; exit 2; fi
if [[ -d $ETCD_DATA_DIR ]] && find "$ETCD_DATA_DIR" -mindepth 1 -print -quit | grep -q .; then
  if systemctl is-active --quiet etcd.service \
    && /usr/local/bin/etcd --version 2>&1 | grep -Fq "$ETCD_VERSION" \
    && cmp -s "$ETCD_ENV_FILE" <(printf '%s\n' "$ETCD_ENV_CONTENT") \
    && cmp -s "$ETCD_UNIT_FILE" <(printf '%s\n' "$ETCD_UNIT_CONTENT"); then
    echo 'Existing etcd member is active with matching version and configuration; no changes made'
    rm -f -- "$0"
    exit 0
  fi
  echo 'Refusing to modify a non-empty etcd data directory or existing member' >&2
  exit 73
fi
if systemctl is-active --quiet etcd.service; then echo 'etcd service active but data directory is empty; refusing ambiguous state' >&2; exit 73; fi
[[ -f $ETCD_SERVER_KEY && -f $ETCD_PEER_KEY && -f $ETCD_CONFIG_DIR/pki/ca.crt && -f $ETCD_CONFIG_DIR/pki/server.crt && -f $ETCD_CONFIG_DIR/pki/peer.crt && -f $ETCD_CONFIG_DIR/pki/healthcheck-client.key ]] || { echo 'etcd PKI not distributed; run distribute-pki first' >&2; exit 2; }
[[ $(stat -c '%a' "$ETCD_SERVER_KEY") == 600 && $(stat -c '%a' "$ETCD_PEER_KEY") == 600 && $(stat -c '%a' "$ETCD_CONFIG_DIR/pki/healthcheck-client.key") == 600 ]] || { echo 'etcd private key mode must be 0600' >&2; exit 2; }
[[ $(stat -c '%a' "$ETCD_CONFIG_DIR/pki") == 750 ]] || { echo 'etcd PKI directory must be mode 0750' >&2; exit 2; }
getent group etcd >/dev/null 2>&1 || groupadd --system etcd
id etcd >/dev/null 2>&1 || useradd --system --gid etcd --home-dir "$ETCD_DATA_DIR" --create-home --shell /sbin/nologin etcd
REMOTE_TMP=$(mktemp -d /var/tmp/ks-etcd.XXXXXX)
cleanup() { rm -rf -- "$REMOTE_TMP"; }
trap cleanup EXIT
curl --fail --silent --show-error --location --proto '=http' --max-time 300 --output "$REMOTE_TMP/$ETCD_FILE" "$ETCD_HTTP_URL/$ETCD_FILE"
printf '%s  %s\n' "$ETCD_SHA" "$REMOTE_TMP/$ETCD_FILE" | sha256sum -c -
tar -tzf "$REMOTE_TMP/$ETCD_FILE" > "$REMOTE_TMP/archive.list"
if grep -E '(^/|(^|/)\.\.(/|$))' "$REMOTE_TMP/archive.list"; then echo 'Unsafe etcd archive path' >&2; exit 2; fi
archive_root="etcd-v$ETCD_VERSION-linux-amd64"
for binary in etcd etcdctl etcdutl; do grep -Fxq "$archive_root/$binary" "$REMOTE_TMP/archive.list" || { echo "Missing $binary in archive" >&2; exit 2; }; done
tar -xzf "$REMOTE_TMP/$ETCD_FILE" -C "$REMOTE_TMP" --no-same-owner --no-same-permissions
for binary in etcd etcdctl etcdutl; do [[ -x $REMOTE_TMP/$archive_root/$binary ]] || exit 2; done
install -d -o etcd -g etcd -m 0700 "$ETCD_DATA_DIR"
install -d -o root -g etcd -m 0750 "$ETCD_CONFIG_DIR" "$ETCD_CONFIG_DIR/pki"
install -d -o root -g root -m 0700 "$ETCD_BACKUP_DIR/.ks-deploy-shell"
backup_dir=$ETCD_BACKUP_DIR/.ks-deploy-shell/$(date -u '+%Y%m%dT%H%M%SZ')
install -d -o root -g root -m 0700 "$backup_dir"
for file in /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/etcdutl "$ETCD_ENV_FILE" "$ETCD_UNIT_FILE"; do [[ ! -e $file ]] || cp -a -- "$file" "$backup_dir/"; done
for binary in etcd etcdctl etcdutl; do
  install -m 0755 "$REMOTE_TMP/$archive_root/$binary" "/usr/local/bin/.$binary.new"
  mv -f -- "/usr/local/bin/.$binary.new" "/usr/local/bin/$binary"
done
printf '%s\n' "$ETCD_ENV_CONTENT" > "$REMOTE_TMP/etcd.env"
printf '%s\n' "$ETCD_UNIT_CONTENT" > "$REMOTE_TMP/etcd.service"
install -o root -g etcd -m 0640 "$REMOTE_TMP/etcd.env" "$ETCD_ENV_FILE.new"
install -o root -g root -m 0644 "$REMOTE_TMP/etcd.service" "$ETCD_UNIT_FILE.new"
mv -f -- "$ETCD_ENV_FILE.new" "$ETCD_ENV_FILE"
mv -f -- "$ETCD_UNIT_FILE.new" "$ETCD_UNIT_FILE"
chown -R root:etcd "$ETCD_CONFIG_DIR"
chmod 0750 "$ETCD_CONFIG_DIR" "$ETCD_CONFIG_DIR/pki"
chown etcd:etcd "$ETCD_SERVER_KEY" "$ETCD_PEER_KEY" "$ETCD_CONFIG_DIR/pki/healthcheck-client.key"
chmod 0600 "$ETCD_SERVER_KEY" "$ETCD_PEER_KEY" "$ETCD_CONFIG_DIR/pki/healthcheck-client.key"
systemctl daemon-reload
if ! systemctl enable --now etcd.service || ! systemctl is-active --quiet etcd.service; then
  for binary in etcd etcdctl etcdutl; do
    if [[ -f $backup_dir/$binary ]]; then cp -a "$backup_dir/$binary" "/usr/local/bin/$binary"; else rm -f "/usr/local/bin/$binary"; fi
  done
  if [[ -f $backup_dir/etcd.env ]]; then cp -a "$backup_dir/etcd.env" "$ETCD_ENV_FILE"; else rm -f "$ETCD_ENV_FILE"; fi
  if [[ -f $backup_dir/etcd.service ]]; then cp -a "$backup_dir/etcd.service" "$ETCD_UNIT_FILE"; else rm -f "$ETCD_UNIT_FILE"; fi
  systemctl daemon-reload
  systemctl restart etcd.service || true
  echo 'etcd activation failed; previous binaries/configuration restored; data directory retained' >&2
  exit 1
fi
/usr/local/bin/etcd --version
echo 'etcd systemd service is active; cluster quorum is checked after all members start'
rm -f -- "$0"
