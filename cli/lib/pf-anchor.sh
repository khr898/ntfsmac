#!/bin/bash
# cli/lib/pf-anchor.sh — 1-pf-rules (PLAN.md §6, L2, L8; Phase 1 defense-in-depth).
#
# Renders cli/pf/ntfsmac.anchor.tmpl for a given /30 subnet: deny-by-default, allow only
# NFS traffic (2049/32767) to/from the host-only vmnet bridge. Never widens scope beyond
# the given subnet, never hardcodes one — the caller must always supply it.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
TEMPLATE="${NTFSMAC_PF_TEMPLATE:-$SCRIPT_DIR/../pf/ntfsmac.anchor.tmpl}"

# render_pf_anchor <subnet-cidr> — prints the rendered anchor to stdout.
render_pf_anchor() {
  local subnet="${1:-}"
  if [[ -z "$subnet" ]]; then
    echo "pf-anchor: a subnet CIDR is required" >&2
    return 1
  fi
  # Security review finding (2026-07-13, LOW, defense-in-depth): the `sed` substitution below
  # only fails safe on delimiter/newline abuse by accident of BSD sed's own parser — a valid but
  # over-wide CIDR (e.g. 0.0.0.0/0) previously sailed through untouched. Mirrors
  # HelperProtocol.swift's isValidSubnetCIDR (private /30 only) so this script fails the same
  # way even if invoked directly, not just via the helper's XPC gate.
  if [[ ! "$subnet" =~ ^(10\.[0-9]{1,3}\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)[0-9]{1,3}\.[0-9]{1,3}/30$ ]]; then
    echo "pf-anchor: subnet CIDR must be a private /30 (got \"$subnet\")" >&2
    return 1
  fi
  if [[ ! -f "$TEMPLATE" ]]; then
    echo "pf-anchor: template not found: $TEMPLATE" >&2
    return 1
  fi
  sed "s|{{SUBNET}}|$subnet|g" "$TEMPLATE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  render_pf_anchor "$@"
fi
