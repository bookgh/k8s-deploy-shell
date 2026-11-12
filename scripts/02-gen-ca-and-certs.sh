#!/usr/bin/env bash
set -Eeuo pipefail
IFS=ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/manifest.sh"

CONFIG="$ROOT/cluster.env"
APPLY=false
INSPECT=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --inspect) INSPECT=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"

ks_resolve_path() {
  local path=$1
  [[ $path == /* ]] || path=$ROOT/$path
  REPLY=$(realpath -m -- "$path")
}

ks_pki_inspect() {
  local root=$1 cert key mode
  if [[ ! -d $root ]]; then
    printf 'PKI directory does not exist: %s\n' "$root"
    return 0
  fi
  while IFS= read -r cert; do
    [[ -n $cert ]] || continue
    printf '\n[certificate] %s\n' "$cert"
    openssl x509 -in "$cert" -noout -subject -issuer -startdate -enddate
  done < <(find "$root" -type f \( -name '*.pem' -o -name '*.crt' \) ! -name '*-key.pem' -print | sort)
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    mode=$(stat -c '%a' "$key")
    printf '[private-key] %s mode=%s\n' "$key" "$mode"
    [[ $mode == 600 || $mode == 400 ]] || ks_log WARN "Private key permissions need review: $key"
  done < <(find "$root" -type f \( -name '*-key.pem' -o -name '*.key' \) -print | sort)
}

ks_generate_ca() {
  local cfssl=$1 cfssljson=$2 directory=$3 common_name=$4
  install -d -m 0700 "$directory"
  cat > "$directory/ca-csr.json" <<CSR
{
  "CN": "$common_name",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [
    { "C": "US", "L": "Kubernetes", "O": "Kubernetes", "OU": "Certificate Authority", "ST": "Cluster" }
  ],
  "ca": { "expiry": "876000h", "pathlen": 1 }
}
CSR
  cat > "$directory/ca-config.json" <<'CONFIG'
{
  "signing": {
    "default": { "expiry": "876000h" },
    "profiles": {
      "server": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "server auth"]
      },
      "client": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "client auth"]
      },
      "peer": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "server auth", "client auth"]
      }
    }
  }
}
CONFIG
  "$cfssl" gencert -initca "$directory/ca-csr.json" | "$cfssljson" -bare "$directory/ca"
  chmod 0600 "$directory/ca-key.pem"
  chmod 0644 "$directory/ca.pem" "$directory/ca.csr" "$directory/ca-csr.json" "$directory/ca-config.json"
  ks_verify_ca "$directory/ca.pem" "$directory/ca-key.pem"
}

ks_verify_ca() {
  local cert=$1 key=$2 cert_pub key_pub end_date end_epoch now_epoch remaining
  openssl x509 -in "$cert" -noout -text > "$cert.text"
  grep -q 'CA:TRUE' "$cert.text"
  rm -f -- "$cert.text"
  openssl verify -CAfile "$cert" "$cert"
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')
  [[ $cert_pub == "$key_pub" ]] || { ks_log ERROR "CA key does not match certificate: $cert"; return 1; }
  [[ $(stat -c '%a' "$key") == 600 ]] || { ks_log ERROR "CA private key must be mode 0600: $key"; return 1; }
  end_date=$(openssl x509 -in "$cert" -enddate -noout | cut -d= -f2-)
  end_epoch=$(date -u -d "$end_date" +%s)
  now_epoch=$(date -u +%s)
  remaining=$((end_epoch - now_epoch))
  ((remaining >= 876000 * 3600 - 86400)) || { ks_log ERROR "Certificate validity is shorter than the required 876000h: $cert"; return 1; }
}

PKI_ROOT_PATH=
ks_resolve_path "$PKI_ROOT"
PKI_ROOT_PATH=$REPLY
CACHE_ROOT=
ks_resolve_path "$ARTIFACT_HTTP_ROOT"
CACHE_ROOT=$REPLY
[[ $PKI_ROOT_PATH != "$CACHE_ROOT" && $PKI_ROOT_PATH != "$CACHE_ROOT/"* ]] || { ks_log ERROR 'PKI must never be placed inside the public artifact root'; exit 2; }

if [[ $INSPECT == true ]]; then
  ks_pki_inspect "$PKI_ROOT_PATH"
  exit 0
fi

MANIFEST=$ROOT/artifacts/manifest.tsv
IFS=$'\t' read -r CFSSL_FILE CFSSL_SHA CFSSL_VERSION CFSSL_ARCH CFSSL_URL < <(ks_manifest_lookup "$MANIFEST" cfssl)
IFS=$'\t' read -r CFSSLJSON_FILE CFSSLJSON_SHA CFSSLJSON_VERSION CFSSLJSON_ARCH CFSSLJSON_URL < <(ks_manifest_lookup "$MANIFEST" cfssljson)
[[ $CFSSL_VERSION == "$CFSSLJSON_VERSION" && $CFSSL_ARCH == amd64 && $CFSSLJSON_ARCH == amd64 ]] || { ks_log ERROR 'CFSSL tools must have matching pinned amd64 versions'; exit 2; }

if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO 'PKI preview only; no directories, keys or certificates created'
  printf 'PKI root: %s\nCFSSL: %s (%s) %s\nCFSSLJSON: %s %s\nTrust domains: kubernetes, etcd, front-proxy\nServiceAccount key: independent RSA-2048\nCertificate validity: 876000h (100 years)\n' "$PKI_ROOT_PATH" "$CFSSL_VERSION" "$CFSSL_FILE" "$CFSSL_URL" "$CFSSLJSON_FILE" "$CFSSLJSON_URL"
  printf 'Existing non-empty PKI will be rejected; CA private keys remain local and must be backed up offline.\n'
  exit 0
fi

ks_pki_generate() {
  local parent stage backup='' cfssl_src cfssljson_src
  [[ -f $CACHE_ROOT/$CFSSL_FILE && -f $CACHE_ROOT/$CFSSLJSON_FILE ]] || { ks_log ERROR 'CFSSL tools are not present in the verified artifact cache'; return 2; }
  ks_verify_sha256 "$CACHE_ROOT/$CFSSL_FILE" "$CFSSL_SHA"
  ks_verify_sha256 "$CACHE_ROOT/$CFSSLJSON_FILE" "$CFSSLJSON_SHA"
  if [[ -e $PKI_ROOT_PATH ]]; then
    [[ -d $PKI_ROOT_PATH && ! -L $PKI_ROOT_PATH ]] || { ks_log ERROR 'Existing PKI path is not a regular directory'; return 2; }
    local existing
    existing=$(find "$PKI_ROOT_PATH" -mindepth 1 ! -name .gitkeep -print -quit)
    [[ -z $existing ]] || { ks_log ERROR "Refusing to overwrite existing PKI content: $existing"; return 73; }
  fi
  parent=$(dirname -- "$PKI_ROOT_PATH")
  mkdir -p -- "$parent"
  stage=$(mktemp -d "$parent/.pki-stage.XXXXXX")
  PKI_STAGE=$stage
  chmod 0700 "$stage"
  mkdir -m 0700 "$stage/.tools"
  cfssl_src=$stage/.tools/cfssl
  cfssljson_src=$stage/.tools/cfssljson
  install -m 0700 "$CACHE_ROOT/$CFSSL_FILE" "$cfssl_src"
  install -m 0700 "$CACHE_ROOT/$CFSSLJSON_FILE" "$cfssljson_src"
  "$cfssl_src" version | grep -F "$CFSSL_VERSION" >/dev/null
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/kubernetes" 'Kubernetes Root CA'
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/etcd" 'Kubernetes ETCD CA'
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/front-proxy" 'Kubernetes Front Proxy CA'
  install -d -m 0700 "$stage/service-account" "$stage/metadata"
  openssl genrsa -out "$stage/service-account/sa.key" 2048
  openssl rsa -in "$stage/service-account/sa.key" -pubout -out "$stage/service-account/sa.pub"
  chmod 0600 "$stage/service-account/sa.key"
  chmod 0644 "$stage/service-account/sa.pub"
  rm -rf -- "$stage/.tools"
  cat > "$stage/metadata/PKI-MANIFEST.txt" <<META
CFSSL_VERSION=$CFSSL_VERSION
CERTIFICATE_DURATION=876000h
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
CA_DOMAINS=kubernetes,etcd,front-proxy
SERVICE_ACCOUNT_ALGORITHM=RSA-2048
META
  chmod 0600 "$stage/metadata/PKI-MANIFEST.txt"
  if [[ -e $PKI_ROOT_PATH ]]; then
    backup=$PKI_ROOT_PATH.empty.$(date -u '+%Y%m%dT%H%M%SZ')
    mv -- "$PKI_ROOT_PATH" "$backup"
  fi
  if ! mv -- "$stage" "$PKI_ROOT_PATH"; then
    [[ -z $backup ]] || mv -- "$backup" "$PKI_ROOT_PATH"
    ks_log ERROR 'Failed to publish generated PKI atomically'
    return 1
  fi
  PKI_STAGE=
  if [[ -n $backup ]]; then
    rm -f -- "$backup/.gitkeep"
    rmdir -- "$backup"
  fi
  ks_log INFO "Three independent CA roots and ServiceAccount keys generated under $PKI_ROOT_PATH"
}
PKI_STAGE=
ks_cleanup_pki_stage() {
  [[ -z $PKI_STAGE ]] || rm -rf -- "$PKI_STAGE"
}
trap ks_cleanup_pki_stage EXIT
ks_with_lock "$ROOT/state/pki.lock" ks_pki_generate
\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/nodes.sh"
source "$ROOT/scripts/lib/manifest.sh"

CONFIG="$ROOT/cluster.env"
APPLY=false
INSPECT=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || exit 2; CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --inspect) INSPECT=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ks_config_load "$CONFIG"
ks_config_validate
ks_nodes_validate "$NODE_INVENTORY_FILE" "$MASTERS" "$WORKERS"

ks_resolve_path() {
  local path=$1
  [[ $path == /* ]] || path=$ROOT/$path
  REPLY=$(realpath -m -- "$path")
}

ks_pki_inspect() {
  local root=$1 cert key mode
  if [[ ! -d $root ]]; then
    printf 'PKI directory does not exist: %s\n' "$root"
    return 0
  fi
  while IFS= read -r cert; do
    [[ -n $cert ]] || continue
    printf '\n[certificate] %s\n' "$cert"
    openssl x509 -in "$cert" -noout -subject -issuer -startdate -enddate
  done < <(find "$root" -type f \( -name '*.pem' -o -name '*.crt' \) ! -name '*-key.pem' -print | sort)
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    mode=$(stat -c '%a' "$key")
    printf '[private-key] %s mode=%s\n' "$key" "$mode"
    [[ $mode == 600 || $mode == 400 ]] || ks_log WARN "Private key permissions need review: $key"
  done < <(find "$root" -type f \( -name '*-key.pem' -o -name '*.key' \) -print | sort)
}

ks_generate_ca() {
  local cfssl=$1 cfssljson=$2 directory=$3 common_name=$4
  install -d -m 0700 "$directory"
  cat > "$directory/ca-csr.json" <<CSR
{
  "CN": "$common_name",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [
    { "C": "US", "L": "Kubernetes", "O": "Kubernetes", "OU": "Certificate Authority", "ST": "Cluster" }
  ],
  "ca": { "expiry": "876000h", "pathlen": 1 }
}
CSR
  cat > "$directory/ca-config.json" <<'CONFIG'
{
  "signing": {
    "default": { "expiry": "876000h" },
    "profiles": {
      "server": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "server auth"]
      },
      "client": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "client auth"]
      },
      "peer": {
        "expiry": "876000h",
        "usages": ["signing", "key encipherment", "server auth", "client auth"]
      }
    }
  }
}
CONFIG
  "$cfssl" gencert -initca "$directory/ca-csr.json" | "$cfssljson" -bare "$directory/ca"
  chmod 0600 "$directory/ca-key.pem"
  chmod 0644 "$directory/ca.pem" "$directory/ca.csr" "$directory/ca-csr.json" "$directory/ca-config.json"
  ks_verify_ca "$directory/ca.pem" "$directory/ca-key.pem"
}

ks_verify_ca() {
  local cert=$1 key=$2 cert_pub key_pub end_date end_epoch now_epoch remaining
  openssl x509 -in "$cert" -noout -text > "$cert.text"
  grep -q 'CA:TRUE' "$cert.text"
  rm -f -- "$cert.text"
  openssl verify -CAfile "$cert" "$cert"
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER | sha256sum | awk '{print $1}')
  [[ $cert_pub == "$key_pub" ]] || { ks_log ERROR "CA key does not match certificate: $cert"; return 1; }
  [[ $(stat -c '%a' "$key") == 600 ]] || { ks_log ERROR "CA private key must be mode 0600: $key"; return 1; }
  end_date=$(openssl x509 -in "$cert" -enddate -noout | cut -d= -f2-)
  end_epoch=$(date -u -d "$end_date" +%s)
  now_epoch=$(date -u +%s)
  remaining=$((end_epoch - now_epoch))
  ((remaining >= 876000 * 3600 - 86400)) || { ks_log ERROR "Certificate validity is shorter than the required 876000h: $cert"; return 1; }
}

PKI_ROOT_PATH=
ks_resolve_path "$PKI_ROOT"
PKI_ROOT_PATH=$REPLY
CACHE_ROOT=
ks_resolve_path "$ARTIFACT_HTTP_ROOT"
CACHE_ROOT=$REPLY
[[ $PKI_ROOT_PATH != "$CACHE_ROOT" && $PKI_ROOT_PATH != "$CACHE_ROOT/"* ]] || { ks_log ERROR 'PKI must never be placed inside the public artifact root'; exit 2; }

if [[ $INSPECT == true ]]; then
  ks_pki_inspect "$PKI_ROOT_PATH"
  exit 0
fi

MANIFEST=$ROOT/artifacts/manifest.tsv
IFS=$'\t' read -r CFSSL_FILE CFSSL_SHA CFSSL_VERSION CFSSL_ARCH CFSSL_URL < <(ks_manifest_lookup "$MANIFEST" cfssl)
IFS=$'\t' read -r CFSSLJSON_FILE CFSSLJSON_SHA CFSSLJSON_VERSION CFSSLJSON_ARCH CFSSLJSON_URL < <(ks_manifest_lookup "$MANIFEST" cfssljson)
[[ $CFSSL_VERSION == "$CFSSLJSON_VERSION" && $CFSSL_ARCH == amd64 && $CFSSLJSON_ARCH == amd64 ]] || { ks_log ERROR 'CFSSL tools must have matching pinned amd64 versions'; exit 2; }

if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO 'PKI preview only; no directories, keys or certificates created'
  printf 'PKI root: %s\nCFSSL: %s (%s)\nCFSSLJSON: %s\nTrust domains: kubernetes, etcd, front-proxy\nServiceAccount key: independent RSA-2048\nCertificate validity: 876000h (100 years)\n' "$PKI_ROOT_PATH" "$CFSSL_VERSION" "$CFSSL_FILE" "$CFSSLJSON_FILE"
  printf 'Existing non-empty PKI will be rejected; CA private keys remain local and must be backed up offline.\n'
  exit 0
fi

ks_with_lock "$ROOT/state/pki.lock" ks_pki_generate

ks_pki_generate() {
  local parent stage backup='' cfssl_src cfssljson_src
  [[ -f $CACHE_ROOT/$CFSSL_FILE && -f $CACHE_ROOT/$CFSSLJSON_FILE ]] || { ks_log ERROR 'CFSSL tools are not present in the verified artifact cache'; return 2; }
  ks_verify_sha256 "$CACHE_ROOT/$CFSSL_FILE" "$CFSSL_SHA"
  ks_verify_sha256 "$CACHE_ROOT/$CFSSLJSON_FILE" "$CFSSLJSON_SHA"
  if [[ -e $PKI_ROOT_PATH ]]; then
    [[ -d $PKI_ROOT_PATH && ! -L $PKI_ROOT_PATH ]] || { ks_log ERROR 'Existing PKI path is not a regular directory'; return 2; }
    local existing
    existing=$(find "$PKI_ROOT_PATH" -mindepth 1 ! -name .gitkeep -print -quit)
    [[ -z $existing ]] || { ks_log ERROR "Refusing to overwrite existing PKI content: $existing"; return 73; }
  fi
  parent=$(dirname -- "$PKI_ROOT_PATH")
  mkdir -p -- "$parent"
  stage=$(mktemp -d "$parent/.pki-stage.XXXXXX")
  PKI_STAGE=$stage
  chmod 0700 "$stage"
  mkdir -m 0700 "$stage/.tools"
  cfssl_src=$stage/.tools/cfssl
  cfssljson_src=$stage/.tools/cfssljson
  install -m 0700 "$CACHE_ROOT/$CFSSL_FILE" "$cfssl_src"
  install -m 0700 "$CACHE_ROOT/$CFSSLJSON_FILE" "$cfssljson_src"
  "$cfssl_src" version | grep -F "$CFSSL_VERSION" >/dev/null
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/kubernetes" 'Kubernetes Root CA'
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/etcd" 'Kubernetes ETCD CA'
  ks_generate_ca "$cfssl_src" "$cfssljson_src" "$stage/front-proxy" 'Kubernetes Front Proxy CA'
  install -d -m 0700 "$stage/service-account" "$stage/metadata"
  openssl genrsa -out "$stage/service-account/sa.key" 2048
  openssl rsa -in "$stage/service-account/sa.key" -pubout -out "$stage/service-account/sa.pub"
  chmod 0600 "$stage/service-account/sa.key"
  chmod 0644 "$stage/service-account/sa.pub"
  rm -rf -- "$stage/.tools"
  cat > "$stage/metadata/PKI-MANIFEST.txt" <<META
CFSSL_VERSION=$CFSSL_VERSION
CERTIFICATE_DURATION=876000h
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
CA_DOMAINS=kubernetes,etcd,front-proxy
SERVICE_ACCOUNT_ALGORITHM=RSA-2048
META
  chmod 0600 "$stage/metadata/PKI-MANIFEST.txt"
  if [[ -e $PKI_ROOT_PATH ]]; then
    backup=$PKI_ROOT_PATH.empty.$(date -u '+%Y%m%dT%H%M%SZ')
    mv -- "$PKI_ROOT_PATH" "$backup"
  fi
  if ! mv -- "$stage" "$PKI_ROOT_PATH"; then
    [[ -z $backup ]] || mv -- "$backup" "$PKI_ROOT_PATH"
    ks_log ERROR 'Failed to publish generated PKI atomically'
    return 1
  fi
  PKI_STAGE=
  if [[ -n $backup ]]; then
    rm -f -- "$backup/.gitkeep"
    rmdir -- "$backup"
  fi
  ks_log INFO "Three independent CA roots and ServiceAccount keys generated under $PKI_ROOT_PATH"
}
PKI_STAGE=
ks_cleanup_pki_stage() {
  [[ -z $PKI_STAGE ]] || rm -rf -- "$PKI_STAGE"
}
trap ks_cleanup_pki_stage EXIT
ks_with_lock "$ROOT/state/pki.lock" ks_pki_generate
