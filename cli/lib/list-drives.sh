#!/bin/bash
# cli/lib/list-drives.sh — shared drive enumeration for mount/unmount's no-argument
# interactive picker. Parses `anylinuxfs list --microsoft` the same way the GUI's
# gui/Drives/DriveScanner.swift DriveListParser does (there is no --json flag on ListCmd,
# confirmed against vendor/.../anylinuxfs/src/cli.rs) — one shared regex shape, two
# implementations, kept in sync deliberately since bash and Swift can't share source.
set -u

LIST_DRIVES_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=run-with-progress.sh
source "$LIST_DRIVES_LIB_DIR/run-with-progress.sh"
# shellcheck source=resolve-vendor-bin.sh
source "$LIST_DRIVES_LIB_DIR/resolve-vendor-bin.sh"

# See nfs-mount.sh's identical line for why this isn't a bare "anylinuxfs" PATH lookup.
ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-$(resolve_vendor_bin anylinuxfs || true)}"

# list_mountable_drives — prints one tab-separated "ident<TAB>label<TAB>size<TAB>fstype" line
# per compatible partition. Whole-disk/header rows never end in a diskNsM token so they're
# naturally excluded by the trailing-identifier match, same reasoning as the Swift parser.
#
# Bounded by run_with_progress (NTFSMAC_LIST_TIMEOUT, default 20s — this is a local metadata
# probe, never a first-run download, so it should always be fast): a wedged backend (degraded
# vmnet bridge, missing vendor binaries) used to hang this indefinitely with zero output and
# no way out. Returns 1 with its own clear message on timeout; callers must not also print
# their generic "no compatible drives found" message in that case — check the exit status,
# don't just look at whether any lines came back.
list_mountable_drives() {
  if [[ -z "$ANYLINUXFS_BIN" ]]; then
    echo "mount: FATAL — anylinuxfs binary not found at any known install path (try reinstalling: sudo bash install.sh, or 'ntfsmac diagnose')" >&2
    return 1
  fi

  local line tmp
  # macOS ships bash 3.2 (GPLv2-only cutoff) — its `[[ =~ ]]` parser trips over some literal
  # parens/brackets when the pattern is written inline, so the regex is assigned to a
  # variable first (a well-known 3.2 workaround) rather than embedded directly.
  local drive_re='^[[:space:]]*[0-9]+:[[:space:]]+([^[:space:]]+)[[:space:]]+(.+[^[:space:]])[[:space:]]+([*]?[0-9.]+[[:space:]]+[A-Za-z]+)[[:space:]]+([A-Za-z0-9]+)[[:space:]]*$'

  tmp="$(mktemp)"
  if ! run_with_progress "${NTFSMAC_LIST_TIMEOUT:-20}" 5 "mount: listing drives" "$tmp" "$ANYLINUXFS_BIN" list --microsoft; then
    rm -f "$tmp"
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ $drive_re ]]; then
      local fstype="${BASH_REMATCH[1]}" label="${BASH_REMATCH[2]}" size="${BASH_REMATCH[3]}" ident="${BASH_REMATCH[4]}"
      [[ "$ident" =~ ^disk[0-9]+s[0-9]+$ ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$ident" "$label" "$size" "$fstype"
    fi
  done < "$tmp"
  rm -f "$tmp"
}

# list_active_nfs_mounts — prints one tab-separated "mount_point<TAB>server_export" line per
# currently mounted ntfsmac NFS export, parsed from the host's own mount table (the same
# check docs/dev/TESTING.md itself uses: `mount | grep nfs`) rather than anylinuxfs's own text output,
# since this needs to work from unmount.sh with no other context.
#
# Also bounded (NTFSMAC_MOUNT_LIST_TIMEOUT, default 15s): plain `mount` is normally instant,
# but macOS's `mount` is documented to block while stat'ing a wedged/unresponsive NFS server —
# exactly the state a degraded vmnet bridge can leave behind, so this is a real, not
# theoretical, hang point too.
list_active_nfs_mounts() {
  local line tmp
  local mount_re='^([^[:space:]]+)[[:space:]]+on[[:space:]]+(/Volumes/[^[:space:](]+)[[:space:]]+\(nfs'

  tmp="$(mktemp)"
  if ! run_with_progress "${NTFSMAC_MOUNT_LIST_TIMEOUT:-15}" 5 "unmount: listing mounts" "$tmp" mount; then
    rm -f "$tmp"
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ $mount_re ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
    fi
  done < "$tmp"
  rm -f "$tmp"
}
