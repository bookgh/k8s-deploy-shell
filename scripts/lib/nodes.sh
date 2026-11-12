#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ks_nodes_resolve_file() {
  local file=${1:?node inventory path required}
  [[ $file == /* ]] || file=$ROOT/$file
  REPLY=$(realpath -m -- "$file")
}

ks_nodes_validate() {
  local file=${1:?node inventory path required} masters_text=${2:?masters required} workers_text=${3:?workers required}
  local line node role address user port tabs lineno=0
  local -a masters=() workers=()
  local -A expected=() seen_nodes=() seen_ips=()
  ks_nodes_resolve_file "$file"; file=$REPLY
  [[ -r $file ]] || { ks_log ERROR "Node inventory unreadable: $file"; return 2; }
  IFS=$' ,\t' read -r -a masters <<< "$masters_text"
  IFS=$' ,\t' read -r -a workers <<< "$workers_text"
  for node in "${masters[@]}"; do expected[$node]=master; done
  for node in "${workers[@]}"; do expected[$node]=worker; done
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line == \#* ]] && continue
    [[ $line != *$'\r'* ]] || { ks_log ERROR "CR character in node inventory line $lineno"; return 2; }
    if ((lineno == 1)) && [[ $line == $'node_id\trole\taddress\tssh_user\tssh_port' ]]; then continue; fi
    tabs=${line//[!$'\t']/}
    (("${#tabs}" == 4)) || { ks_log ERROR "Expected five TSV columns at node inventory line $lineno"; return 2; }
    IFS=$'\t' read -r node role address user port <<< "$line"
    [[ -n $node && -n $role && -n $address && -n $user && -n $port ]] || return 2
    [[ $node =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
    [[ $role == master || $role == worker ]] || return 2
    [[ ${expected[$node]:-} == "$role" ]] || { ks_log ERROR "Unexpected node or role mismatch: $node/$role"; return 2; }
    [[ -z ${seen_nodes[$node]:-} ]] || { ks_log ERROR "Duplicate node ID: $node"; return 2; }
    [[ -z ${seen_ips[$address]:-} ]] || { ks_log ERROR "Duplicate node address: $address"; return 2; }
    ks_ipv4_to_int "$address" || { ks_log ERROR "Invalid IPv4 address for $node: $address"; return 2; }
    [[ $user =~ ^[a-z_][a-zA-Z0-9_-]*[$]?$ ]] || return 2
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port < 65536)) || return 2
    seen_nodes[$node]=1; seen_ips[$address]=1
  done < "$file"
  for node in "${!expected[@]}"; do
    [[ -n ${seen_nodes[$node]:-} ]] || { ks_log ERROR "Node missing from inventory: $node"; return 2; }
  done
  (("${#seen_nodes[@]}" == "${#expected[@]}")) || { ks_log ERROR 'Node inventory contains unexpected entries'; return 2; }
}

ks_node_lookup() {
  local file=${1:?node inventory path required} wanted=${2:?node ID required}
  local line node role address user port
  ks_nodes_resolve_file "$file"; file=$REPLY
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* || $line == $'node_id\trole\taddress\tssh_user\tssh_port' ]] && continue
    IFS=$'\t' read -r node role address user port <<< "$line"
    if [[ $node == "$wanted" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$role" "$address" "$user" "$port"
      return 0
    fi
  done < "$file"
  ks_log ERROR "Node not found: $wanted"
  return 1
}
