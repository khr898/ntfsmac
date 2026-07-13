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

# Resolved via resolve_vendor_bin (PATH, then $PREFIX/bin, then the homebrew-tap prefix) —
# never a bare "anylinuxfs" name. That relied on $PATH containing $PREFIX/bin, which the
# GUI's privileged helper (launchd daemon, minimal system PATH) never has, and which an
# interactive shell isn't guaranteed to have either — this was the actual cause of "anylinuxfs:
# command not found" mount failures even once the CLI itself was correctly staged and launched.
# Falls back to the bare name only if resolution genuinely finds nothing, matching prior
# (already-broken, not made worse) behavior instead of inventing a new failure mode.
ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-$(resolve_vendor_bin anylinuxfs || echo anylinuxfs)}"

# run_anylinuxfs_mount <device> <fs_driver> [mount_point] [read_only]
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
run_anylinuxfs_mount() {
  local device="$1" fs_driver="${2:-}" mount_point="${3:-}" read_only="${4:-}"
  local disk_ident="/dev/${device}"

  # Auto-eject: if macOS already auto-mounted this partition with its own (read-only) NTFS
  # driver, the raw block device is held and anylinuxfs/ntfs-3g can't probe it ("Insufficient
  # permissions?" is this exact symptom misreported by the probe layer). `diskutil unmount`
  # only detaches this one volume from Finder/macOS, leaving the physical disk and any sibling
  # partitions untouched — never `diskutil eject` (that would eject the whole disk). Errors
  # here are swallowed on purpose: "wasn't mounted by macOS to begin with" is the common case,
  # and a real failure still surfaces from the `anylinuxfs mount` call right below.
  diskutil unmount "$disk_ident" >/dev/null 2>&1 || true

  # First-run notice: anylinuxfs downloads+unpacks the Alpine rootfs into ~/.anylinuxfs/alpine
  # (confirmed path, matches anylinuxfs's own "Image base path:" log line) only when that
  # directory doesn't exist yet — every mount after this one reuses it and skips straight to
  # booting the VM. Surfaced here so the one-time download/init wall of text doesn't read like
  # a hang or a bug on the very first real mount.
  if [[ ! -d "$HOME/.anylinuxfs/alpine" ]]; then
    echo "mount: first run — downloading and initializing the Linux environment (one-time, ~1-2 min)..." >&2
  fi

  local -a args=(mount "$disk_ident")
  [[ -n "$mount_point" ]] && args+=("$mount_point")
  local nfs_opts="soft"
  [[ -n "$read_only" ]] && nfs_opts="soft,ro"
  args+=(--nfs-options "$nfs_opts")
  [[ -n "$fs_driver" ]] && args+=(-t "$fs_driver")

  # Bounded + heartbeated (NTFSMAC_MOUNT_TIMEOUT, default 240s — generous: first-run download +
  # VM boot legitimately takes 1-2 min per the notice above, this just bounds a truly wedged
  # guest instead of hanging forever with zero feedback). outfile "-": anylinuxfs's own live
  # "macOS: .../Linux: ..." progress lines stay visible in real time, never buffered.
  if ! run_with_progress "${NTFSMAC_MOUNT_TIMEOUT:-240}" 15 "mount" - "$ANYLINUXFS_BIN" "${args[@]}"; then
    return 1
  fi

  # Don't trust anylinuxfs's own exit code alone: a crashed guest VM (e.g. the guest init
  # script failing partway through) has been observed to still report success upstream while
  # no NFS mount actually exists. Independently verify before this function's caller ever
  # prints "mounted". NTFSMAC_SKIP_MOUNT_VERIFY exists only for tests that stub `anylinuxfs`
  # without a real NFS mount to check against.
  if [[ "${NTFSMAC_SKIP_MOUNT_VERIFY:-}" != "1" ]] && ! mount -t nfs 2>/dev/null | grep -q .; then
    echo "mount: anylinuxfs reported success but no NFS mount is present — treating as failed (try 'ntfsmac diagnose')" >&2
    return 1
  fi
}
