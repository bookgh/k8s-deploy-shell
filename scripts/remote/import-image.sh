#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
(($# == 6)) || { echo 'Expected HTTP_URL ARCHIVE ARCHIVE_SHA IMAGE_REFERENCE IMAGE_DIGEST CTR_BIN' >&2; exit 2; }
HTTP_URL=$1
ARCHIVE=$2
ARCHIVE_SHA=$3
IMAGE_REFERENCE=$4
IMAGE_DIGEST=$5
CTR_BIN=$6
[[ $HTTP_URL =~ ^http://[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || exit 2
[[ $ARCHIVE =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.tar(\.gz|\.zst)?$ && $ARCHIVE != *'..'* ]] || exit 2
[[ $ARCHIVE_SHA =~ ^[a-fA-F0-9]{64}$ && $IMAGE_DIGEST =~ ^sha256:[a-fA-F0-9]{64}$ ]] || exit 2
[[ $IMAGE_REFERENCE =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || exit 2
[[ $CTR_BIN =~ ^/[A-Za-z0-9._/-]+$ && $CTR_BIN != *'/../'* ]] || exit 2
if [[ $EUID -ne 0 ]]; then exec sudo -n bash "$0" "$@"; fi
for cmd in curl sha256sum mktemp rm awk flock; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 127; }; done
[[ -x $CTR_BIN && ! -L $CTR_BIN ]] || { echo "containerd ctr missing: $CTR_BIN" >&2; exit 127; }
WORK=$(mktemp -d /var/tmp/ks-image-import.XXXXXX)
cleanup() { rm -rf -- "$WORK"; rm -f -- "$0"; }
trap cleanup EXIT
exec 9>/run/lock/ks-image-import.lock
flock -n 9 || { echo 'Image import already in progress' >&2; exit 75; }
curl --fail --silent --show-error --location --proto '=http' --proto-redir '=http' --max-time 1800 --output "$WORK/$ARCHIVE" "$HTTP_URL/$ARCHIVE"
printf '%s  %s\n' "$ARCHIVE_SHA" "$WORK/$ARCHIVE" | sha256sum -c -
"$CTR_BIN" -n k8s.io images import --all-platforms --digests "$WORK/$ARCHIVE"
"$CTR_BIN" -n k8s.io images ls | awk -v ref="$IMAGE_REFERENCE" -v digest="$IMAGE_DIGEST" '$1 == ref && $3 == digest { found=1 } END { exit !found }' || {
  echo "Imported image does not match locked reference/digest: $IMAGE_REFERENCE $IMAGE_DIGEST" >&2
  exit 1
}
echo "Imported and verified $IMAGE_REFERENCE ($IMAGE_DIGEST)"
