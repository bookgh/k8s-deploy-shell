#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/manifest.sh"
source "$ROOT/scripts/lib/addons.sh"
BUNDLE=${1:?Usage: verify-offline-bundle.sh BUNDLE.tar.gz}
[[ -f $BUNDLE && ! -L $BUNDLE ]] || { ks_log ERROR 'Bundle is missing, not a regular file or symlinked'; exit 2; }
SIDECAR=$BUNDLE.sha256
[[ -f $SIDECAR && ! -L $SIDECAR ]] || { ks_log ERROR 'Bundle SHA256 sidecar missing or unsafe'; exit 2; }
for cmd in sha256sum tar awk grep find mktemp; do ks_require_cmd "$cmd"; done
EXPECTED=$(awk 'NR==1 {print $1}' "$SIDECAR")
[[ $EXPECTED =~ ^[a-fA-F0-9]{64}$ ]] || { ks_log ERROR 'Invalid bundle SHA256 sidecar'; exit 2; }
ACTUAL=$(ks_sha256_file "$BUNDLE")
[[ "${ACTUAL,,}" == "${EXPECTED,,}" ]] || { ks_log ERROR 'Bundle SHA256 mismatch'; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
tar -tzf "$BUNDLE" > "$WORK/entries.txt"
while IFS= read -r entry; do
  [[ $entry != /* && $entry != .. && $entry != *../* && $entry != */.. && ( $entry == ks-deploy-shell || $entry == ks-deploy-shell/* ) ]] || { ks_log ERROR "Unsafe archive path: $entry"; exit 2; }
done < "$WORK/entries.txt"
if grep -E '(^|/)(cluster\.env|known_hosts|pki|output)(/|$)|\.(key|pem|crt|kubeconfig|token|log)$' "$WORK/entries.txt"; then
  ks_log ERROR 'Bundle contains a secret or runtime path'
  exit 2
fi
tar -tvzf "$BUNDLE" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' || {
  ks_log ERROR 'Bundle contains a symlink, hardlink or special file'
  exit 2
}
for required in ARCHITECTURE.md IMPLEMENTATION-PROMPT.md IMPLEMENTATION-PLAN.md README.md versions.yaml charts.yaml cluster.env.example artifacts/manifest.tsv images.lock.tsv scripts/lib/common.sh scripts/lib/manifest.sh scripts/lib/addons.sh bin/install.sh scripts/16-verify-offline-bundle.sh; do
  grep -Fxq "ks-deploy-shell/$required" "$WORK/entries.txt" || { ks_log ERROR "Bundle missing required path: $required"; exit 2; }
done
tar -xzf "$BUNDLE" -C "$WORK"
BUNDLE_ROOT=$WORK/ks-deploy-shell
[[ -d $BUNDLE_ROOT && ! -L $BUNDLE_ROOT ]] || exit 2
if find "$BUNDLE_ROOT" -type l -print -quit | grep -q .; then ks_log ERROR 'Extracted bundle contains symlinks'; exit 2; fi
awk -F '\t' 'NR>1 && $1 !~ /^#/ && NF==6 {n++} END {exit (n>0 ? 0 : 1)}' "$BUNDLE_ROOT/images.lock.tsv" || {
  ks_log ERROR 'Bundle image lock has no valid image rows'
  exit 2
}
ks_manifest_validate "$BUNDLE_ROOT/artifacts/manifest.tsv"
ks_manifest_verify_cache "$BUNDLE_ROOT/artifacts/manifest.tsv" "$BUNDLE_ROOT/artifacts/cache"
ks_images_validate "$BUNDLE_ROOT/images.lock.tsv"
ks_images_verify_archives "$BUNDLE_ROOT/images.lock.tsv" "$BUNDLE_ROOT/artifacts/cache"
while IFS= read -r -d '' script; do bash -n "$script"; done < <(find "$BUNDLE_ROOT/bin" "$BUNDLE_ROOT/scripts" -type f -name '*.sh' -print0)
ks_log INFO "Offline bundle verified: $BUNDLE"
ks_log INFO "Bundle SHA256: $ACTUAL"
