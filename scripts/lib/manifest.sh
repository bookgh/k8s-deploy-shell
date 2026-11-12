#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_manifest_validate() {
  local manifest=${1:?manifest required} line name version arch url sha file tabs lineno=0 entries=0
  local -A names=() filenames=()
  [[ -r $manifest ]] || { ks_log ERROR "Manifest unreadable: $manifest"; return 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line == \#* ]] && continue
    [[ $line != *$'\r'* ]] || { ks_log ERROR "CR character in manifest line $lineno"; return 2; }
    if ((lineno == 1)) && [[ $line == $'name\tversion\tarch\turl\tsha256\tfilename' ]]; then continue; fi
    tabs=${line//[!$'\t']/}
    (("${#tabs}" == 5)) || { ks_log ERROR "Expected exactly six TSV columns at line $lineno"; return 2; }
    IFS=$'\t' read -r name version arch url sha file <<< "$line"
    [[ -n $name && -n $version && -n $arch && -n $url && -n $sha && -n $file ]] || { ks_log ERROR "Empty manifest field at line $lineno"; return 2; }
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && $version =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 2
    [[ $arch == amd64 || $arch == x86_64 || $arch == noarch ]] || return 2
    [[ $url =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#\[\]@!$%&()*+,;=-]*)?$ ]] || { ks_log ERROR "Unsafe or non-HTTPS URL at line $lineno"; return 2; }
    [[ $sha =~ ^[a-fA-F0-9]{64}$ ]] || return 2
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && $file != *'..'* ]] || return 2
    if [[ -n ${names[$name]:-} || -n ${filenames[$file]:-} ]]; then
      ks_log ERROR "Duplicate artifact name or filename at line $lineno"; return 2
    fi
    names[$name]=1; filenames[$file]=1
    ((entries+=1))
  done < "$manifest"
  ((entries > 0)) || { ks_log ERROR 'Artifact manifest contains no entries'; return 2; }
}
ks_manifest_fetch() {
  local manifest=${1:?manifest required} root=${2:?cache root required}
  local line name version arch url sha file target tmp
  ks_manifest_validate "$manifest"
  if ks_is_true "$KS_DRY_RUN"; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == \#* || $line == $'name\tversion\tarch\turl\tsha256\tfilename' ]] && continue
      IFS=$'\t' read -r name version arch url sha file <<< "$line"
      printf '[dry-run] fetch %s -> %s/%s sha256=%s\n' "$url" "$root" "$file" "$sha"
    done < "$manifest"
    return 0
  fi
  mkdir -p -- "$root"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* || $line == $'name\tversion\tarch\turl\tsha256\tfilename' ]] && continue
    IFS=$'\t' read -r name version arch url sha file <<< "$line"
    target=$root/$file
    if [[ -f $target ]] && ks_verify_sha256 "$target" "$sha"; then continue; fi
    tmp=$(mktemp "$root/.${file}.part.XXXXXX")
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 --output "$tmp" "$url"; then
      rm -f -- "$tmp"; return 1
    fi
    if ! ks_verify_sha256 "$tmp" "$sha"; then
      rm -f -- "$tmp"; return 1
    fi
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$target"
  done < "$manifest"
}
