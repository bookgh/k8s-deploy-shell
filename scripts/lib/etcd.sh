#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_etcd_cluster_string() {
  local file=$1 node role address result=''
  local -a members=()
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  (("${#members[@]}" > 0 && "${#members[@]}" % 2 == 1)) || return 2
  for node in "${members[@]}"; do
    IFS=
    [[ $role == master ]] || { ks_log ERROR "etcd member is not a Master: $node"; return 2; }
    [[ -z $result ]] || result+=,
    result+="$node=https://$address:$ETCD_PEER_PORT"
  done
  REPLY=$result
}
ks_etcd_render_env() {
  local node=$1 address=$2 cluster=$3
  cat <<ENV
ETCD_NAME=$node
ETCD_DATA_DIR=$ETCD_DATA_DIR
ETCD_LISTEN_PEER_URLS=https://$address:$ETCD_PEER_PORT
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$address:$ETCD_PEER_PORT
ETCD_LISTEN_CLIENT_URLS=https://127.0.0.1:$ETCD_CLIENT_PORT,https://$address:$ETCD_CLIENT_PORT
ETCD_ADVERTISE_CLIENT_URLS=https://$address:$ETCD_CLIENT_PORT
ETCD_INITIAL_CLUSTER=$cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$CLUSTER_NAME
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
}
ks_etcd_render_unit() {
  local config_dir=$ETCD_CONFIG_DIR data_dir=$ETCD_DATA_DIR
  printf '[Unit]\nDescription=etcd distributed key-value store\nDocumentation=https://etcd.io/docs/\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=notify\nUser=etcd\nGroup=etcd\n'
  printf 'EnvironmentFile=%s/etcd.env\n' "$config_dir"
  cat <<'UNIT'
ExecStart=/usr/local/bin/etcd \
  --name=${ETCD_NAME} \
  --data-dir=${ETCD_DATA_DIR} \
  --listen-peer-urls=${ETCD_LISTEN_PEER_URLS} \
  --initial-advertise-peer-urls=${ETCD_INITIAL_ADVERTISE_PEER_URLS} \
  --listen-client-urls=${ETCD_LISTEN_CLIENT_URLS} \
  --advertise-client-urls=${ETCD_ADVERTISE_CLIENT_URLS} \
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \
  --initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE} \
  --initial-cluster-token=${ETCD_INITIAL_CLUSTER_TOKEN} \
  --cert-file=${ETCD_CERT_FILE} \
  --key-file=${ETCD_KEY_FILE} \
  --trusted-ca-file=${ETCD_TRUSTED_CA_FILE} \
  --client-cert-auth=${ETCD_CLIENT_CERT_AUTH} \
  --peer-cert-file=${ETCD_PEER_CERT_FILE} \
  --peer-key-file=${ETCD_PEER_KEY_FILE} \
  --peer-trusted-ca-file=${ETCD_PEER_TRUSTED_CA_FILE} \
  --peer-client-cert-auth=${ETCD_PEER_CLIENT_CERT_AUTH} \
  --logger=zap \
  --log-level=${ETCD_LOG_LEVEL} \
  --log-outputs=${ETCD_LOG_OUTPUTS} \
  --auto-compaction-mode=${ETCD_AUTO_COMPACTION_MODE} \
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
UNIT
  printf 'ReadWritePaths=%s\n' "$data_dir"
  cat <<'UNIT_TAIL'

[Install]
WantedBy=multi-user.target
UNIT_TAIL
}
ks_etcd_validate_pki() {
  local root=$1 node file
  local -a members=()
  for file in "$root/etcd/ca.pem" "$root/etcd/clients/healthcheck-client.pem" "$root/etcd/clients/healthcheck-client-key.pem"; do
    [[ -f $file && ! -L $file ]] || { ks_log ERROR "Missing etcd PKI material: $file"; return 2; }
  done
  [[ $(stat -c '%a' "$root/etcd/clients/healthcheck-client-key.pem") == 600 ]] || return 2
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  for node in "${members[@]}"; do
    for file in "$root/etcd/members/$node/server.pem" "$root/etcd/members/$node/server-key.pem" "$root/etcd/members/$node/peer.pem" "$root/etcd/members/$node/peer-key.pem"; do
      [[ -f $file && ! -L $file ]] || { ks_log ERROR "Missing etcd member PKI material: $file"; return 2; }
    done
    [[ $(stat -c '%a' "$root/etcd/members/$node/server-key.pem") == 600 && $(stat -c '%a' "$root/etcd/members/$node/peer-key.pem") == 600 ]] || return 2
  done
}
\t' read -r role address _ _ < <(ks_node_lookup "$file" "$node")
    [[ $role == master ]] || { ks_log ERROR "etcd member is not a Master: $node"; return 2; }
    [[ -z $result ]] || result+=,
    result+="$node=https://$address:$ETCD_PEER_PORT"
  done
  REPLY=$result
}
ks_etcd_render_env() {
  local node=$1 address=$2 cluster=$3
  cat <<ENV
ETCD_NAME=$node
ETCD_DATA_DIR=$ETCD_DATA_DIR
ETCD_LISTEN_PEER_URLS=https://$address:$ETCD_PEER_PORT
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$address:$ETCD_PEER_PORT
ETCD_LISTEN_CLIENT_URLS=https://127.0.0.1:$ETCD_CLIENT_PORT,https://$address:$ETCD_CLIENT_PORT
ETCD_ADVERTISE_CLIENT_URLS=https://$address:$ETCD_CLIENT_PORT
ETCD_INITIAL_CLUSTER=$cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$CLUSTER_NAME
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
}
ks_etcd_render_unit() {
  local config_dir=$ETCD_CONFIG_DIR data_dir=$ETCD_DATA_DIR
  printf '[Unit]\nDescription=etcd distributed key-value store\nDocumentation=https://etcd.io/docs/\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=notify\nUser=etcd\nGroup=etcd\n'
  printf 'EnvironmentFile=%s/etcd.env\n' "$config_dir"
  cat <<'UNIT'
ExecStart=/usr/local/bin/etcd \
  --name=${ETCD_NAME} \
  --data-dir=${ETCD_DATA_DIR} \
  --listen-peer-urls=${ETCD_LISTEN_PEER_URLS} \
  --initial-advertise-peer-urls=${ETCD_INITIAL_ADVERTISE_PEER_URLS} \
  --listen-client-urls=${ETCD_LISTEN_CLIENT_URLS} \
  --advertise-client-urls=${ETCD_ADVERTISE_CLIENT_URLS} \
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \
  --initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE} \
  --initial-cluster-token=${ETCD_INITIAL_CLUSTER_TOKEN} \
  --cert-file=${ETCD_CERT_FILE} \
  --key-file=${ETCD_KEY_FILE} \
  --trusted-ca-file=${ETCD_TRUSTED_CA_FILE} \
  --client-cert-auth=${ETCD_CLIENT_CERT_AUTH} \
  --peer-cert-file=${ETCD_PEER_CERT_FILE} \
  --peer-key-file=${ETCD_PEER_KEY_FILE} \
  --peer-trusted-ca-file=${ETCD_PEER_TRUSTED_CA_FILE} \
  --peer-client-cert-auth=${ETCD_PEER_CLIENT_CERT_AUTH} \
  --logger=zap \
  --log-level=${ETCD_LOG_LEVEL} \
  --log-outputs=${ETCD_LOG_OUTPUTS} \
  --auto-compaction-mode=${ETCD_AUTO_COMPACTION_MODE} \
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
UNIT
  printf 'ReadWritePaths=%s\n' "$data_dir"
  cat <<'UNIT_TAIL'

[Install]
WantedBy=multi-user.target
UNIT_TAIL
}
ks_etcd_validate_pki() {
  local root=$1 node file
  local -a members=()
  for file in "$root/etcd/ca.pem" "$root/etcd/clients/healthcheck-client.pem" "$root/etcd/clients/healthcheck-client-key.pem"; do
    [[ -f $file && ! -L $file ]] || { ks_log ERROR "Missing etcd PKI material: $file"; return 2; }
  done
  [[ $(stat -c '%a' "$root/etcd/clients/healthcheck-client-key.pem") == 600 ]] || return 2
  IFS=$' ,\t' read -r -a members <<< "$ETCD_NODES"
  for node in "${members[@]}"; do
    for file in "$root/etcd/members/$node/server.pem" "$root/etcd/members/$node/server-key.pem" "$root/etcd/members/$node/peer.pem" "$root/etcd/members/$node/peer-key.pem"; do
      [[ -f $file && ! -L $file ]] || { ks_log ERROR "Missing etcd member PKI material: $file"; return 2; }
    done
    [[ $(stat -c '%a' "$root/etcd/members/$node/server-key.pem") == 600 && $(stat -c '%a' "$root/etcd/members/$node/peer-key.pem") == 600 ]] || return 2
  done
}
