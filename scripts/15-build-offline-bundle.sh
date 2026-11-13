#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/config.sh"
source "$ROOT/scripts/lib/manifest.sh"
source "$ROOT/scripts/lib/addons.sh"
CONFIG="$ROOT/cluster.env"
APPLY=false
while (($#)); do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --apply) APPLY=true; shift ;;
    --dry-run) KS_DRY_RUN=true; KS_DRY_RUN_OVERRIDE=true; shift ;;
    build) shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
ks_config_load "$CONFIG"
ks_config_validate
[[ $ARTIFACT_HTTP_ROOT == /* ]] || ARTIFACT_HTTP_ROOT=$ROOT/$ARTIFACT_HTTP_ROOT
CACHE_ROOT=$(realpath -m -- "$ARTIFACT_HTTP_ROOT")
[[ $OUTPUT_ROOT == /* ]] || OUTPUT_ROOT=$ROOT/$OUTPUT_ROOT
OUTPUT_PATH=$(realpath -m -- "$OUTPUT_ROOT")
if [[ ! -f $ROOT/images.lock.tsv || -L $ROOT/images.lock.tsv ]]; then
  if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
    ks_log WARN 'DRY-RUN: images.lock.tsv is not present; bundle creation remains blocked until image closure is pinned'
    exit 78
  fi
  ks_log ERROR 'Offline bundle requires a reviewed images.lock.tsv'
  exit 78
fi
ks_images_validate "$ROOT/images.lock.tsv"
if [[ $APPLY != true || ${KS_DRY_RUN:-true} == true ]]; then
  ks_log INFO 'DRY-RUN: would verify artifact/image cache and create a sanitized offline bundle'
  ks_log INFO 'Secrets excluded: cluster.env, known_hosts, pki/, kubeconfigs and runtime state'
  exit 0
fi
[[ ${KS_DRY_RUN:-true} == false ]] || { ks_log ERROR 'Set DRY_RUN=false before --apply'; exit 2; }
for cmd in tar gzip sha256sum cp install find realpath; do ks_require_cmd "$cmd"; done
ks_manifest_verify_cache "$ROOT/artifacts/manifest.tsv" "$CACHE_ROOT"
ks_images_verify_archives "$ROOT/images.lock.tsv" "$CACHE_ROOT"
if find "$CACHE_ROOT" -type l -print -quit | grep -q .; then ks_log ERROR 'Artifact cache contains symlinks'; exit 2; fi
if find "$CACHE_ROOT" -type f \( -name '*.key' -o -name '*.pem' -o -name '*.crt' -o -name '*.kubeconfig' -o -name '*.token' -o -name '*.log' \) -print -quit | grep -q .; then
  ks_log ERROR 'Sensitive material found in artifact cache; refusing bundle'
  exit 2
fi
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
RELEASE_DIR=$OUTPUT_PATH/releases
install -d -m 0700 "$RELEASE_DIR"
WORK=$(mktemp -d "$OUTPUT_PATH/.bundle.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
STAGE=$WORK/ks-deploy-shell
install -d -m 0700 "$STAGE/artifacts/cache" "$STAGE/config" "$STAGE/docs" "$STAGE/scripts" "$STAGE/bin" "$STAGE/charts" "$STAGE/tests" "$STAGE/state"
cp -a "$ROOT/ARCHITECTURE.md" "$ROOT/IMPLEMENTATION-PROMPT.md" "$ROOT/IMPLEMENTATION-PLAN.md" "$ROOT/README.md" "$ROOT/versions.yaml" "$ROOT/charts.yaml" "$ROOT/cluster.env.example" "$ROOT/artifacts/manifest.tsv" "$STAGE/"
cp -a "$ROOT/docs/OPERATIONS.md" "$ROOT/docs/SECURITY.md" "$ROOT/docs/IMPLEMENTATION-STATUS.md" "$STAGE/docs/"
cp -a "$ROOT/config/nodes.tsv.example" "$ROOT/config/Caddyfile.example" "$STAGE/config/"
cp -a "$ROOT/bin/." "$STAGE/bin/"
cp -a "$ROOT/scripts/." "$STAGE/scripts/"
cp -a "$ROOT/charts/." "$STAGE/charts/"
cp -a "$ROOT/tests/." "$STAGE/tests/"
cp -a "$ROOT/images.lock.tsv" "$STAGE/"
cp -a "$CACHE_ROOT/." "$STAGE/artifacts/cache/"
[[ ! -f $ROOT/state/generated-artifacts.tsv ]] || cp -a "$ROOT/state/generated-artifacts.tsv" "$STAGE/state/"
cat > "$STAGE/BUNDLE-METADATA.txt" <<META
project=ks-deploy-shell
cluster_target=Rocky Linux 9 x86_64
kubernetes_target=$(ks_yaml_scalar "$ROOT/versions.yaml" kubernetes version)
created_utc=$STAMP
source_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
META
BUNDLE=$RELEASE_DIR/ks-deploy-shell-$STAMP.tar.gz
TMP_BUNDLE=$WORK/bundle.tar.gz
tar -cf - --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$WORK" ks-deploy-shell | gzip -n > "$TMP_BUNDLE"
mv -- "$TMP_BUNDLE" "$BUNDLE"
chmod 0600 "$BUNDLE"
sha256sum "$BUNDLE" > "$BUNDLE.sha256"
chmod 0600 "$BUNDLE.sha256"
ks_log INFO "Offline bundle created: $BUNDLE"
ks_log INFO "Bundle SHA256: $(ks_sha256_file "$BUNDLE")"
