#!/usr/bin/env bats
# tests/cli/run-with-progress.bats — shared subprocess watchdog used by list-drives.sh,
# nfs-mount.sh, unmount.sh so no CLI operation can hang with zero feedback.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$REPO_ROOT/cli/lib/run-with-progress.sh"
  source "$LIB"
}

@test "fast command returns immediately with its real exit code" {
  run run_with_progress 5 2 "test" - true
  [ "$status" -eq 0 ]
}

@test "propagates a real non-zero exit code, not a timeout" {
  run run_with_progress 5 2 "test" - false
  [ "$status" -eq 1 ]
}

@test "captures stdout to the given outfile" {
  local outfile
  outfile="$(mktemp)"
  run_with_progress 5 2 "test" "$outfile" echo "hello"
  [ "$(cat "$outfile")" = "hello" ]
  rm -f "$outfile"
}

@test "kills a hanging command after the timeout and returns 124 with a clear message" {
  run run_with_progress 1 1 "test-label" - sleep 30
  [ "$status" -eq 124 ]
  [[ "$output" == *"test-label"*"no response after 1s"* ]]
}

@test "does not leave the killed process running" {
  run_with_progress 1 1 "test" - sleep 30 &
  local watchdog_pid=$!
  # run_with_progress itself returns 124 on this path (a "failure" exit code) — the point of
  # this test is only whether the killed `sleep 30` is still alive afterward, not the
  # watchdog's own exit status (already covered above).
  wait "$watchdog_pid" || true
  sleep 1
  # No leaked `sleep 30` from this test should still be alive.
  ! pgrep -f "sleep 30" >/dev/null 2>&1
}

@test "kills descendants that detach from a TERM-exiting parent" {
  local marker="$BATS_TEST_TMPDIR/orphan.pid"
  local fixture="$BATS_TEST_TMPDIR/forking-command.sh"
  cat > "$fixture" <<'STUB'
#!/bin/bash
( trap '' TERM; sleep 30 ) &
child_pid=$!
echo "$child_pid" > "$1"
trap 'exit 0' TERM
wait
STUB
  chmod +x "$fixture"

  run run_with_progress 1 1 "fork-test" - "$fixture" "$marker"
  [ "$status" -eq 124 ]
  local child_pid
  child_pid="$(cat "$marker")"
  ! kill -0 "$child_pid" 2>/dev/null
}

@test "prints a heartbeat line while a slow-but-eventually-completing command runs" {
  run run_with_progress 5 1 "test-label" - sleep 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-label: still working"* ]]
}
