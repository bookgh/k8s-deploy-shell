#!/usr/bin/env bats
@test "upgrade planner rejects unsupported downgrade" {
  run bash -c '
    current=v1.37.2
    target=v1.36.9
    [[ $current =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    cm=${BASH_REMATCH[2]}; cp=${BASH_REMATCH[3]}
    [[ $target =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    tm=${BASH_REMATCH[2]}; tp=${BASH_REMATCH[3]}
    ((tm >= cm && tm <= cm + 1)) && ! ((tm == cm && tp < cp))
  '
  [ "$status" -ne 0 ]
}
@test "upgrade planner accepts one minor increment" {
  run bash -c '
    current=v1.36.5
    target=v1.37.2
    [[ $current =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    cm=${BASH_REMATCH[2]}
    [[ $target =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    tm=${BASH_REMATCH[2]}
    ((tm >= cm && tm <= cm + 1))
  '
  [ "$status" -eq 0 ]
}
