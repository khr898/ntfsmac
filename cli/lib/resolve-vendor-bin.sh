#!/bin/bash
# cli/lib/resolve-vendor-bin.sh — locates a vendored binary (anylinuxfs, gvproxy,
# vmnet-helper, vmproxy) without relying on PATH. install.sh puts anylinuxfs at
# $PREFIX/bin and the rest at $PREFIX/libexec (install_binaries()); the homebrew tap
# Formula uses the same layout under $HOMEBREW_OPT_PREFIX. Neither the GUI's privileged
# helper (launchd daemon, minimal system PATH) nor a bare CLI invocation can be trusted to
# have $PREFIX/bin on PATH — same class of bug diagnose.sh's own resolve_bin() already
# guarded against; this is that logic extracted so nfs-mount.sh/list-drives.sh/unmount.sh
# stop duplicating (and risk drifting from) it.
set -u

RESOLVE_VENDOR_BIN_PREFIX="${NTFSMAC_PREFIX:-/usr/local/ntfsmac}"
RESOLVE_VENDOR_BIN_HOMEBREW_OPT_PREFIX="/opt/homebrew/opt/ntfsmac"

# resolve_vendor_bin <name> — prints the resolved path and returns 0, or returns 1 with no
# output if the binary can't be found anywhere.
# Security review finding: when running as root (EUID == 0), PATH lookup is skipped and only
# fixed root-owned paths are checked. macOS sudo preserves the user's PATH by default, so
# checking PATH when running as root would allow an unprivileged user to execute arbitrary
# code as root by placing an anylinuxfs binary in their PATH. Tests opt in via NTFSMAC_ALLOW_UNSAFE_PATH=1.
resolve_vendor_bin() {
  local name="$1"
  local effective_uid="${NTFSMAC_EFFECTIVE_UID:-$EUID}"

  # Only check PATH if not running as root or if explicitly allowed by test harnesses
  if [[ $effective_uid -ne 0 || "${NTFSMAC_ALLOW_UNSAFE_PATH:-0}" == "1" ]]; then
    local on_path
    on_path="$(command -v "$name" 2>/dev/null)"
    if [[ -n "$on_path" ]]; then
      printf '%s\n' "$on_path"
      return 0
    fi
  fi

  local prefixes
  if [[ $effective_uid -eq 0 && "${NTFSMAC_ALLOW_UNSAFE_PATH:-0}" != "1" ]]; then
    prefixes=("$RESOLVE_VENDOR_BIN_PREFIX")
  else
    prefixes=("$RESOLVE_VENDOR_BIN_PREFIX" "$RESOLVE_VENDOR_BIN_HOMEBREW_OPT_PREFIX")
  fi

  local prefix sub candidate
  for prefix in "${prefixes[@]}"; do
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
