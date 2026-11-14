#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Read-only validation. It never contacts nodes or invokes etcdutl.
ks_etcd_restore_manifest_validate() {
  local manifest=${1:?manifest path required}
  local snapshot=${2:?snapshot path required}
  local expected_cluster=${3:?expected cluster name required}
  local expected_version=${4:?expected etcd version required}
  local expected_members=${5:?expected member map required}
  local line key value tab actual_sha actual_size mode
  local -A fields=()
  local required

  [[ -f $manifest && ! -L $manifest ]] || {
    ks_log ERROR "Restore manifest must be a regular non-symlink file: $manifest"
    return 2
  }
  [[ -f $snapshot && ! -L $snapshot && -r $snapshot && -s $snapshot ]] || {
    ks_log ERROR "Snapshot must be a non-empty readable regular non-symlink file: $snapshot"
    return 2
  }

  mode=$(stat -c '%a' -- "$manifest") || return 2
  (( (8#$mode & 0022) == 0 )) || {
    ks_log ERROR "Restore manifest must not be group/world writable: $manifest"
    return 2
  }

  tab=$(printf '\t')
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ $line == *"$tab"* && ${line#*"$tab"} != *"$tab"* ]] || {
      ks_log ERROR 'Malformed restore manifest row'
      return 2
    }
    key=${line%%"$tab"*}
    value=${line#*"$tab"}
    [[ -n $key && -n $value ]] || {
      ks_log ERROR 'Malformed restore manifest row'
      return 2
    }
    [[ $key =~ ^[a-z][a-z0-9_]*$ ]] || {
      ks_log ERROR "Invalid restore manifest key: $key"
      return 2
    }
    [[ ! -v fields[$key] ]] || {
      ks_log ERROR "Duplicate restore manifest key: $key"
      return 2
    }
    fields[$key]=$value
  done < "$manifest"

  for required in schema_version cluster_name etcd_version snapshot_sha256 snapshot_revision snapshot_hash snapshot_total_keys snapshot_total_size snapshot_file_size cluster_id members created_at_utc; do
    [[ -v fields[$required] ]] || {
      ks_log ERROR "Missing restore manifest field: $required"
      return 2
    }
  done
  (( ${#fields[@]} == 12 )) || {
    ks_log ERROR 'Restore manifest contains unknown fields'
    return 2
  }

  [[ ${fields[schema_version]} == 1 ]] || return 2
  [[ ${fields[cluster_name]} == "$expected_cluster" ]] || {
    ks_log ERROR 'Restore manifest cluster name does not match configuration'
    return 2
  }
  [[ ${fields[etcd_version]} == "$expected_version" ]] || {
    ks_log ERROR 'Restore manifest etcd version does not match the selected binary'
    return 2
  }
  [[ ${fields[members]} == "$expected_members" ]] || {
    ks_log ERROR 'Restore manifest member topology does not exactly match inventory'
    return 2
  }
  [[ ${fields[snapshot_sha256]} =~ ^[a-fA-F0-9]{64}$ ]] || return 2
  [[ ${fields[snapshot_revision]} =~ ^[1-9][0-9]*$ ]] || return 2
  [[ ${fields[snapshot_hash]} =~ ^[a-fA-F0-9]{8,64}$ ]] || return 2
  [[ ${fields[snapshot_total_keys]} =~ ^[0-9]+$ ]] || return 2
  [[ ${fields[snapshot_total_size]} =~ ^[1-9][0-9]*$ ]] || return 2
  [[ ${fields[snapshot_file_size]} =~ ^[1-9][0-9]*$ ]] || return 2
  [[ ${fields[cluster_id]} =~ ^[a-fA-F0-9]{8,32}$ ]] || return 2
  [[ ${fields[created_at_utc]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 2

  actual_sha=$(ks_sha256_file "$snapshot") || return 2
  [[ ${actual_sha,,} == "${fields[snapshot_sha256],,}" ]] || {
    ks_log ERROR 'Snapshot SHA256 does not match restore manifest'
    return 1
  }
  actual_size=$(stat -c '%s' -- "$snapshot") || return 2
  [[ $actual_size == "${fields[snapshot_file_size]}" ]] || {
    ks_log ERROR 'Snapshot file size does not match restore manifest'
    return 1
  }

  ks_log INFO "Restore manifest preflight passed for cluster=$expected_cluster revision=${fields[snapshot_revision]}"
}
