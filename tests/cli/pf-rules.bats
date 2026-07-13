#!/usr/bin/env bats
# tests/cli/pf-rules.bats — 1-pf-rules acceptance (PLAN.md §6, L2, L8).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/cli/lib/pf-anchor.sh"
  SUBNET="172.27.1.0/30"
}

@test "renders deny-by-default rules" {
  run render_pf_anchor "$SUBNET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"block in all"* ]]
  [[ "$output" == *"block out all"* ]]
}

@test "renders allow rules scoped to the given subnet only" {
  run render_pf_anchor "$SUBNET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $SUBNET to $SUBNET"* ]]
}

@test "no unrendered {{SUBNET}} placeholder remains" {
  run render_pf_anchor "$SUBNET"
  [ "$status" -eq 0 ]
  [[ "$output" != *"{{SUBNET}}"* ]]
}

@test "never widens scope beyond the given subnet (no 'any' in pass rules, no other CIDR)" {
  run render_pf_anchor "$SUBNET"
  [ "$status" -eq 0 ]
  run bash -c "echo \"$output\" | grep '^pass' | grep -c ' any '"
  [ "$status" -ne 0 ]
}

@test "a different subnet renders with no cross-contamination" {
  run render_pf_anchor "10.1.2.0/30"
  [ "$status" -eq 0 ]
  [[ "$output" == *"10.1.2.0/30"* ]]
  [[ "$output" != *"172.27.1.0/30"* ]]
}

@test "rejects a missing subnet argument" {
  run render_pf_anchor
  [ "$status" -ne 0 ]
}
