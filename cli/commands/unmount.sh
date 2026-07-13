#!/bin/bash
# cli/commands/unmount.sh — 2-unmount (PLAN.md §6).
#
# Safe-unmounts via `anylinuxfs unmount`, which tears down the host NFS mount and the
# microVM session itself (cmd_mount.rs run_unmount — already handles "no longer
# mounted"/"not mounted yet" as non-fatal warnings, not hangs). Never passes
# --wait-for-vm: synchronously waiting for VM process exit risks blocking on a
# wedged/dead VM — PLAN.md's Don't clause ("never block indefinitely on a dead mount").
# Calls Phase-1 pf teardown if that unit has landed (soft-optional — Phase 1 is
# deferrable per SHARED_TASK_NOTES.md; its absence here is not an error).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=../lib/resolve-vendor-bin.sh
source "$SCRIPT_DIR/../lib/resolve-vendor-bin.sh"
# See cli/lib/nfs-mount.sh's identical line for why this isn't a bare "anylinuxfs" PATH lookup.
ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-$(resolve_vendor_bin anylinuxfs || true)}"
PF_TEARDOWN="$SCRIPT_DIR/../lib/pf-teardown.sh"
# shellcheck source=../lib/list-drives.sh
source "$SCRIPT_DIR/../lib/list-drives.sh"
# shellcheck source=../lib/interactive-select.sh
source "$SCRIPT_DIR/../lib/interactive-select.sh"

usage() {
  echo "usage: unmount.sh <device_or_mount_point>" >&2
}

cmd_unmount() {
  if [[ -z "$ANYLINUXFS_BIN" ]]; then
    echo "unmount: FATAL — anylinuxfs binary not found at any known install path (try reinstalling: sudo bash install.sh, or 'ntfsmac diagnose')" >&2
    return 1
  fi

  local target="${1:-}"

  # No target given: list what's actually mounted instead of just erroring on missing args.
  if [[ -z "$target" ]]; then
    local -a mount_points=() menu_lines=()
    local mp server
    local mounts_tmp
    mounts_tmp="$(mktemp)"
    # Real exit status, not process substitution — see mount.sh's identical comment.
    # list_active_nfs_mounts() returns 1 (own clear message already printed) if `mount` itself
    # is wedged (a known real failure mode against an unresponsive NFS server).
    if ! list_active_nfs_mounts > "$mounts_tmp"; then
      rm -f "$mounts_tmp"
      return 1
    fi
    while IFS=$'\t' read -r mp server; do
      [[ -n "$mp" ]] || continue
      mount_points+=("$mp")
      menu_lines+=("$mp  ($server)")
    done < "$mounts_tmp"
    rm -f "$mounts_tmp"

    if [[ ${#mount_points[@]} -eq 0 ]]; then
      echo "unmount: nothing is currently mounted" >&2
      return 1
    fi

    echo "unmount: currently mounted:" >&2
    local i
    for i in "${!menu_lines[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${menu_lines[$i]}" >&2
    done

    local choice
    choice="$(prompt_choice "${#mount_points[@]}")" || { echo "unmount: cancelled" >&2; return 1; }
    target="${mount_points[$((choice - 1))]}"
  fi

  # Accept either a validated bare device (diskNsM) or an already-resolved mount
  # point/path — anylinuxfs's own UnmountCmd accepts either. Mirrors
  # helper/HelperProtocol.swift's isValidUnmountTarget(): a bare arg must match the
  # L6 device regex, a path must live under /Volumes/ and not traverse. Anything else
  # (e.g. a typo'd subcommand like "help") is rejected here rather than handed to
  # anylinuxfs, which would otherwise report a fake "unmounted" success for garbage input.
  local arg="$target"
  if [[ "$target" =~ ^disk[0-9]+s[0-9]+$ ]]; then
    arg="/dev/${target}"
  elif [[ "$target" == /Volumes/* && "$target" != *..* ]]; then
    arg="$target"
  else
    echo "unmount: invalid target '$target' (expected diskNsM or /Volumes/<name>)" >&2
    return 1
  fi

  # Bounded + heartbeated (NTFSMAC_UNMOUNT_TIMEOUT, default 60s): unmount should be fast, but a
  # wedged guest VM/NFS server must never leave the user staring at a silent blocked terminal.
  # outfile "-": anylinuxfs's own live output stays visible in real time, not buffered.
  if ! run_with_progress "${NTFSMAC_UNMOUNT_TIMEOUT:-60}" 10 "unmount" - "$ANYLINUXFS_BIN" unmount "$arg"; then
    echo "unmount: failed to unmount $target" >&2
    return 1
  fi

  if [[ -x "$PF_TEARDOWN" ]]; then
    "$PF_TEARDOWN" || echo "unmount: WARN — pf-teardown.sh failed (non-fatal)" >&2
  fi

  echo "unmount: $target unmounted"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd_unmount "$@"
fi
