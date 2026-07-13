#!/bin/bash
# cli/commands/uninstall.sh — full CLI + vendored-dependency removal, no leftovers.
#
# Self-contained: only needs $PREFIX (matches every other command's convention), never the
# original repo tree — works whether or not the clone that installed it still exists.
# Removes exactly what install.sh created (PREFIX tree) plus real runtime state anylinuxfs
# itself creates outside PREFIX (confirmed by reading vendor/.../anylinuxfs/src/main.rs, not
# guessed): ~/.anylinuxfs (rootfs cache + config.toml) and ~/Library/Logs/anylinuxfs*.log —
# glob-scoped to that exact prefix, never the whole Library/Logs dir (shared with every other
# app on the system). Run with sudo to also remove the GUI's privileged helper (root-owned
# files under /Library/{LaunchDaemons,PrivilegedHelperTools} — a non-root process cannot
# touch them, and per L5 this script never re-authenticates itself to gain that access; the
# GUI's own Preferences "Uninstall" control uses the already-authorized XPC helper instead).
set -u

PREFIX="${NTFSMAC_PREFIX:-/usr/local/ntfsmac}"
# Must match install.sh's own default/override so a real install's symlink actually gets found.
PATH_SYMLINK="${NTFSMAC_PATH_SYMLINK:-/usr/local/bin/ntfsmac}"

usage() {
  echo "usage: uninstall.sh [--force] [--keep-cache]" >&2
  echo "  --force       skip the active-NFS-mount safety check" >&2
  echo "  --keep-cache  keep ~/.anylinuxfs (downloaded rootfs images, config.toml)" >&2
}

refuse_if_mounted() {
  local force="${1:-}"
  [[ -n "$force" ]] && return 0
  if mount -t nfs 2>/dev/null | grep -q .; then
    echo "uninstall: an NFS mount is currently active — unmount it first (ntfsmac unmount <device>) or pass --force" >&2
    return 1
  fi
  return 0
}

teardown_pf_if_present() {
  local teardown_script="$PREFIX/libexec/ntfsmac/lib/pf-teardown.sh"
  # Silent-failure-hunter finding (2026-07-13, LOW): a real (non-fatal-by-design) teardown
  # failure was fully swallowed here with no message, unlike unmount.sh's identical call —
  # matching that WARN for parity.
  if [[ -x "$teardown_script" ]]; then
    "$teardown_script" || echo "uninstall: WARN — pf-teardown.sh failed (non-fatal)" >&2
  fi
  return 0
}

remove_path_symlink() {
  # Only remove it if it still points where install.sh would have pointed it — never blow
  # away an unrelated file a user happens to have at that path.
  [[ -L "$PATH_SYMLINK" ]] || return 0
  local resolved
  resolved="$(readlink "$PATH_SYMLINK")"
  if [[ "$resolved" == "$PREFIX/bin/ntfsmac" ]]; then
    rm -f "$PATH_SYMLINK"
    echo "uninstall: removed $PATH_SYMLINK"
  fi
}

remove_prefix() {
  # Safety guard: never operate on an empty/root-ish PREFIX — a blank NTFSMAC_PREFIX or one
  # pointed at a shared system directory would turn `rm -rf "$PREFIX"` catastrophic.
  case "$PREFIX" in
    "" | "/" | "/usr" | "/usr/local" | "/opt" | "/opt/homebrew")
      echo "uninstall: refusing to remove suspicious prefix '$PREFIX'" >&2
      return 1
      ;;
  esac
  if [[ -d "$PREFIX" ]]; then
    rm -rf "$PREFIX"
    echo "uninstall: removed $PREFIX"
  fi
  return 0
}

# resolve_invoker_home — after self-elevating via sudo, plain $HOME may be root's
# (/var/root), not the real invoking user's — sudo's HOME-reset behavior depends on the
# system's sudoers policy, so this doesn't rely on it either way. Resolves the real user's
# home from $SUDO_USER via dscl (macOS's actual account database, no eval/shell-injection
# risk) when running as root with sudo; falls back to plain $HOME otherwise (matches
# every test in this file, none of which set SUDO_USER).
resolve_invoker_home() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    local resolved
    resolved="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
    if [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  printf '%s' "${HOME:-}"
}

remove_rootfs_cache() {
  local keep_cache="${1:-}"
  [[ -n "$keep_cache" ]] && return 0
  local home
  home="$(resolve_invoker_home)"
  [[ -n "$home" && -d "$home/.anylinuxfs" ]] || return 0
  rm -rf "$home/.anylinuxfs"
  echo "uninstall: removed $home/.anylinuxfs (rootfs cache + config.toml)"
}

remove_logs() {
  local home
  home="$(resolve_invoker_home)"
  [[ -n "$home" ]] || return 0
  local log_dir="$home/Library/Logs"
  [[ -d "$log_dir" ]] || return 0
  rm -f "$log_dir"/anylinuxfs-*.log "$log_dir"/anylinuxfs_kernel-*.log "$log_dir"/anylinuxfs_nethelper-*.log 2>/dev/null
  return 0
}

remove_privileged_helper_if_root() {
  local plist="${NTFSMAC_HELPER_PLIST:-/Library/LaunchDaemons/com.khr898.ntfsmac.helper.plist}"
  local bin="${NTFSMAC_HELPER_BIN:-/Library/PrivilegedHelperTools/com.khr898.ntfsmac.helper}"

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "uninstall: not running as root — the GUI's privileged helper (if installed) was left in place."
    echo "uninstall: re-run with 'sudo' to remove it too, or use the GUI's own Uninstall control in Preferences."
    return 0
  fi
  if launchctl print system/com.khr898.ntfsmac.helper >/dev/null 2>&1; then
    launchctl bootout system/com.khr898.ntfsmac.helper >/dev/null 2>&1
  fi
  rm -f "$plist"
  rm -f "$bin"
  echo "uninstall: removed privileged helper (ran as root)"
}

cmd_uninstall() {
  # Self-elevate so a single `ntfsmac uninstall` actually finishes the whole job — the GUI's
  # privileged helper (/Library/LaunchDaemons, /Library/PrivilegedHelperTools) can only be
  # removed as root, and previously this just printed "re-run with sudo" and left it in
  # place. Same pattern as mount.sh's self-elevation; resolve_invoker_home() above is what
  # keeps ~/.anylinuxfs/logs removal pointed at the real user's home once this re-execs as
  # root, not root's own.
  if [[ $EUID -ne 0 && "${NTFSMAC_SKIP_ROOT_CHECK:-}" != "1" ]]; then
    exec sudo "$0" "$@"
  fi

  local force="" keep_cache=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force="1"
        shift
        ;;
      --keep-cache)
        keep_cache="1"
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        echo "uninstall: unknown option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  refuse_if_mounted "$force" || return 1
  teardown_pf_if_present
  remove_path_symlink
  remove_prefix || return 1
  remove_rootfs_cache "$keep_cache"
  remove_logs
  remove_privileged_helper_if_root

  echo "uninstall: done"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd_uninstall "$@"
fi
