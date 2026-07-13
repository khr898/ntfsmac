#!/bin/bash
# cli/lib/run-with-progress.sh — shared background-job watchdog so no CLI subprocess call can
# leave the user staring at a blocked terminal with no feedback and no way out (backend-hang
# reports: degraded vmnet bridge / missing vendor binaries can wedge `anylinuxfs` indefinitely).
# No GNU coreutils `timeout` dependency (macOS ships none) — same manual background+kill
# pattern already used by build/init-rootfs.sh's own VM-boot bound, generalized for reuse.
set -u

# run_with_progress <timeout_secs> <heartbeat_secs> <label> <outfile|-> <cmd...>
#   <outfile>: capture <cmd>'s stdout there (caller reads it after a 0 return); pass "-" to
#              let <cmd> inherit this script's real stdout/stderr instead (used for anylinuxfs
#              mount/unmount, whose own live "macOS: ..." progress lines must stay visible,
#              not get buffered until the whole thing finishes).
#   Returns <cmd>'s real exit code on completion, or 124 (matching coreutils `timeout`'s
#   convention) after killing it once <timeout_secs> of wall time elapses with no exit —
#   printing exactly why, via <label>, before returning so the caller never has to guess.
run_with_progress() {
  local timeout_secs="$1" heartbeat_secs="$2" label="$3" outfile="$4"
  shift 4

  if [[ "$outfile" == "-" ]]; then
    "$@" &
  else
    "$@" > "$outfile" 2>/dev/null &
  fi
  local pid=$!
  # `SECONDS` (bash builtin, auto-incrementing since shell start) instead of manually adding up
  # sleep durations — polls on a short 0.2s tick so a fast-exiting child (the common case) isn't
  # taxed a full heartbeat_secs of dead wait just to notice it's already done; heartbeat_secs
  # only paces how often the "still working" line prints, not how often we check.
  local start=$SECONDS next_heartbeat=$heartbeat_secs elapsed

  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    kill -0 "$pid" 2>/dev/null || break
    elapsed=$((SECONDS - start))
    if [[ $elapsed -ge $timeout_secs ]]; then
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "$label: no response after ${timeout_secs}s — backend may be wedged (try 'ntfsmac diagnose')" >&2
      return 124
    fi
    if [[ $elapsed -ge $next_heartbeat ]]; then
      echo "$label: still working (${elapsed}s elapsed)..." >&2
      next_heartbeat=$((next_heartbeat + heartbeat_secs))
    fi
  done

  wait "$pid"
}
