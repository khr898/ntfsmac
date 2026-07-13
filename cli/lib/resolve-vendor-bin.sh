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
# output if the binary can't be found anywhere. PATH is checked first (lets tests/dev
# environments override via a stub earlier on PATH), then both known install layouts.
resolve_vendor_bin() {
  local name="$1"
  local on_path
  on_path="$(command -v "$name" 2>/dev/null)"
  if [[ -n "$on_path" ]]; then
    printf '%s\n' "$on_path"
    return 0
  fi

  local prefix sub candidate
  for prefix in "$RESOLVE_VENDOR_BIN_PREFIX" "$RESOLVE_VENDOR_BIN_HOMEBREW_OPT_PREFIX"; do
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
