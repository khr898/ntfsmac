#!/usr/bin/env bats
# tests/cli/pf-rules.bats — 1-pf-rules acceptance (PLAN.md §6, L2, L8).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/cli/lib/pf-anchor.sh"
  SUBNET="172.27.1.0/30"
  INTERFACE="bridge100"
  SESSION="disk2s1"
}

@test "renders bridge-scoped quick deny rules" {
  run render_pf_anchor "$SUBNET" "$INTERFACE" "$SESSION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"block drop quick on $INTERFACE"* ]]
  [[ "$output" == *"block drop quick on $INTERFACE inet6 all"* ]]
  [[ "$output" != *"block in all"* ]]
  [[ "$output" != *"block out all"* ]]
}

@test "renders allow rules scoped to the given subnet only" {
  run render_pf_anchor "$SUBNET" "$INTERFACE" "$SESSION"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $SUBNET to $SUBNET"* ]]
  [[ "$output" == *"port { 2049, 32767 }"* ]]
  [[ "$output" == *"label \"ntfsmac-$SESSION-nfs\""* ]]
}

@test "no unrendered placeholder remains" {
  run render_pf_anchor "$SUBNET" "$INTERFACE" "$SESSION"
  [ "$status" -eq 0 ]
  [[ "$output" != *"{{SUBNET}}"* ]]
  [[ "$output" != *"{{INTERFACE}}"* ]]
  [[ "$output" != *"{{SESSION}}"* ]]
}

@test "never widens pass scope beyond the measured subnet and interface" {
  run render_pf_anchor "$SUBNET" "$INTERFACE" "$SESSION"
  [ "$status" -eq 0 ]
  rendered="$output"
  run bash -c "echo \"$rendered\" | grep '^pass' | grep -c ' any '"
  [ "$status" -ne 0 ]
  [[ "$rendered" == *"on $INTERFACE"* ]]
}

@test "a different subnet renders with no cross-contamination" {
  run render_pf_anchor "172.28.2.0/30" "bridge101" "disk3s2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"172.28.2.0/30"* ]]
  [[ "$output" != *"172.27.1.0/30"* ]]
}

@test "rejects a missing subnet argument" {
  run render_pf_anchor
  [ "$status" -ne 0 ]
}

@test "rejects an untrusted interface or session" {
  run render_pf_anchor "$SUBNET" "en0" "$SESSION"
  [ "$status" -ne 0 ]
  run render_pf_anchor "$SUBNET" "$INTERFACE" "disk2s1; pfctl -d"
  [ "$status" -ne 0 ]
}

@test "rejects an out-of-pool or non-canonical /30" {
  run render_pf_anchor "10.1.2.0/30" "$INTERFACE" "$SESSION"
  [ "$status" -ne 0 ]
  run render_pf_anchor "172.27.1.2/30" "$INTERFACE" "$SESSION"
  [ "$status" -ne 0 ]
  run render_pf_anchor "172.27.999.0/30" "$INTERFACE" "$SESSION"
  [ "$status" -ne 0 ]
}
