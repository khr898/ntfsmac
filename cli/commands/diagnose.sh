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
  if [[ ! -x "$lock_sh" ]]; then
    lock_sh="$PREFIX/libexec/ntfsmac/lib/lock.sh"
  fi

  local kernel_dir="${NTFSMAC_VENDOR_KERNEL_DIR:-$REPO_ROOT/vendor/kernel}"
  if [[ ! -d "$kernel_dir" ]]; then
    kernel_dir="$PREFIX/lib"
  fi

  if [[ ! -x "$lock_sh" ]]; then
    echo "unknown"
    return
  fi

  # shellcheck source=../../build/lib/lock.sh
  source "$lock_sh"
  local expected actual
  expected="$(lock_get LIBKRUNFW_MODULES_SHA256 2>/dev/null)" || { echo "unknown"; return; }

  local squashfs_file="$kernel_dir/modules.squashfs"
  if [[ ! -f "$squashfs_file" && -f "$PREFIX/lib/modules.squashfs" ]]; then
    squashfs_file="$PREFIX/lib/modules.squashfs"
  fi

  [[ -f "$squashfs_file" ]] || { echo "missing"; return; }
  actual="$(shasum -a 256 "$squashfs_file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] && echo "match" || echo "mismatch"
}

check_bridge_up() {
  if pgrep 'vmnet-helper' >/dev/null 2>&1 || \
     pgrep 'gvproxy' >/dev/null 2>&1 || \
     pgrep 'anylinuxfs' >/dev/null 2>&1 || \
     ifconfig | grep -E "inet 172\.(1[6-9]|2[0-9]|3[0-1])\." >/dev/null 2>&1; then
    echo "up"
  else
    echo "down"
  fi
}

current_mounts() {
  mount -t nfs 2>/dev/null | awk '{print $1, "on", $3}'
}

# check_macos_version — reports the macOS product version. Two reasons diagnose grew this:
# (1) triage reports (see README "Troubleshooting" / the issue tracker) kept omitting the OS
# version, so the first ask on every "installed but not working" report was "which macOS?";
# (2) ntfsmac requires macOS 13.0+, so an older host is a real cause of that symptom, worth
# flagging directly. Overridable for tests via NTFSMAC_MACOS_VERSION_OVERRIDE — note the `-`
# (not `:-`) default: an explicitly-set empty value simulates sw_vers returning nothing
# (reported as "unknown"), while leaving it unset runs sw_vers normally. bash-3.2 + set -u
# safe (plain default expansion, no indirect ${!var}).
check_macos_version() {
  local ver
  ver="${NTFSMAC_MACOS_VERSION_OVERRIDE-$(sw_vers -productVersion 2>/dev/null)}"
  if [[ -n "$ver" ]]; then
    printf '%s\n' "$ver"
  else
    printf 'unknown\n'
  fi
}

main() {
  local kernel_pin bridge mounts healthy=1
  local macos_version macos_major macos_supported=1
  MISSING_BINS=0
  QUARANTINED_BINS=0

  macos_version="$(check_macos_version)"
  check_vendor_binaries
  kernel_pin="$(check_kernel_pin)"
  bridge="$(check_bridge_up)"
  mounts="$(current_mounts)"

  # ntfsmac requires macOS 13.0+ on Apple Silicon. Only a real, parseable major version
  # below 13 flips health; an unknown/undetected version is reported but left non-fatal.
  # Portable "is it all digits" test (case glob) instead of a regex — bash-3.2 safe.
  macos_major="${macos_version%%.*}"
  case "$macos_major" in
    ''|*[!0-9]*) macos_major="" ;;
  esac
  if [[ -n "$macos_major" && "$macos_major" -lt 13 ]]; then
    healthy=0
    macos_supported=0
  fi

  [[ "$MISSING_BINS" -gt 0 ]] && healthy=0
  [[ "$QUARANTINED_BINS" -gt 0 ]] && healthy=0
  [[ "$kernel_pin" == "mismatch" ]] && healthy=0

  if [[ $json_mode -eq 1 ]]; then
    printf '{"healthy":%s,"macos_version":"%s","missing_binaries":%s,"quarantined_binaries":%s,"kernel_pin":"%s","bridge":"%s"}\n' \
      "$([[ $healthy -eq 1 ]] && echo true || echo false)" "$macos_version" "$MISSING_BINS" "$QUARANTINED_BINS" "$kernel_pin" "$bridge"
  else
    echo "diagnose: macOS version: $macos_version"
    [[ "$macos_supported" -eq 0 ]] && echo "diagnose:   unsupported — ntfsmac requires macOS 13.0+"
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
