#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_manifest_validate() {
  local manifest=${1:?manifest required} name version arch url sha file line=0
  [[ -r $manifest ]] || { ks_log ERROR "Manifest unreadable: $manifest"; return 2; }
  while IFS=$'\t' read -r name version arch url sha file || [[ -n ${name:-} ]]; do
    ((line+=1))
    [[ -z ${name:-} || $name == name || $name == \#* ]] && continue
    [[ $name =~ ^[A-Za-z0-9._+-]+$ && $version =~ ^[A-Za-z0-9._+-]+$ ]] || return 2
    [[ $arch == amd64 || $arch == x86_64 || $arch == noarch ]] || return 2
    [[ $url == https://* ]] || { ks_log ERROR "Only HTTPS source accepted at line $line"; return 2; }
    [[ $sha =~ ^[a-fA-F0-9]{64}$ ]] || return 2
    [[ -n $file && $file != */* && $file != *'..'* ]] || return 2
  done < "$manifest"
}
ks_manifest_fetch() {
  local manifest=$1 root=$2 name version arch url sha file target
  ks_manifest_validate "$manifest"
  mkdir -p -- "$root"
  while IFS=$'\t' read -r name version arch url sha file || [[ -n ${name:-} ]]; do
    [[ -z ${name:-} || $name == name || $name == \#* ]] && continue
    target=$root/$file
    if [[ -f $target ]] && ks_verify_sha256 "$target" "$sha"; then continue; fi
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --output "$target.part" "$url"
    ks_verify_sha256 "$target.part" "$sha"
    chmod 0644 "$target.part"
    mv -f -- "$target.part" "$target"
  done < "$manifest"
}
