#!/bin/bash
# cli/commands/diagnose.sh — 2-diagnose (PLAN.md §6).
#
# Read-only health report: vendor binaries present, vmnet-helper reachable, bridge up,
# kernel pin match, quarantine xattr status, current NFS mounts. No privileged op ever
# runs here (diagnose never mounts/unmounts/touches pf/route).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." &>/dev/null && pwd)"
# Same two candidates helper/HelperProtocol.swift's resolveNtfsmacPrefix() checks (bash and
# Swift can't share source — kept in sync deliberately, same pattern as list-drives.sh's own
# comment about its Swift-side counterpart). NTFSMAC_PREFIX matches every other command's
# convention (install.sh, uninstall.sh).
PREFIX="${NTFSMAC_PREFIX:-/usr/local/ntfsmac}"
HOMEBREW_OPT_PREFIX="/opt/homebrew/opt/ntfsmac"

json_mode=0
for arg in "$@"; do
  [[ "$arg" == "--json" ]] && json_mode=1
done

# env_override_for <name> — explicit lookup, not indirect (${!var}) expansion: macOS's
# system /bin/bash is 3.2, where indirect expansion combined with `set -u` unreliably
# errors "unbound variable" even when a `:-` default is given. A plain case statement
# is bash-3.2-safe and set -u-safe.
env_override_for() {
  case "$1" in
    anylinuxfs) printf '%s' "${NTFSMAC_ANYLINUXFS_BIN:-}" ;;
    gvproxy) printf '%s' "${NTFSMAC_GVPROXY_BIN:-}" ;;
    vmnet-helper) printf '%s' "${NTFSMAC_VMNET_HELPER_BIN:-}" ;;
    vmproxy) printf '%s' "${NTFSMAC_VMPROXY_BIN:-}" ;;
  esac
}

resolve_bin() {
  local name="$1" override_val
  override_val="$(env_override_for "$name")"
  if [[ -n "$override_val" ]]; then
    printf '%s\n' "$override_val"
    return 0
  fi

  local on_path
  on_path="$(command -v "$name" 2>/dev/null)"
  if [[ -n "$on_path" ]]; then
    printf '%s\n' "$on_path"
    return 0
  fi

  # gvproxy/vmnet-helper/vmproxy live in $PREFIX/libexec by design (install.sh, Formula) —
  # never on PATH. Checking only `command -v` reported them "missing" on every correctly
  # installed system; check both real install layouts (fixed prefix, homebrew tap) before
  # giving up.
  local prefix sub candidate
  for prefix in "$PREFIX" "$HOMEBREW_OPT_PREFIX"; do
    for sub in bin libexec; do
      candidate="$prefix/$sub/$name"
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

# check_vendor_binaries — sets MISSING_BINS / QUARANTINED_BINS globals (plain scalars,
# not an associative array: macOS's system bash 3.2 has no `declare -A`).
check_vendor_binaries() {
  MISSING_BINS=0
  QUARANTINED_BINS=0
  local name bin
  for name in anylinuxfs gvproxy vmnet-helper vmproxy; do
    bin="$(resolve_bin "$name")"
    if [[ -z "$bin" || ! -x "$bin" ]]; then
      MISSING_BINS=$((MISSING_BINS + 1))
      continue
    fi
    if xattr -p com.apple.quarantine "$bin" >/dev/null 2>&1; then
      QUARANTINED_BINS=$((QUARANTINED_BINS + 1))
    fi
  done
}

check_kernel_pin() {
  local lock_sh="$REPO_ROOT/build/lib/lock.sh"
  local kernel_dir="${NTFSMAC_VENDOR_KERNEL_DIR:-$REPO_ROOT/vendor/kernel}"
  [[ -x "$lock_sh" ]] || { echo "unknown"; return; }
  # shellcheck source=../../build/lib/lock.sh
  source "$lock_sh"
  local expected actual
  expected="$(lock_get LIBKRUNFW_MODULES_SHA256 2>/dev/null)" || { echo "unknown"; return; }
  [[ -f "$kernel_dir/modules.squashfs" ]] || { echo "missing"; return; }
  actual="$(shasum -a 256 "$kernel_dir/modules.squashfs" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] && echo "match" || echo "mismatch"
}

check_bridge_up() {
  pgrep -f 'vmnet-helper' >/dev/null 2>&1 && echo "up" || echo "down"
}

current_mounts() {
  mount -t nfs 2>/dev/null | awk '{print $1, "on", $3}'
}

main() {
  local kernel_pin bridge mounts healthy=1
  MISSING_BINS=0
  QUARANTINED_BINS=0

  check_vendor_binaries
  kernel_pin="$(check_kernel_pin)"
  bridge="$(check_bridge_up)"
  mounts="$(current_mounts)"

  [[ "$MISSING_BINS" -gt 0 ]] && healthy=0
  [[ "$QUARANTINED_BINS" -gt 0 ]] && healthy=0
  [[ "$kernel_pin" == "mismatch" ]] && healthy=0

  if [[ $json_mode -eq 1 ]]; then
    printf '{"healthy":%s,"missing_binaries":%s,"quarantined_binaries":%s,"kernel_pin":"%s","bridge":"%s"}\n' \
      "$([[ $healthy -eq 1 ]] && echo true || echo false)" "$MISSING_BINS" "$QUARANTINED_BINS" "$kernel_pin" "$bridge"
  else
    echo "diagnose: vendor binaries missing: $MISSING_BINS"
    echo "diagnose: quarantined binaries: $QUARANTINED_BINS"
    echo "diagnose: kernel pin: $kernel_pin"
    echo "diagnose: vmnet bridge: $bridge"
    echo "diagnose: current NFS mounts:"
    if [[ -n "$mounts" ]]; then
      echo "$mounts"
    else
      echo "  (none)"
    fi
    echo "diagnose: overall: $([[ $healthy -eq 1 ]] && echo healthy || echo degraded)"
  fi

  [[ $healthy -eq 1 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
