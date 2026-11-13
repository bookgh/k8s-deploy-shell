#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_images_validate() {
  local file=${1:?image lock required} line name reference digest archive archive_sha platform tabs lineno=0 entries=0
  local -A names=() refs=()
  [[ -r $file ]] || { ks_log ERROR "Image lock unreadable: $file"; return 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line == \#* ]] && continue
    if ((lineno == 1)) && [[ $line == $'name\treference\tdigest\tarchive\tarchive_sha256\tplatform' ]]; then continue; fi
    tabs=${line//[!$'\t']/}
    (("${#tabs}" == 5)) || { ks_log ERROR "Expected six image lock columns at line $lineno"; return 2; }
    IFS=$'\t' read -r name reference digest archive archive_sha platform <<< "$line"
    [[ -n $name && -n $reference && -n $digest && -n $archive && -n $archive_sha && -n $platform ]] || { ks_log ERROR "Empty image lock field at line $lineno"; return 2; }
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 2
    [[ $reference =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || { ks_log ERROR "Invalid image reference at line $lineno"; return 2; }
    [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ && $archive_sha =~ ^[a-fA-F0-9]{64}$ ]] || return 2
    [[ $archive =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.tar(\.gz|\.zst)?$ && $archive != *'..'* ]] || return 2
    [[ $platform == linux/amd64 ]] || { ks_log ERROR "Unsupported image platform at line $lineno"; return 2; }
    [[ -z ${names[$name]:-} && -z ${refs[$reference]:-} ]] || { ks_log ERROR "Duplicate image name/reference at line $lineno"; return 2; }
    names[$name]=1; refs[$reference]=1
    ((entries+=1))
  done < "$file"
  ((entries > 0)) || { ks_log ERROR 'Image lock contains no pinned images'; return 2; }
}
ks_images_require() {
  local file=$1 wanted
  shift
  for wanted in "$@"; do
    awk -F '\t' -v wanted="$wanted" 'NR>1 && $1==wanted {found=1} END {exit !found}' "$file" || {
      ks_log ERROR "Required addon image missing from lock: $wanted"
      return 2
    }
  done
}
ks_images_verify_archives() {
  local file=$1 root=$2 line name reference digest archive archive_sha platform
  ks_images_validate "$file"
  while IFS=$'\t' read -r name reference digest archive archive_sha platform || [[ -n ${name:-} ]]; do
    [[ -z ${name:-} || $name == name || $name == \#* ]] && continue
    [[ -f $root/$archive && ! -L $root/$archive ]] || { ks_log ERROR "Missing image archive: $root/$archive"; return 2; }
    ks_verify_sha256 "$root/$archive" "$archive_sha"
  done < "$file"
}
ks_addon_artifact() {
  local name=$1 expected_version=$2 expected_url=$3 file sha version arch url
  IFS=$'\t' read -r file sha version arch url < <(ks_manifest_lookup "$ROOT/artifacts/manifest.tsv" "$name")
  [[ $version == "$expected_version" && $url == "$expected_url" && $sha =~ ^[a-fA-F0-9]{64}$ ]] || {
    ks_log ERROR "Addon artifact pin mismatch: $name"
    return 2
  }
  REPLY=$file
  KS_ADDON_SHA=$sha
}
