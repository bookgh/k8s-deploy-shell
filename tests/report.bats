#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$ROOT/scripts/lib/common.sh"
  source "$ROOT/scripts/lib/report.sh"
  CHECKS="$BATS_TEST_TMPDIR/checks.tsv"
  : > "$CHECKS"
}
@test "report overall is PASS when all checks pass" {
  ks_report_add "$CHECKS" api PASS ready
  ks_report_overall "$CHECKS"
  [ "$REPLY" = PASS ]
}
@test "report overall is PARTIAL when a check is not verified" {
  ks_report_add "$CHECKS" api PASS ready
  ks_report_add "$CHECKS" dns NOT_VERIFIED "no workload test"
  ks_report_overall "$CHECKS"
  [ "$REPLY" = PARTIAL ]
}
@test "report overall is FAIL when any check fails" {
  ks_report_add "$CHECKS" api PASS ready
  ks_report_add "$CHECKS" etcd FAIL unavailable
  ks_report_overall "$CHECKS"
  [ "$REPLY" = FAIL ]
}
