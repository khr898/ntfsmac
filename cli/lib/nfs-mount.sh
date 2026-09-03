#!/bin/bash
# cli/lib/nfs-mount.sh — 2-mount (PLAN.md §6, L1-L3).
#
# Wraps the real `anylinuxfs mount` invocation. anylinuxfs already brings up the
# microVM, exports NFS from the guest, and performs the host-side NFS mount itself
# (vendor/src/anylinuxfs/anylinuxfs/src/fsutil.rs NfsOptions::default() already defaults
# to `soft` on macOS, for exactly L3's hot-unplug-panic reason — verified in source, not
# assumed). This is the single place that ever sets --nfs-options, so `hard` can never
# leak in from a caller, and it's explicit rather than relying silently on upstream's
# default in case that default ever changes upstream.
set -u

# GUI helper launches this via XPC/launchd with a minimal environment — HOME is not
# guaranteed to be set there (unlike an interactive shell). Fall back to the invoking
# user's real home dir via bash's own tilde expansion (uses the passwd db when HOME is
# unset), so `set -u` below doesn't crash the mount before it starts.
: "${HOME:=$(cd ~ && pwd)}"

NFS_MOUNT_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=run-with-progress.sh
source "$NFS_MOUNT_LIB_DIR/run-with-progress.sh"
# shellcheck source=resolve-vendor-bin.sh
source "$NFS_MOUNT_LIB_DIR/resolve-vendor-bin.sh"

load_runtime_alpine_contract() {
  local lock_lib=""
  if [[ -r "$NFS_MOUNT_LIB_DIR/lock.sh" ]]; then
    lock_lib="$NFS_MOUNT_LIB_DIR/lock.sh"
  elif [[ -r "$NFS_MOUNT_LIB_DIR/../../build/lib/lock.sh" ]]; then
    lock_lib="$NFS_MOUNT_LIB_DIR/../../build/lib/lock.sh"
  fi
  if [[ -z "$lock_lib" || ! -r "$NFS_MOUNT_LIB_DIR/runtime-alpine.sh" ]]; then
    local missing=()
    [[ -z "$lock_lib" ]] && missing+=("lock.sh")
    [[ ! -r "$NFS_MOUNT_LIB_DIR/runtime-alpine.sh" ]] && missing+=("runtime-alpine.sh")
    echo "mount: FATAL — pinned Alpine runtime metadata is missing (${missing[*]}); reinstall ntfsmac" >&2
    return 1
  fi
  # Runtime and source-tree layouts resolve lock.sh from different locations.
  # shellcheck disable=SC1090
  source "$lock_lib"
  # shellcheck source=runtime-alpine.sh
  source "$NFS_MOUNT_LIB_DIR/runtime-alpine.sh"
  runtime_alpine_load
}

# Resolved via resolve_vendor_bin (PATH, then $PREFIX/bin, then the homebrew-tap prefix) —
# never a bare "anylinuxfs" name. That relied on $PATH containing $PREFIX/bin, which the
# GUI's privileged helper (launchd daemon, minimal system PATH) never has, and which an
# interactive shell isn't guaranteed to have either — this was the actual cause of "anylinuxfs:
# command not found" mount failures even once the CLI itself was correctly staged and launched.
# Fails immediately with a clear diagnostic instead of falling back to a bare name that
# produces a cryptic "command not found" from run-with-progress.sh at runtime.
ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-$(resolve_vendor_bin anylinuxfs || true)}"

# run_anylinuxfs_mount <device> <fs_driver> [mount_point] [read_only] [ignore_perms] [key_file]
# <device> must already be validate_device()-checked by the caller — this function does
# not re-validate. Only this function ever prepends "/dev/" (L6: raw /dev/-prefixed
# input is rejected upstream; this is our own controlled construction, not user input).
#
# <read_only> (any non-empty value): appends "ro" to --nfs-options. This is a real,
# standard NFS *client-side* mount option (confirmed against
# vendor/.../anylinuxfs/src/fsutil.rs's NfsOptions — --nfs-options values extend, not
# replace, the default map, and "ro" is a normal `mount_nfs(8)` option, not
# anylinuxfs-specific) — the macOS NFS client will refuse writes locally regardless of
# what ntfs-3g's own dirty-journal check would otherwise have allowed server-side. There
# is deliberately no anylinuxfs/ntfs-3g flag to *request* read-only (confirmed: no `force`
# or mode field exists on `MountCmd` in cli.rs) — this is the only real lever available.
#
# <ignore_perms> (any non-empty value): passes --ignore-permissions to anylinuxfs. ext is a
# real Unix filesystem with its own ownership bits, so unlike NTFS (which anylinuxfs remaps
# to the host user via uid=/gid=, cmd_mount.rs WINDOWS_LABELS.fs_types) ext can't be remapped
# at mount time — without this flag, files belong to whatever uid/gid the disk stored and the
# macOS user can't open lost+found or write. --ignore-permissions sets all_squash,anonuid=0,
# anongid=0 on the NFS export (vendor vmproxy/main.rs:1327), mapping all client access to
# server root. NTFS never gets this — "do not change the NTFS part": ntfs-3g already owns
# the uid/gid remap and adding all_squash there would change NTFS behavior.
run_anylinuxfs_mount() {
  if [[ -z "$ANYLINUXFS_BIN" ]]; then
    echo "mount: FATAL — anylinuxfs binary not found at any known install path (try reinstalling: sudo bash install.sh, or 'ntfsmac diagnose')" >&2
    return 1
  fi

  local device="$1" fs_driver="${2:-}" mount_point="${3:-}" read_only="${4:-}" ignore_perms="${5:-}" key_file="${6:-}"
  local disk_ident="/dev/${device}"

  # Validate the exact runtime contract before changing the host's current mount state.
  # Upgrades use a versioned directory; legacy, mismatched, and interrupted caches are preserved
  # side-by-side so a mount never silently destroys rollback data.
  load_runtime_alpine_contract || return 1
  runtime_alpine_prepare_cache "$HOME" || return 1

  # Auto-eject: if macOS already auto-mounted this partition with its own (read-only) NTFS
  # driver, the raw block device is held and anylinuxfs/ntfs-3g can't probe it ("Insufficient
  # permissions?" is this exact symptom misreported by the probe layer). `diskutil unmount`
  # only detaches this one volume from Finder/macOS, leaving the physical disk and any sibling
  # partitions untouched — never `diskutil eject` (that would eject the whole disk). Errors
  # here are swallowed on purpose: "wasn't mounted by macOS to begin with" is the common case,
  # and a real failure still surfaces from the `anylinuxfs mount` call right below.
  diskutil unmount "$disk_ident" >/dev/null 2>&1 || true

  # ntfsmac's transport contract is vmnet-only. Pass the choice explicitly so a stale or
  # user-edited anylinuxfs config cannot silently switch this product to gvproxy's loopback
  # frontend while the UI/docs continue claiming a dedicated private /30 path.
  local -a args=(mount "$disk_ident" --net-helper vmnet)
  [[ -n "$mount_point" ]] && args+=("$mount_point")
  local nfs_opts="soft"
  [[ -n "$read_only" ]] && nfs_opts="soft,ro"
  # Throughput tuning — default-on (PLAN.md L8 owner-override, see README "Performance"):
  # rsize/wsize=1MB (NFSv3/TCP max transfer unit; kernel auto-negotiates down to the server's
  # cap, so this never fails or loses data — it just widens the pipe) + readahead=16 (macOS
  # mount_nfs read-ahead window; pure prefetch). Near-zero risk, no integrity path. rsize ==
  # wsize on purpose: macOS mount_nfs warns on a high wsize/rsize ratio ("unexpected readahead
  # RPCs"). This is the single place --nfs-options is set (comment block above), so the GUI
  # path (helper → ntfsmac mount → mount.sh → here) inherits tuning with no GUI/XPC change.
  nfs_opts="$nfs_opts,rsize=1048576,wsize=1048576,readahead=16"
  args+=(--nfs-options "$nfs_opts")
  [[ -n "$fs_driver" ]] && args+=(-t "$fs_driver")
  [[ -n "$ignore_perms" ]] && args+=(--ignore-permissions)
  [[ -n "$key_file" ]] && args+=(--key-file "$key_file")

  # Bounded + heartbeated (NTFSMAC_MOUNT_TIMEOUT, default 240s — generous: first-run download +
  # VM boot legitimately takes 1-2 min per the notice above, this just bounds a truly wedged
  # guest instead of hanging forever with zero feedback). outfile "-": anylinuxfs's own live
  # "macOS: .../Linux: ..." progress lines stay visible in real time, never buffered.
  # Start the bounded backend as a background job so the transaction layer can observe the new
  # vmnet /30 and repair an exact VPN-captured guest route before anylinuxfs performs its own
  # NFS readiness check. The job still runs through the same watchdog and preserves live output.
  local security_prepare_available="0" mount_job mount_result="0"
  if declare -F security_begin_prepared_mount >/dev/null 2>&1 \
    && declare -F security_prepare_mount_transport >/dev/null 2>&1; then
    security_begin_prepared_mount "$device" || true
    security_prepare_available="1"
  fi
  run_with_progress "${NTFSMAC_MOUNT_TIMEOUT:-240}" 15 "mount" - \
    "$ANYLINUXFS_BIN" "${args[@]}" &
  mount_job=$!
  if [[ "$security_prepare_available" == "1" ]]; then
    security_prepare_mount_transport "$device" "$mount_job" || true
  fi
  wait "$mount_job" || mount_result=$?
  if [[ "$mount_result" != "0" ]]; then
    if [[ "$security_prepare_available" == "1" ]] \
      && declare -F security_abort_prepared_mount >/dev/null 2>&1; then
      security_abort_prepared_mount "$device" || true
    fi
    return 1
  fi

  # Don't trust anylinuxfs's own exit code alone: a crashed guest VM (e.g. the guest init
  # script failing partway through) has been observed to still report success upstream while
  # no NFS mount actually exists. Independently verify before this function's caller ever
  # prints "mounted". NTFSMAC_SKIP_MOUNT_VERIFY exists only for tests that stub `anylinuxfs`
  # without a real NFS mount to check against.
  if [[ "${NTFSMAC_SKIP_MOUNT_VERIFY:-}" != "1" ]] && ! mount -t nfs 2>/dev/null | grep -q .; then
    if [[ "$security_prepare_available" == "1" ]] \
      && declare -F security_abort_prepared_mount >/dev/null 2>&1; then
      security_abort_prepared_mount "$device" || true
    fi
    echo "mount: anylinuxfs reported success but no NFS mount is present — treating as failed (try 'ntfsmac diagnose')" >&2
    return 1
  fi
}
