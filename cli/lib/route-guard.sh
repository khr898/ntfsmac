#!/bin/bash
# cli/lib/route-guard.sh — 1-vpn-bypass (PLAN.md §6; Phase 1 defense-in-depth).
#
# Detects whether the current default route is on a VPN-style tunnel interface (utunN,
# ppp, or tun) and, if so, adds a host route for the ntfsmac bridge subnet directly on
# the bridge interface — so NFS/vmnet traffic never leaks onto the VPN tunnel. Never
# touches the VPN's own default route (only adds our own scoped route).
set -u

# apply_vpn_bypass <bridge_subnet_cidr> <bridge_iface>
apply_vpn_bypass() {
  local bridge_subnet="${1:-}" bridge_iface="${2:-}"

  if [[ -z "$bridge_subnet" || -z "$bridge_iface" ]]; then
    echo "route-guard: bridge subnet and interface are both required" >&2
    return 1
  fi

  local default_iface
  default_iface="$(netstat -rn -f inet 2>/dev/null | awk '/^default/ {print $NF; exit}')"

  if [[ "$default_iface" =~ ^(utun|ppp|tun) ]]; then
    echo "route-guard: VPN detected on default route ($default_iface) — adding bypass route for $bridge_subnet via $bridge_iface"
    route add -net "$bridge_subnet" -interface "$bridge_iface"
    return $?
  fi

  echo "route-guard: no VPN on default route (${default_iface:-none}) — no bypass needed"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  apply_vpn_bypass "$@"
fi
