#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 12)) || { echo 'Expected 12 kubelet/proxy arguments' >&2; exit 2; }
K8S_VERSION=$1; KUBELET_FILE=$2; KUBELET_SHA=$3; KUBE_PROXY_FILE=$4; KUBE_PROXY_SHA=$5
HTTP_URL=$6; BIN_DIR=$7; CONFIG_DIR=$8; KUBELET_DATA_DIR=$9; CONTAINERD_STATE_DIR=${10}; NODE_NAME=${11}; NODE_IP=${12}
if [[ $EUID -ne 0 ]]; then command -v sudo >/dev/null 2>&1 || { echo 'sudo is required for non-root SSH users' >&2; exit 127; }; exec sudo -n bash "$0" "$@"; fi
for cmd in curl sha256sum install systemctl cmp mktemp rm openssl awk grep stat sed tr; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing remote command: $cmd" >&2; exit 127; }; done
[[ -r /etc/os-release ]] || exit 2
remote_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
remote_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $remote_os == rocky && ${remote_version%%.*} == 9 && $(uname -m) == x86_64 ]] || { echo 'Target must be Rocky Linux 9 / x86_64' >&2; exit 2; }
[[ $K8S_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $KUBELET_FILE == kubelet && $KUBE_PROXY_FILE == kube-proxy ]] || exit 2
for digest in "$KUBELET_SHA" "$KUBE_PROXY_SHA"; do [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || exit 2; done
[[ $HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
[[ $NODE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
[[ $NODE_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 2
IFS=. read -r -a octets <<< "$NODE_IP"
for octet in "${octets[@]}"; do [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || exit 2; done
for path in "$BIN_DIR" "$CONFIG_DIR" "$KUBELET_DATA_DIR" "$CONTAINERD_STATE_DIR"; do
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *'/../'* && $path != */.. && $path != / ]] || exit 2
  [[ ! -L $path ]] || { echo "Symlinked directory rejected: $path" >&2; exit 2; }
done
[[ ! -L $CONFIG_DIR/pki && ! -L $KUBELET_DATA_DIR/pki ]] || { echo 'Symlinked PKI directory rejected' >&2; exit 2; }
systemctl is-active --quiet containerd.service || { echo 'containerd is not active; deploy runtime first' >&2; exit 78; }
[[ -S $CONTAINERD_STATE_DIR/containerd.sock ]] || { echo 'containerd CRI socket is missing' >&2; exit 78; }
if systemctl is-active --quiet kubelet.service || systemctl is-active --quiet kube-proxy.service || systemctl is-enabled --quiet kubelet.service || systemctl is-enabled --quiet kube-proxy.service; then
  echo 'kubelet or kube-proxy is active/enabled; refusing in-place replacement' >&2
  exit 73
fi
CA=$CONFIG_DIR/pki/ca.crt
KUBELET_CLIENT_CERT=$KUBELET_DATA_DIR/pki/kubelet-client.crt
KUBELET_CLIENT_KEY=$KUBELET_DATA_DIR/pki/kubelet-client.key
KUBELET_SERVING_CERT=$KUBELET_DATA_DIR/pki/kubelet-serving.crt
KUBELET_SERVING_KEY=$KUBELET_DATA_DIR/pki/kubelet-serving.key
KUBE_PROXY_CERT=$CONFIG_DIR/pki/kube-proxy.crt
KUBE_PROXY_KEY=$CONFIG_DIR/pki/kube-proxy.key
for file in "$CA" "$KUBELET_CLIENT_CERT" "$KUBELET_CLIENT_KEY" "$KUBELET_SERVING_CERT" "$KUBELET_SERVING_KEY" "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY"; do
  [[ -f $file && ! -L $file ]] || { echo "Required PKI file missing or unsafe: $file" >&2; exit 2; }
done
for key in "$KUBELET_CLIENT_KEY" "$KUBELET_SERVING_KEY" "$KUBE_PROXY_KEY"; do
  [[ $(stat -c '%a' "$key") == 600 ]] || { echo "Private key mode must be 0600: $key" >&2; exit 2; }
done
verify_pair() {
  local cert=$1 key=$2 cert_pub key_pub
  openssl verify -CAfile "$CA" "$cert" >/dev/null
  cert_pub=$(openssl x509 -in "$cert" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')
  [[ $cert_pub == "$key_pub" ]] || { echo "Certificate/key mismatch: $cert" >&2; exit 2; }
}
verify_pair "$KUBELET_CLIENT_CERT" "$KUBELET_CLIENT_KEY"
verify_pair "$KUBELET_SERVING_CERT" "$KUBELET_SERVING_KEY"
verify_pair "$KUBE_PROXY_CERT" "$KUBE_PROXY_KEY"
client_subject=$(openssl x509 -in "$KUBELET_CLIENT_CERT" -noout -subject -nameopt RFC2253)
serving_subject=$(openssl x509 -in "$KUBELET_SERVING_CERT" -noout -subject -nameopt RFC2253)
proxy_subject=$(openssl x509 -in "$KUBE_PROXY_CERT" -noout -subject -nameopt RFC2253)
[[ $client_subject == *"CN=system:node:$NODE_NAME"* && $client_subject == *"O=system:nodes"* ]] || { echo 'Kubelet client certificate identity mismatch' >&2; exit 2; }
[[ $serving_subject == *"CN=$NODE_NAME"* && $serving_subject == *"O=system:nodes"* ]] || { echo 'Kubelet serving certificate identity mismatch' >&2; exit 2; }
[[ $proxy_subject == *"CN=system:kube-proxy"* && $proxy_subject == *"O=system:node-proxier"* ]] || { echo 'Kube-proxy certificate identity mismatch' >&2; exit 2; }
openssl x509 -in "$KUBELET_SERVING_CERT" -noout -ext subjectAltName | grep -Fq "IP Address:$NODE_IP" || { echo 'Kubelet serving certificate is missing node IP SAN' >&2; exit 2; }
WORK=$(mktemp -d /var/tmp/ks-kubelet-proxy.XXXXXX)
cleanup() { rm -rf -- "$WORK"; rm -f -- "$0"; }
trap cleanup EXIT
fetch_verified() {
  local name=$1 digest=$2 target=$WORK/$1
  curl --fail --silent --show-error --location --proto '=http' --proto-redir '=http' --max-time 600 --output "$target" "$HTTP_URL/$name"
  printf '%s  %s\n' "$digest" "$target" | sha256sum -c -
}
fetch_verified "$KUBELET_FILE" "$KUBELET_SHA"
fetch_verified "$KUBE_PROXY_FILE" "$KUBE_PROXY_SHA"
"$WORK/$KUBELET_FILE" --version | grep -Fq "Kubernetes $K8S_VERSION"
"$WORK/$KUBE_PROXY_FILE" --version | grep -Fq "Kubernetes $K8S_VERSION"
for target in "$BIN_DIR/kubelet" "$BIN_DIR/kube-proxy" /etc/systemd/system/kubelet.service /etc/systemd/system/kube-proxy.service; do
  [[ ! -L $target ]] || { echo "Symlinked target rejected: $target" >&2; exit 2; }
done
for pair in "kubelet:$BIN_DIR/kubelet" "kube-proxy:$BIN_DIR/kube-proxy"; do
  name=${pair%%:*}; target=${pair#*:}
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || exit 2
    cmp -s "$WORK/$name" "$target" || { echo "Existing binary differs; refusing replacement: $target" >&2; exit 73; }
  fi
done
kubelet_unit=$WORK/kubelet.service
cat > "$kubelet_unit" <<UNIT
[Unit]
Description=Kubernetes Kubelet
Documentation=https://kubernetes.io/docs/
After=network-online.target containerd.service k8s-api-proxy.service
Wants=network-online.target
Requires=containerd.service
StartLimitIntervalSec=0

[Service]
ExecStartPre=/usr/bin/test -S $CONTAINERD_STATE_DIR/containerd.sock
ExecStartPre=/usr/bin/test -s $CONFIG_DIR/kubelet-config.yaml
ExecStartPre=/usr/bin/test -s $CONFIG_DIR/kubelet.kubeconfig
ExecStart=$BIN_DIR/kubelet --config=$CONFIG_DIR/kubelet-config.yaml --kubeconfig=$CONFIG_DIR/kubelet.kubeconfig --hostname-override=$NODE_NAME --node-ip=$NODE_IP
Restart=always
RestartSec=5
KillMode=process
Delegate=yes
OOMScoreAdjust=-999
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
proxy_unit=$WORK/kube-proxy.service
cat > "$proxy_unit" <<UNIT
[Unit]
Description=Kubernetes kube-proxy
Documentation=https://kubernetes.io/docs/
After=network-online.target k8s-api-proxy.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStartPre=/usr/bin/test -s $CONFIG_DIR/kube-proxy-config.yaml
ExecStartPre=/usr/bin/test -s $CONFIG_DIR/kube-proxy.kubeconfig
ExecStart=$BIN_DIR/kube-proxy --config=$CONFIG_DIR/kube-proxy-config.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
for pair in "$kubelet_unit:/etc/systemd/system/kubelet.service" "$proxy_unit:/etc/systemd/system/kube-proxy.service"; do
  source_file=${pair%%:*}; target=${pair#*:}
  if [[ -e $target ]]; then
    [[ -f $target && ! -L $target ]] || exit 2
    cmp -s "$source_file" "$target" || { echo "Existing unit differs; refusing replacement: $target" >&2; exit 73; }
  fi
done
install -d -o root -g root -m 0755 "$BIN_DIR" "$CONFIG_DIR/manifests"
install -d -o root -g root -m 0750 "$CONFIG_DIR" "$KUBELET_DATA_DIR"
install -d -o root -g root -m 0700 "$CONFIG_DIR/pki" "$KUBELET_DATA_DIR/pki"
[[ -e $BIN_DIR/kubelet ]] || install -o root -g root -m 0755 "$WORK/kubelet" "$BIN_DIR/kubelet"
[[ -e $BIN_DIR/kube-proxy ]] || install -o root -g root -m 0755 "$WORK/kube-proxy" "$BIN_DIR/kube-proxy"
[[ -e /etc/systemd/system/kubelet.service ]] || install -o root -g root -m 0644 "$kubelet_unit" /etc/systemd/system/kubelet.service
[[ -e /etc/systemd/system/kube-proxy.service ]] || install -o root -g root -m 0644 "$proxy_unit" /etc/systemd/system/kube-proxy.service
if command -v restorecon >/dev/null 2>&1; then restorecon -RF "$BIN_DIR" "$CONFIG_DIR" "$KUBELET_DATA_DIR"; fi
systemctl daemon-reload
echo "Kubernetes $K8S_VERSION kubelet/kube-proxy binaries and disabled systemd units installed on $NODE_NAME; services were not started"
