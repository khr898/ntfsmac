#!/usr/bin/env bats
# tests/cli/teardown.bats — 1-teardown acceptance (PLAN.md §6).
# Mocks pfctl + route. Asserts pfctl -a ntfsmac -F + route delete calls, and exit 0 even
# when the stubs simulate "nothing to remove" (non-zero exit swallowed).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/lib/pf-teardown.sh"
  STUB_DIR="$(mktemp -d)"
  PFCTL_LOG="$STUB_DIR/pfctl.calls"
  ROUTE_LOG="$STUB_DIR/route.calls"

  cat > "$STUB_DIR/pfctl" <<STUB
#!/bin/bash
echo "\$@" >> "$PFCTL_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/pfctl"

  cat > "$STUB_DIR/route" <<STUB
#!/bin/bash
echo "\$@" >> "$ROUTE_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/route"

  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

@test "flushes only the ntfsmac anchor, never a global pfctl flush" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$PFCTL_LOG"
  [[ "$output" == "-a ntfsmac -F rules" ]]
}

@test "deletes the bypass route when a subnet is given" {
  run "$SCRIPT" "172.27.1.0/30"
  [ "$status" -eq 0 ]
  run cat "$ROUTE_LOG"
  [[ "$output" == "delete -net 172.27.1.0/30" ]]
}

@test "no subnet given: pfctl still runs, route is never called" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$ROUTE_LOG" ]
}

@test "idempotent: exits 0 even when pfctl and route report nothing to remove" {
  cat > "$STUB_DIR/pfctl" <<STUB
#!/bin/bash
echo "\$@" >> "$PFCTL_LOG"
exit 1
STUB
  chmod +x "$STUB_DIR/pfctl"
  cat > "$STUB_DIR/route" <<STUB
#!/bin/bash
echo "\$@" >> "$ROUTE_LOG"
exit 1
STUB
  chmod +x "$STUB_DIR/route"

  run "$SCRIPT" "172.27.1.0/30"
  [ "$status" -eq 0 ]
}

@test "never flushes pf rules outside the ntfsmac anchor (no bare 'pfctl -F')" {
  run grep -E -- '-F(\s|$)' "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c -- '^\s*pfctl -F\b' "$SCRIPT"
  [ "$status" -ne 0 ]
}
