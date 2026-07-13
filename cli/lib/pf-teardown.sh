#!/bin/bash
# cli/lib/pf-teardown.sh — 1-teardown (PLAN.md §6).
#
# Idempotent: removes only the ntfsmac pf anchor (never a global pfctl flush — only
# `-a ntfsmac`) and the VPN-bypass host route, if one was added. Always exits 0, even if
# there's nothing to remove (soft-optional — called from cli/commands/unmount.sh).
set -u

# teardown_pf [bridge_subnet_cidr]
teardown_pf() {
  local bridge_subnet="${1:-}"

  pfctl -a ntfsmac -F rules >/dev/null 2>&1 || true

  if [[ -n "$bridge_subnet" ]]; then
    route delete -net "$bridge_subnet" >/dev/null 2>&1 || true
  fi

  echo "pf-teardown: done"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  teardown_pf "$@"
fi
