#!/bin/bash
# build/lib/lock.sh — read pins from build/sources.lock.
# Usage: lock.sh get <KEY>
#
# Meant to be sourced by other build scripts, so this deliberately does NOT set -e
# (that would silently change the sourcing script's own shell options) and uses a
# private variable name (not SCRIPT_DIR) so it can't clobber a caller's own SCRIPT_DIR
# — a real bug hit once already (build-all.sh's orchestration paths broke after
# sourcing this file overwrote its SCRIPT_DIR).
set -u

_LOCK_SH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LOCK_FILE="${NTFSMAC_SOURCES_LOCK:-$_LOCK_SH_DIR/../sources.lock}"

lock_get() {
  local key="$1"
  if [[ ! -f "$LOCK_FILE" ]]; then
    echo "lock.sh: sources.lock not found at $LOCK_FILE" >&2
    return 1
  fi
  local line
  line=$(grep -E "^${key}=" "$LOCK_FILE" || true)
  if [[ -z "$line" ]]; then
    echo "lock.sh: key '$key' not found in $LOCK_FILE" >&2
    return 1
  fi
  printf '%s\n' "${line#*=}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    get)
      [[ $# -eq 2 ]] || { echo "usage: lock.sh get <KEY>" >&2; exit 1; }
      lock_get "$2"
      ;;
    *)
      echo "usage: lock.sh get <KEY>" >&2
      exit 1
      ;;
  esac
fi
