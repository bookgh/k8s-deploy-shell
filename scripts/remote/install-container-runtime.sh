#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 17)) || { echo 'Expected 17 runtime arguments' >&2; exit 2; }
CONTAINERD_VERSION=$1; CONTAINERD_FILE=$2; CONTAINERD_SHA=$3
RUNC_VERSION=$4; RUNC_FILE=$5; RUNC_SHA=$6
CNI_VERSION=$7; CNI_FILE=$8; CNI_SHA=$9
HTTP_URL=${10}; CONFIG_DIR=${11}; ROOT_DIR=${12}; STATE_DIR=${13}; BIN_DIR=${14}; CNI_BIN_DIR=${15}; CNI_CONF_DIR=${16}; SANDBOX_IMAGE=${17}
if [[ $EUID -ne 0 ]]; then command -v sudo >/dev/null 2>&1 || { echo "sudo is required for non-root SSH users" >&2; exit 127; }; exec sudo -n bash "$0" "$@"; fi
for cmd in curl sha256sum tar install systemctl cmp mv mktemp find flock sed tr grep awk; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing remote command: $cmd" >&2; exit 127; }; done
[[ -r /etc/os-release ]] || exit 2
remote_os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
remote_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $remote_os == rocky && ${remote_version%%.*} == 9 && $(uname -m) == x86_64 ]] || { echo 'Target must be Rocky Linux 9 / x86_64' >&2; exit 2; }
[[ $CONTAINERD_VERSION =~ ^2\.[0-9]+\.[0-9]+$ && $CONTAINERD_FILE == "containerd-static-$CONTAINERD_VERSION-linux-amd64.tar.gz" ]] || exit 2
[[ $RUNC_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $RUNC_FILE == "runc-$RUNC_VERSION-amd64" ]] || exit 2
[[ $CNI_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $CNI_FILE == "cni-plugins-linux-amd64-v$CNI_VERSION.tgz" ]] || exit 2
for digest in "$CONTAINERD_SHA" "$RUNC_SHA" "$CNI_SHA"; do [[ $digest =~ ^[a-fA-F0-9]{64}$ ]] || exit 2; done
[[ $HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
[[ $SANDBOX_IMAGE =~ ^[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || exit 2
for path in "$CONFIG_DIR" "$ROOT_DIR" "$STATE_DIR" "$BIN_DIR" "$CNI_BIN_DIR" "$CNI_CONF_DIR"; do
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *'/../'* && $path != */.. && $path != / ]] || exit 2
done
[[ $ROOT_DIR != "$STATE_DIR" && $ROOT_DIR != "$STATE_DIR/"* && $STATE_DIR != "$ROOT_DIR/"* ]] || { echo 'containerd root and state paths must be separate' >&2; exit 2; }
install -d -o root -g root -m 0755 /run/lock
exec 8>/run/lock/ks-deploy-shell-node.lock
flock -n 8 || { echo 'Another deployment mutation is already running on this node' >&2; exit 75; }
exec 9>/run/lock/ks-container-runtime.lock
flock -n 9 || { echo 'Container runtime operation already in progress' >&2; exit 75; }
WORK=$(mktemp -d /var/tmp/ks-container-runtime.XXXXXX)
cleanup() { rm -rf -- "$WORK"; rm -f -- "$0"; }
trap cleanup EXIT
fetch_verified() {
  local name=$1 digest=$2 target=$WORK/$1
  curl --fail --silent --show-error --location --proto '=http' --max-time 600 --output "$target" "$HTTP_URL/$name"
  printf '%s  %s\n' "$digest" "$target" | sha256sum -c -
}
fetch_verified "$CONTAINERD_FILE" "$CONTAINERD_SHA"
fetch_verified "$RUNC_FILE" "$RUNC_SHA"
fetch_verified "$CNI_FILE" "$CNI_SHA"
tar -tvzf "$WORK/$CONTAINERD_FILE" | awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' || { echo 'Containerd archive contains a link or special file' >&2; exit 2; }
mapfile -t containerd_entries < <(tar -tzf "$WORK/$CONTAINERD_FILE")
(("${#containerd_entries[@]}" > 0)) || exit 2
for entry in "${containerd_entries[@]}"; do
  entry=${entry#./}
  [[ -z $entry ]] && continue
  [[ $entry == bin || $entry == bin/ || $entry =~ ^bin/[A-Za-z0-9._+-]+$ ]] || { echo "Unsafe containerd archive member: $entry" >&2; exit 2; }
done
tar -tvzf "$WORK/$CNI_FILE" | awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' || { echo 'CNI archive contains a link or special file' >&2; exit 2; }
mapfile -t cni_entries < <(tar -tzf "$WORK/$CNI_FILE")
(("${#cni_entries[@]}" > 0)) || exit 2
for entry in "${cni_entries[@]}"; do
  entry=${entry#./}
  [[ -z $entry ]] && continue
  [[ $entry =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo "Unsafe CNI archive member: $entry" >&2; exit 2; }
done
mkdir -m 0700 "$WORK/containerd" "$WORK/cni"
tar --no-same-owner --no-same-permissions -xzf "$WORK/$CONTAINERD_FILE" -C "$WORK/containerd"
tar --no-same-owner --no-same-permissions -xzf "$WORK/$CNI_FILE" -C "$WORK/cni"
for binary in containerd containerd-shim-runc-v2 ctr; do
  [[ -f $WORK/containerd/bin/$binary && ! -L $WORK/containerd/bin/$binary ]] || { echo "Missing containerd binary: $binary" >&2; exit 2; }
done
[[ -f $WORK/cni/bridge && -f $WORK/cni/host-local && -f $WORK/cni/loopback && -f $WORK/cni/portmap ]] || { echo 'Required CNI plugin binaries missing' >&2; exit 2; }
"$WORK/containerd/bin/containerd" --version | grep -Fq "v$CONTAINERD_VERSION"
"$WORK/containerd/bin/ctr" version | grep -Fq "$CONTAINERD_VERSION"
"$WORK/$RUNC_FILE" --version | grep -Fq "version $RUNC_VERSION"
containerd_targets=()
containerd_sources=()
while IFS= read -r -d '' source; do
  containerd_sources+=("$source")
  containerd_targets+=("$BIN_DIR/${source##*/}")
done < <(find "$WORK/containerd/bin" -maxdepth 1 -type f -print0)
(("${#containerd_targets[@]}" > 0)) || exit 2
cni_targets=()
cni_sources=()
while IFS= read -r -d '' source; do
  cni_sources+=("$source")
  cni_targets+=("$CNI_BIN_DIR/${source##*/}")
done < <(find "$WORK/cni" -maxdepth 1 -type f -print0)
(("${#cni_targets[@]}" > 0)) || exit 2
for target in "${containerd_targets[@]}" "${cni_targets[@]}" "$BIN_DIR/runc" "$CONFIG_DIR/config.toml" /etc/systemd/system/containerd.service; do
  [[ ! -L $target ]] || { echo "Symlinked runtime target rejected: $target" >&2; exit 2; }
done
config_tmp=$WORK/config.toml
cat > "$config_tmp" <<TOML
version = 3
root = "$ROOT_DIR"
state = "$STATE_DIR"

[grpc]
  address = "$STATE_DIR/containerd.sock"

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = "$SANDBOX_IMAGE"

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ["$CNI_BIN_DIR"]
  conf_dir = "$CNI_CONF_DIR"
  max_conf_num = 1

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
TOML
unit_tmp=$WORK/containerd.service
cat > "$unit_tmp" <<UNIT
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=$BIN_DIR/containerd --config $CONFIG_DIR/config.toml
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
PrivateTmp=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
if [[ -e $CONFIG_DIR/config.toml ]]; then
  [[ -f $CONFIG_DIR/config.toml && ! -L $CONFIG_DIR/config.toml ]] || exit 2
  cmp -s "$config_tmp" "$CONFIG_DIR/config.toml" || { echo 'Existing containerd config differs; refusing replacement' >&2; exit 73; }
fi
if [[ -e /etc/systemd/system/containerd.service ]]; then
  [[ -f /etc/systemd/system/containerd.service && ! -L /etc/systemd/system/containerd.service ]] || exit 2
  cmp -s "$unit_tmp" /etc/systemd/system/containerd.service || { echo 'Existing containerd unit differs; refusing replacement' >&2; exit 73; }
fi
for i in "${!containerd_targets[@]}"; do
  if [[ -e ${containerd_targets[$i]} ]]; then
    [[ -f ${containerd_targets[$i]} && ! -L ${containerd_targets[$i]} ]] || exit 2
    cmp -s "${containerd_sources[$i]}" "${containerd_targets[$i]}" || { echo "Existing runtime binary differs: ${containerd_targets[$i]}" >&2; exit 73; }
  fi
done
if [[ -e $BIN_DIR/runc ]]; then
  [[ -f $BIN_DIR/runc && ! -L $BIN_DIR/runc ]] || exit 2
  cmp -s "$WORK/$RUNC_FILE" "$BIN_DIR/runc" || { echo 'Existing runc binary differs; refusing replacement' >&2; exit 73; }
fi
for i in "${!cni_targets[@]}"; do
  if [[ -e ${cni_targets[$i]} ]]; then
    [[ -f ${cni_targets[$i]} && ! -L ${cni_targets[$i]} ]] || exit 2
    cmp -s "${cni_sources[$i]}" "${cni_targets[$i]}" || { echo "Existing CNI plugin differs: ${cni_targets[$i]}" >&2; exit 73; }
  fi
done
if systemctl is-active --quiet containerd; then
  [[ -f /etc/systemd/system/containerd.service ]] || { echo 'An unmanaged containerd service is active; refusing to take it over' >&2; exit 73; }
  cmp -s "$unit_tmp" /etc/systemd/system/containerd.service || { echo 'Active containerd service unit differs; refusing to take it over' >&2; exit 73; }
fi
for path in "$CONFIG_DIR" "$ROOT_DIR" "$STATE_DIR" "$BIN_DIR" "$CNI_BIN_DIR" "$CNI_CONF_DIR"; do
  [[ ! -L $path ]] || { echo "Symlinked runtime directory rejected: $path" >&2; exit 2; }
done
install -d -o root -g root -m 0755 "$CONFIG_DIR" "$ROOT_DIR" "$BIN_DIR" "$CNI_BIN_DIR" "$CNI_CONF_DIR"
install -d -o root -g root -m 0755 "$STATE_DIR"
for i in "${!containerd_targets[@]}"; do
  [[ -e ${containerd_targets[$i]} ]] || install -o root -g root -m 0755 "${containerd_sources[$i]}" "${containerd_targets[$i]}"
done
[[ -e $BIN_DIR/runc ]] || install -o root -g root -m 0755 "$WORK/$RUNC_FILE" "$BIN_DIR/runc"
for i in "${!cni_targets[@]}"; do
  [[ -e ${cni_targets[$i]} ]] || install -o root -g root -m 0755 "${cni_sources[$i]}" "${cni_targets[$i]}"
done
[[ -e $CONFIG_DIR/config.toml ]] || install -o root -g root -m 0644 "$config_tmp" "$CONFIG_DIR/config.toml"
[[ -e /etc/systemd/system/containerd.service ]] || install -o root -g root -m 0644 "$unit_tmp" /etc/systemd/system/containerd.service
"$BIN_DIR/containerd" --config "$CONFIG_DIR/config.toml" config dump >/dev/null
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$CONFIG_DIR" "$ROOT_DIR" "$BIN_DIR" "$CNI_BIN_DIR" "$CNI_CONF_DIR" "$STATE_DIR"
fi
systemctl daemon-reload
systemctl enable --now containerd.service
systemctl is-active --quiet containerd.service
$BIN_DIR/ctr --address "$STATE_DIR/containerd.sock" plugins ls | grep -F 'io.containerd.cri.v1.runtime' | grep -Fq ok
$BIN_DIR/ctr --address "$STATE_DIR/containerd.sock" version >/dev/null
echo "containerd $CONTAINERD_VERSION, runc $RUNC_VERSION and CNI plugins $CNI_VERSION installed; CRI is active"
