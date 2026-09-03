#!/bin/bash
# cli/lib/run-with-progress.sh — shared background-job watchdog so no CLI subprocess call can
# leave the user staring at a blocked terminal with no feedback and no way out (backend-hang
# reports: degraded vmnet bridge / missing vendor binaries can wedge `anylinuxfs` indefinitely).
# No GNU coreutils `timeout` dependency (macOS ships none) — same manual background+kill
# pattern already used by build/init-rootfs.sh's own VM-boot bound, generalized for reuse.
set -u

# Signal an exact process tree, children before parent. anylinuxfs forks a session leader for the
# VM; killing only the wrapper PID leaves that child reparented to launchd, holding the global
# instance lock forever and making subsequent drive scans appear empty.
collect_process_tree() {
  local parent="$1" child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    collect_process_tree "$child"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
  process_tree_pids+=("$parent")
}

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
      # Snapshot descendants before TERM: once an intermediate parent exits, launchd reparents
      # surviving VM children and a second tree walk can no longer discover them.
      local -a process_tree_pids=()
      local process_pid
      collect_process_tree "$pid"
      for process_pid in "${process_tree_pids[@]}"; do
        kill -TERM "$process_pid" 2>/dev/null || true
      done
      sleep 1
      for process_pid in "${process_tree_pids[@]}"; do
        kill -0 "$process_pid" 2>/dev/null && kill -KILL "$process_pid" 2>/dev/null || true
      done
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
