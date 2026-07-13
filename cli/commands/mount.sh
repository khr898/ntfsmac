#!/bin/bash
# cli/commands/mount.sh — 2-mount + 2-fs-driver-flag (PLAN.md §6, L1, L3, L6).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=../lib/validate-device.sh
source "$SCRIPT_DIR/../lib/validate-device.sh"
# shellcheck source=../lib/nfs-mount.sh
source "$SCRIPT_DIR/../lib/nfs-mount.sh"
# shellcheck source=../lib/list-drives.sh
source "$SCRIPT_DIR/../lib/list-drives.sh"
# shellcheck source=../lib/interactive-select.sh
source "$SCRIPT_DIR/../lib/interactive-select.sh"

usage() {
  echo "usage: mount.sh [--fs-driver ntfs-3g|ntfs3] [--read-only] <device> [mount_point]" >&2
}

cmd_mount() {
  # Real, upstream-documented requirement (vendor/src/anylinuxfs/docs/important-notes.md
  # "Permissions"): anylinuxfs needs raw /dev/disk* access, which macOS refuses without root
  # (it drops back to the invoking user once the disk is open — this isn't a permanent
  # privilege escalation). Self-elevates via sudo (prompts for the password interactively)
  # instead of just erroring and making the user retype the whole command — same one-time
  # auth UX as install.sh's own sudo path for the GUI helper removal. `exec` replaces this
  # process outright, so mount.sh's own exit status becomes whatever the re-run (as root)
  # produces; sudo's own prompt/failure handling covers a wrong password or a Ctrl-C.
  # Transparent to the GUI: its privileged helper already runs as root, so this never fires.
  if [[ $EUID -ne 0 && "${NTFSMAC_SKIP_ROOT_CHECK:-}" != "1" ]]; then
    exec sudo "$0" "$@"
  fi

  local fs_driver="" device="" mount_point="" read_only=""
  local -a positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fs-driver)
        [[ $# -ge 2 ]] || { echo "mount: --fs-driver requires a value" >&2; return 1; }
        fs_driver="$2"
        shift 2
        ;;
      --fs-driver=*)
        fs_driver="${1#*=}"
        shift
        ;;
      --read-only)
        read_only="1"
        shift
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        echo "mount: unknown option: $1" >&2
        usage
        return 1
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  device="${positional[0]:-}"
  mount_point="${positional[1]:-}"

  # No device given: list compatible drives instead of just erroring on missing args.
  if [[ -z "$device" ]]; then
    local -a idents=() menu_lines=()
    local ident label size fstype
    local drives_tmp
    drives_tmp="$(mktemp)"
    # Real exit status, not process substitution: list_mountable_drives() returns 1 (with its
    # own clear "no response" message already printed) on a backend timeout — that must short-
    # circuit here, not fall through to the generic "no compatible drives found" below, which
    # would misreport a wedged backend as an empty drive list.
    if ! list_mountable_drives > "$drives_tmp"; then
      rm -f "$drives_tmp"
      return 1
    fi
    while IFS=$'\t' read -r ident label size fstype; do
      [[ -n "$ident" ]] || continue
      idents+=("$ident")
      menu_lines+=("/dev/$ident  $label  $size  $fstype")
    done < "$drives_tmp"
    rm -f "$drives_tmp"

    if [[ ${#idents[@]} -eq 0 ]]; then
      echo "mount: no compatible drives found (plug one in, or pass a device explicitly)" >&2
      return 1
    fi

    echo "mount: compatible drives:" >&2
    local i
    for i in "${!menu_lines[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${menu_lines[$i]}" >&2
    done

    local choice
    choice="$(prompt_choice "${#idents[@]}")" || { echo "mount: cancelled" >&2; return 1; }
    device="${idents[$((choice - 1))]}"
  fi

  if [[ -n "$fs_driver" && "$fs_driver" != "ntfs-3g" && "$fs_driver" != "ntfs3" ]]; then
    echo "mount: invalid --fs-driver '$fs_driver' (must be ntfs-3g or ntfs3)" >&2
    return 1
  fi
  # ntfs-3g is the implicit default (L1) — only pass -t to opt into ntfs3.
  [[ "$fs_driver" == "ntfs-3g" ]] && fs_driver=""

  if ! validate_device "$device"; then
    return 1
  fi

  if run_anylinuxfs_mount "$device" "$fs_driver" "$mount_point" "$read_only"; then
    echo "mount: $device mounted"
    return 0
  fi
  echo "mount: failed to mount $device" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd_mount "$@"
fi
