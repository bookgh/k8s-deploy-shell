#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ks_report_add() {
  local file=${1:?checks file required} name=${2:?name required} status=${3:?status required} detail=${4:-}
  [[ $status == PASS || $status == FAIL || $status == NOT_VERIFIED ]] || return 2
  detail=${detail//$'\t'/ }
  detail=${detail//$'\n'/ }
  printf '%s\t%s\t%s\n' "$name" "$status" "$detail" >> "$file"
}
ks_report_overall() {
  local file=$1
  if grep -q $'\tFAIL\t' "$file"; then REPLY=FAIL
  elif grep -q $'\tNOT_VERIFIED\t' "$file"; then REPLY=PARTIAL
  else REPLY=PASS
  fi
}
ks_report_render() {
  local checks=$1 text_file=$2 json_file=$3 cluster=$4 overall=$5 timestamp=$6
  {
    printf 'Cluster: %s\nGenerated: %s\nOverall: %s\n\n' "$cluster" "$timestamp" "$overall"
    printf '%-32s %-14s %s\n' CHECK STATUS DETAIL
    while IFS=$'\t' read -r name status detail || [[ -n ${name:-} ]]; do
      [[ -n ${name:-} ]] || continue
      printf '%-32s %-14s %s\n' "$name" "$status" "$detail"
    done < "$checks"
  } > "$text_file"
  jq -Rn --arg cluster "$cluster" --arg generated_at "$timestamp" --arg overall "$overall" --rawfile raw "$checks" '
    {cluster:$cluster, generated_at:$generated_at, overall:$overall,
     checks:($raw | split("\n") | map(select(length>0) | split("\t") |
       {name:.[0],status:.[1],detail:.[2]}))}
  ' > "$json_file"
  chmod 0600 "$text_file" "$json_file"
}
