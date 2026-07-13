#!/usr/bin/env bats
# tests/build/gvproxy.bats — v-gvproxy acceptance (PLAN.md §6).
# Runs the real build (network clone + go build) — same live-verification pattern as
# fetch-prebuilt.sh. Slow; not mocked, since the acceptance criterion is a real arm64 binary.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/build-gvproxy.sh"
  BIN="$REPO_ROOT/vendor/bin/gvproxy"
}

@test "build-gvproxy.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "build-gvproxy.sh HARD-STOPs on an unresolved TODO-KAVEEN pin" {
  local lock
  lock="$(mktemp)"
  printf 'GVPROXY_VERSION=TODO-KAVEEN\nGVPROXY_COMMIT=TODO-KAVEEN\n' > "$lock"
  NTFSMAC_SOURCES_LOCK="$lock" run "$SCRIPT"
  rm -f "$lock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HARD-STOP"* ]]
}

@test "builds gvproxy from source: vendor/bin/gvproxy is an executable arm64 binary" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -x "$BIN" ]
  run file "$BIN"
  [[ "$output" == *"arm64"* ]]
}
