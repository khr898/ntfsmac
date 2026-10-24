#!/bin/bash
# cli/lib/list-drives.sh — shared drive enumeration for mount/unmount's no-argument
# interactive picker. Parses `anylinuxfs list` the same way the GUI's
# gui/Drives/DriveScanner.swift DriveListParser does (there is no --json flag on ListCmd,
# confirmed against vendor/.../anylinuxfs/src/cli.rs) — one shared regex shape, two
# implementations, kept in sync deliberately since bash and Swift can't share source.
#
# Scope: NTFS (ntfs/BitLocker) + ext2/3/4. exFAT is excluded — macOS reads/writes exFAT
# natively, so ntfsmac should not surface it. anylinuxfs list returns ALL Linux FS types
# (btrfs/xfs/zfs/LUKS/LVM/...), so we filter client-side to NTFSMAC_ALLOWED_FS_TYPES. Keep
# this array and DriveListParser's allowedFsTypes in sync (same comment in DriveScanner.swift).
set -u

# Filesystems ntfsmac mounts: NTFS + BitLocker + ext2/3/4 (kernel auto-detect, no --fs-driver).
# The real anylinuxfs TYPE column is NOT always a single blkid fstype token: for NTFS, blkid's
# fs_type can be empty, so darwin::augment_line falls back to the raw partition type name:
# "Microsoft Basic Data" on GPT and "Windows_NTFS" on MBR. The parser captures the whole
# TYPE+NAME blob and derives fstype from it — both prefixes are in the server's own
# WINDOWS_FS_TYPES set, so matching them client-side replicates --microsoft's reliability
# without a second anylinuxfs call. Note: "Microsoft Basic Data" is the GPT type
# for ntfs AND exfat; when blkid resolves exfat it surfaces as "exfat" and is dropped by the
# allow-set, but the rare GPT-fallback case can't distinguish the two (same limitation as the
# server's --microsoft filter). Keep this array and DriveListParser's allowedFsTypes in sync
# (same comment in DriveScanner.swift).
NTFSMAC_ALLOWED_FS_TYPES=(ntfs BitLocker ext ext2 ext3 ext4)

LIST_DRIVES_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=run-with-progress.sh
source "$LIST_DRIVES_LIB_DIR/run-with-progress.sh"
# shellcheck source=resolve-vendor-bin.sh
source "$LIST_DRIVES_LIB_DIR/resolve-vendor-bin.sh"

# See nfs-mount.sh's identical line for why this isn't a bare "anylinuxfs" PATH lookup.
ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-$(resolve_vendor_bin anylinuxfs || true)}"

load_runtime_alpine_contract_for_list() {
  local lock_lib=""
  if [[ -r "$LIST_DRIVES_LIB_DIR/lock.sh" ]]; then
    lock_lib="$LIST_DRIVES_LIB_DIR/lock.sh"
  elif [[ -r "$LIST_DRIVES_LIB_DIR/../../build/lib/lock.sh" ]]; then
    lock_lib="$LIST_DRIVES_LIB_DIR/../../build/lib/lock.sh"
  fi
  if [[ -z "$lock_lib" || ! -r "$LIST_DRIVES_LIB_DIR/runtime-alpine.sh" ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$lock_lib"
  # shellcheck source=runtime-alpine.sh
  source "$LIST_DRIVES_LIB_DIR/runtime-alpine.sh"
  runtime_alpine_load || return 1
}

# list_mountable_drives — prints one tab-separated "ident<TAB>label<TAB>size<TAB>fstype" line
# per compatible partition. Whole-disk/header rows never end in a diskNsM token so they're
# naturally excluded by the trailing-identifier match, same reasoning as the Swift parser.
#
# Bounded by run_with_progress (NTFSMAC_LIST_TIMEOUT, default 20s when runtime is initialized;
# adapts to NTFSMAC_MOUNT_TIMEOUT, default 240s, on first run or interrupted cache setup):
# a wedged backend (degraded vmnet bridge, missing vendor binaries) used to hang this
# indefinitely with zero output and no way out. Returns 1 with its own clear message on timeout;
# callers must not also print their generic "no compatible drives found" message in that case —
# check the exit status, don't just look at whether any lines came back.
list_mountable_drives() {
  if [[ -z "$ANYLINUXFS_BIN" ]]; then
    echo "mount: FATAL — anylinuxfs binary not found at any known install path (try reinstalling: sudo bash install.sh, or 'ntfsmac diagnose')" >&2
    return 1
  fi

  local line tmp
  local runtime_home

  local timeout="${NTFSMAC_LIST_TIMEOUT:-20}"
  local label="mount: listing drives"

  if load_runtime_alpine_contract_for_list; then
    runtime_home="$(runtime_alpine_resolve_home)"
    local cache_state
    cache_state="$(runtime_alpine_cache_state "$runtime_home" 2>/dev/null || echo "unknown")"
    if [[ "$cache_state" != "initialized" ]]; then
      runtime_alpine_prepare_cache "$runtime_home" || return 1
      timeout="${NTFSMAC_MOUNT_TIMEOUT:-240}"
      label="mount: setting up runtime & listing drives"
    fi
  else
    runtime_home="${NTFSMAC_RUNTIME_HOME_OVERRIDE-${HOME:-}}"
    if [[ -z "$runtime_home" ]]; then
      runtime_home="$(cd ~ 2>/dev/null && pwd)"
    fi
  fi

  # macOS ships bash 3.2 (GPLv2-only cutoff) — its `[[ =~ ]]` parser trips over some literal
  # parens/brackets when the pattern is written inline, so the regex is assigned to a
  # variable first (a well-known 3.2 workaround) rather than embedded directly.
  #
  # Captures the TYPE+NAME columns as ONE blob (group 1), then size (group 2) and ident
  # (group 3) from the right. Splitting TYPE from NAME positionally is fragile (both are
  # multi-word, space-padded to fixed widths by darwin::augment_line) and unnecessary: ident
  # is unambiguous from the right, and fstype is derived from the blob's prefix below. The
  # fstype is display-only — mount.sh validates --fs-driver itself, never trusting the picker.
  local drive_re='^[[:space:]]*[0-9]+:[[:space:]]+(.*)([*][0-9.]+[[:space:]]+[A-Za-z]+|[[:space:]]+[0-9.]+[[:space:]]+[A-Za-z]+)[[:space:]]+([A-Za-z0-9]+)[[:space:]]*$'

  tmp="$(mktemp)" || return 1
  trap 'rm -f -- "$tmp"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$tmp"; trap - TERM; kill -TERM $$' TERM
  if ! HOME="$runtime_home" run_with_progress "$timeout" 5 "$label" "$tmp" "$ANYLINUXFS_BIN" list; then
    rm -f "$tmp"
    trap - INT TERM
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ $drive_re ]]; then
      local blob="${BASH_REMATCH[1]}" size="${BASH_REMATCH[2]}" ident="${BASH_REMATCH[3]}"
      size="${size#"${size%%[![:space:]]*}"}"
      size="${size#\*}"
      [[ "$ident" =~ ^disk[0-9]+(s[0-9]+)?$ ]] || continue
      # Derive fstype + label from the TYPE+NAME blob. The GPT type name "Microsoft Basic
      # Data" covers ntfs AND exfat (both use that GPT type), while "Windows_NTFS" is emitted
      # for MBR NTFS partitions. exfat is out of scope — when
      # blkid resolves it, it surfaces as "exfat" and is dropped by NTFSMAC_ALLOWED_FS_TYPES;
      # the rare GPT-fallback case can't distinguish ntfs from exfat (same limitation as the
      # server's --microsoft filter). Match it as a prefix — same key the server filter uses,
      # so NTFS survives even when blkid's fs_type is empty. "BitLocker" is its own GPT type.
      # Everything else is a blkid single-token fstype (ext2/3/4, sometimes ntfs) + label.
      local fstype label
      if [[ "$blob" == "Microsoft Basic Data"* ]]; then
        fstype="ntfs"
        label="${blob#Microsoft Basic Data}"
      elif [[ "$blob" == "Windows_NTFS"* ]]; then
        fstype="ntfs"
        label="${blob#Windows_NTFS}"
      elif [[ "$blob" == "BitLocker"* ]]; then
        fstype="BitLocker"
        label="${blob#BitLocker}"
      elif [[ "$blob" == "Linux Filesystem"* ]]; then
        # GPT type name "Linux Filesystem" (GUID 0FC63DAF) is what darwin::augment_line falls
        # back to when blkid can't resolve the ext superblock (darwin.rs fs_type.unwrap_or(
        # part_type); the name is in LINUX_PART_TYPES, mod.rs). One GPT type covers ALL ext
        # versions — ext2, ext3, ext4 — Apple diskutil does not distinguish them, so the GPT
        # name can't either. Map to generic "ext" (kernel auto-detects at mount; no --fs-driver).
        # The single-token branch below would grab "Linux" and the allow-set would reject the
        # row — the ext equivalent of the NTFS "Microsoft Basic Data" bug above.
        fstype="ext"
        label="${blob#Linux Filesystem}"
      else
        fstype="${blob%%[[:space:]]*}"
        label="${blob#"$fstype"}"
      fi
      # ltrim and rtrim label (the blob's leading spaces are gone, but the stripped prefix leaves any)
      label="${label#"${label%%[![:space:]]*}"}"
      label="${label%"${label##*[![:space:]]}"}"
      # Client-side allow-set filter (header comment): anylinuxfs list returns every Linux FS
      # type; only NTFS-family + ext2/3/4 are in ntfsmac's mount scope. Skip the rest.
      local allowed=0 t
      for t in "${NTFSMAC_ALLOWED_FS_TYPES[@]}"; do [[ "$fstype" == "$t" ]] && allowed=1 && break; done
      [[ "$allowed" -eq 0 ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$ident" "$label" "$size" "$fstype"
    fi
  done < "$tmp"
  rm -f "$tmp"
  trap - INT TERM
}

# fs_type_for_device <device> — reuses list_mountable_drives' parse to return the fstype
# column (4th tab field) for a single device, or empty if the device isn't a mountable row.
# mount.sh calls this on the direct mount path (no --fs-driver given) to decide whether the
# drive is ext-family and needs --ignore-permissions (ext's Unix ownership would otherwise
# block the macOS user from writing; --ignore-permissions tells anylinuxfs to set all_squash,
# anonuid=0, anongid=0 server-side — vendor vmproxy/main.rs). NTFS returns "ntfs" and is left
# alone. One `anylinuxfs list` probe per direct mount — the picker path already has the fstype
# in hand and does NOT call this. Bounded + exit-tolerant: a backend timeout returns empty
# rather than propagating failure, so a wedged probe never blocks the mount itself (the mount
# call below will surface the real error); the cost is that an ext drive whose probe timed out
# won't auto-get --ignore-permissions, fixable by passing --ignore-permissions explicitly.
fs_type_for_device() {
  local device="$1" ident label size fstype rest line
  local tmp
  tmp="$(mktemp)" || return 1
  trap 'rm -f -- "$tmp"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$tmp"; trap - TERM; kill -TERM $$' TERM
  if list_mountable_drives > "$tmp" 2>/dev/null; then
    # Manual tab split (not `IFS=$'\t' read`): an empty label field makes `read` collapse
    # fields and lose fstype — see mount.sh's picker loop for the same fix + rationale.
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      rest="${line#*$'\t'}"; ident="${line%%$'\t'*}"
      label="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      size="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      fstype="${rest%%$'\t'*}"
      if [[ "$ident" == "$device" ]]; then
        rm -f "$tmp"
        trap - INT TERM
        printf '%s' "$fstype"
        return 0
      fi
    done < "$tmp"
  fi
  rm -f "$tmp"
  trap - INT TERM
  printf ''
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

  tmp="$(mktemp)" || return 1
  trap 'rm -f -- "$tmp"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$tmp"; trap - TERM; kill -TERM $$' TERM
  if ! run_with_progress "${NTFSMAC_MOUNT_LIST_TIMEOUT:-15}" 5 "unmount: listing mounts" "$tmp" mount; then
    rm -f "$tmp"
    trap - INT TERM
    return 1
  fi

  while IFS= read -r line; do
    if [[ "$line" =~ $mount_re ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
    fi
  done < "$tmp"
  rm -f "$tmp"
  trap - INT TERM
}
