#!/usr/bin/env bats
# tests/cli/route-guard.bats — 1-vpn-bypass acceptance (PLAN.md §6).
# Mocks netstat + route; asserts the correct route command and that the VPN's own
# default route is never touched.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/cli/lib/route-guard.sh"
  STUB_DIR="$(mktemp -d)"
  ROUTE_LOG="$STUB_DIR/route.calls"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

stub_netstat_default() {
  cat > "$STUB_DIR/netstat" <<STUB
#!/bin/bash
echo "default            192.168.1.1        UGScg          $1"
STUB
  chmod +x "$STUB_DIR/netstat"
}

stub_route() {
  cat > "$STUB_DIR/route" <<STUB
#!/bin/bash
echo "\$@" >> "$ROUTE_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/route"
}

@test "adds a bypass route when the default route is on a VPN tunnel (utun)" {
  stub_netstat_default "utun4"
  stub_route
  run apply_vpn_bypass "172.27.1.0/30" "bridge100"
  [ "$status" -eq 0 ]
  [ -f "$ROUTE_LOG" ]
  run cat "$ROUTE_LOG"
  [[ "$output" == "add -net 172.27.1.0/30 -interface bridge100" ]]
}

@test "does not add a route when there is no VPN (default on en0)" {
  stub_netstat_default "en0"
  stub_route
  run apply_vpn_bypass "172.27.1.0/30" "bridge100"
  [ "$status" -eq 0 ]
  [ ! -f "$ROUTE_LOG" ]
}

@test "detects ppp and tun tunnel interfaces too" {
  stub_route
  stub_netstat_default "ppp0"
  run apply_vpn_bypass "172.27.1.0/30" "bridge100"
  [ -f "$ROUTE_LOG" ]
  rm -f "$ROUTE_LOG"

  stub_netstat_default "tun0"
  run apply_vpn_bypass "172.27.1.0/30" "bridge100"
  [ -f "$ROUTE_LOG" ]
}

@test "never modifies the VPN's own default route (no 'route delete default' / 'route change default')" {
  stub_netstat_default "utun4"
  stub_route
  run apply_vpn_bypass "172.27.1.0/30" "bridge100"
  [ "$status" -eq 0 ]
  run cat "$ROUTE_LOG"
  [[ "$output" != *"default"* ]]
}

@test "rejects missing arguments" {
  run apply_vpn_bypass
  [ "$status" -ne 0 ]
}
