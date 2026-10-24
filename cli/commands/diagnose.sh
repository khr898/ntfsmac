#!/bin/bash
# cli/commands/diagnose.sh — 2-diagnose (PLAN.md §6).
#
# Read-only health report: product/system metadata, expected and detected runtime versions,
# helper/vendor presence, Alpine guest packages, bridge state, kernel pin, quarantine xattrs, a
# tunnel-default-route boolean, and NFS mount count. No privileged op ever runs here (diagnose
# never mounts/unmounts/touches pf/route).
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." &>/dev/null && pwd)"
VERSION_LIB="$SCRIPT_DIR/../lib/version.sh"
if [[ -r "$VERSION_LIB" ]]; then
  # Runtime and installed layouts resolve this file from different roots.
  # shellcheck disable=SC1090
  source "$VERSION_LIB"
  ntfsmac_load_product_version "$REPO_ROOT"
else
  NTFSMAC_VERSION="unknown"
  NTFSMAC_BUILD_VERSION="unknown"
  NTFSMAC_DIAGNOSTIC_SCHEMA_VERSION="5"
fi
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
  MISSING_COMPONENTS=""
  QUARANTINED_COMPONENTS=""
  local name bin
  for name in anylinuxfs gvproxy vmnet-helper vmproxy; do
    bin="$(resolve_bin "$name")"
    if [[ -z "$bin" || ! -x "$bin" ]]; then
      MISSING_BINS=$((MISSING_BINS + 1))
      MISSING_COMPONENTS="${MISSING_COMPONENTS}${MISSING_COMPONENTS:+ }$name"
      continue
    fi
    if xattr -p com.apple.quarantine "$bin" >/dev/null 2>&1; then
      QUARANTINED_BINS=$((QUARANTINED_BINS + 1))
      QUARANTINED_COMPONENTS="${QUARANTINED_COMPONENTS}${QUARANTINED_COMPONENTS:+ }$name"
    fi
  done
}

# Version strings enter JSON and the GUI, so accept only the conservative token alphabet used by
# the pinned projects/package managers. Unexpected output becomes "unknown" rather than being
# echoed verbatim or allowed to break JSON. Paths and free-form command output are never emitted.
safe_version_token() {
  local value="$1"
  case "$value" in
    ''|*[!A-Za-z0-9._+~:-]*) printf 'unknown\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

lock_value_or_unknown() {
  local key="$1" value
  value="$(lock_get "$key" 2>/dev/null)" || { printf 'unknown\n'; return; }
  safe_version_token "$value"
}

apk_package_version() {
  local database="$1" package="$2" value
  if [[ ! -f "$database" ]]; then
    printf 'unknown\n'
    return
  fi
  value="$(awk -v wanted="$package" '
    BEGIN { RS=""; FS="\n" }
    {
      name=""; version=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^P:/) name=substr($i, 3)
        else if ($i ~ /^V:/) version=substr($i, 3)
      }
      if (name == wanted) { print version; exit }
    }
  ' "$database" 2>/dev/null)"
  if [[ -z "$value" ]]; then
    printf 'not_installed\n'
  else
    safe_version_token "$value"
  fi
}

inspect_alpine_installation() {
  local runtime_home="$1" state="$2" rootfs="" base release_file apk_database value
  ALPINE_INSTALLED_CACHE="none"
  ALPINE_INSTALLED_VERSION="not_installed"
  NTFS_3G_VERSION="not_installed"
  NFS_UTILS_VERSION="not_installed"

  base="$(runtime_alpine_cache_path "$runtime_home")"
  case "$state" in
    initialized)
      ALPINE_INSTALLED_CACHE="pinned"
      rootfs="$base/rootfs"
      ;;
    migration_available)
      ALPINE_INSTALLED_CACHE="legacy"
      rootfs="$runtime_home/.anylinuxfs/alpine/rootfs"
      ;;
    mismatch|incomplete)
      ALPINE_INSTALLED_CACHE="pinned_unusable"
      rootfs="$base/rootfs"
      ;;
    invalid)
      ALPINE_INSTALLED_CACHE="invalid"
      return
      ;;
    not_initialized)
      return
      ;;
    *)
      ALPINE_INSTALLED_CACHE="unknown"
      ALPINE_INSTALLED_VERSION="unknown"
      NTFS_3G_VERSION="unknown"
      NFS_UTILS_VERSION="unknown"
      return
      ;;
  esac

  # Refuse symlinked cache roots: diagnostics are read-only and must not follow an attacker-chosen
  # path merely to collect a version. Missing/incomplete files remain explicit fixed tokens.
  if [[ -L "$runtime_home/.anylinuxfs" || -L "$runtime_home/.anylinuxfs/alpine" ||
        -L "$base" || -L "$rootfs" || ! -d "$rootfs" ]]; then
    ALPINE_INSTALLED_VERSION="unknown"
    NTFS_3G_VERSION="unknown"
    NFS_UTILS_VERSION="unknown"
    return
  fi

  release_file="$rootfs/etc/alpine-release"
  if [[ -f "$release_file" && ! -L "$release_file" ]]; then
    value="$(sed -n '1p' "$release_file" 2>/dev/null)"
    ALPINE_INSTALLED_VERSION="$(safe_version_token "$value")"
  else
    ALPINE_INSTALLED_VERSION="unknown"
  fi

  apk_database="$rootfs/lib/apk/db/installed"
  if [[ -L "$apk_database" ]]; then
    NTFS_3G_VERSION="unknown"
    NFS_UTILS_VERSION="unknown"
  else
    NTFS_3G_VERSION="$(apk_package_version "$apk_database" ntfs-3g)"
    NFS_UTILS_VERSION="$(apk_package_version "$apk_database" nfs-utils)"
  fi
}

component_version() {
  local name="$1" bin output value
  bin="$(resolve_bin "$name")"
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    printf 'not_installed\n'
    return
  fi
  if xattr -p com.apple.quarantine "$bin" >/dev/null 2>&1; then
    printf 'quarantined\n'
    return
  fi

  output="$("$bin" --version 2>&1)" || true
  case "$name" in
    anylinuxfs) value="$(printf '%s\n' "$output" | awk '$1 == "anylinuxfs" { print $2; exit }')" ;;
    gvproxy) value="$(printf '%s\n' "$output" | awk '$1 == "gvproxy" && $2 == "version" { print $3; exit }')" ;;
    vmnet-helper) value="$(printf '%s\n' "$output" | awk -F': *' '$1 == "version" { print $2; exit }')" ;;
    *) value="" ;;
  esac
  safe_version_token "$value"
}

vmnet_helper_commit() {
  local bin output value
  bin="$(resolve_bin vmnet-helper)"
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    printf 'not_installed\n'
    return
  fi
  if xattr -p com.apple.quarantine "$bin" >/dev/null 2>&1; then
    printf 'quarantined\n'
    return
  fi
  output="$("$bin" --version 2>&1)" || true
  value="$(printf '%s\n' "$output" | awk -F': *' '$1 == "commit" { print $2; exit }')"
  if [[ ${#value} -eq 40 && "$value" != *[!0-9a-f]* ]]; then
    printf '%s\n' "$value"
  else
    printf 'unknown\n'
  fi
}

version_status() {
  local actual="$1" expected="$2"
  case "$actual" in
    not_installed|quarantined) printf '%s\n' "$actual" ;;
    unknown) printf 'unknown\n' ;;
    *)
      if [[ "$expected" == "unknown" ]]; then
        printf 'unknown\n'
      elif [[ "$actual" == "$expected" ]]; then
        printf 'match\n'
      else
        printf 'mismatch\n'
      fi
      ;;
  esac
}

check_kernel_pin() {
  local lock_sh=""
  if [[ -r "$SCRIPT_DIR/../lib/lock.sh" ]]; then
    lock_sh="$SCRIPT_DIR/../lib/lock.sh"
  elif [[ -r "$REPO_ROOT/build/lib/lock.sh" ]]; then
    lock_sh="$REPO_ROOT/build/lib/lock.sh"
  elif [[ -r "$PREFIX/libexec/ntfsmac/lib/lock.sh" ]]; then
    lock_sh="$PREFIX/libexec/ntfsmac/lib/lock.sh"
  elif [[ -r "$HOMEBREW_OPT_PREFIX/libexec/ntfsmac/lib/lock.sh" ]]; then
    lock_sh="$HOMEBREW_OPT_PREFIX/libexec/ntfsmac/lib/lock.sh"
  else
    echo "unknown"
    return
  fi

  # Runtime and installed layouts resolve this file from different roots.
  # shellcheck disable=SC1090
  source "$lock_sh"
  local expected actual
  expected="$(lock_get LIBKRUNFW_MODULES_SHA256 2>/dev/null)" || { echo "unknown"; return; }

  local squashfs_file="" candidate
  local candidates=(
    "${NTFSMAC_VENDOR_KERNEL_DIR:-}/modules.squashfs"
    "$REPO_ROOT/vendor/kernel/modules.squashfs"
    "$PREFIX/lib/modules.squashfs"
    "$HOMEBREW_OPT_PREFIX/lib/modules.squashfs"
    "$SCRIPT_DIR/../../../lib/modules.squashfs"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      squashfs_file="$candidate"
      break
    fi
  done

  [[ -n "$squashfs_file" ]] || { echo "missing"; return; }
  actual="$(shasum -a 256 "$squashfs_file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] && echo "match" || echo "mismatch"
}

# Loads the same sources.lock-derived runtime contract used by the build and mount path, then
# reports only fixed tokens plus the approved tag/digest. No home path or cache content is emitted.
check_alpine_runtime() {
  local runtime_lib="$SCRIPT_DIR/../lib/runtime-alpine.sh"
  local lock_lib
  if [[ -r "$SCRIPT_DIR/../lib/lock.sh" ]]; then
    lock_lib="$SCRIPT_DIR/../lib/lock.sh"
  else
    lock_lib="$REPO_ROOT/build/lib/lock.sh"
  fi

  ALPINE_RUNTIME_TAG="unknown"
  ALPINE_RUNTIME_DIGEST="unknown"
  ALPINE_RUNTIME_STATE="unknown"
  ALPINE_INSTALLED_CACHE="unknown"
  ALPINE_INSTALLED_VERSION="unknown"
  NTFS_3G_VERSION="unknown"
  NFS_UTILS_VERSION="unknown"
  ANYLINUXFS_EXPECTED_VERSION="unknown"
  ANYLINUXFS_SOURCE_COMMIT="unknown"
  VMPROXY_SOURCE_VERSION="unknown"
  LIBKRUN_VERSION="unknown"
  LIBKRUNFW_VERSION="unknown"
  GVPROXY_EXPECTED_VERSION="unknown"
  GVPROXY_SOURCE_COMMIT="unknown"
  VMNET_HELPER_EXPECTED_VERSION="unknown"
  if [[ ! -r "$lock_lib" || ! -r "$runtime_lib" ]]; then
    return 1
  fi

  # Installed and source-tree layouts resolve the same libraries from different roots.
  # shellcheck disable=SC1090
  source "$lock_lib"
  # shellcheck disable=SC1090
  source "$runtime_lib"
  runtime_alpine_load || return 1

  ANYLINUXFS_EXPECTED_VERSION="$(lock_value_or_unknown ANYLINUXFS_VERSION)"
  ANYLINUXFS_SOURCE_COMMIT="$(lock_value_or_unknown ANYLINUXFS_COMMIT)"
  VMPROXY_SOURCE_VERSION="$(lock_value_or_unknown VMPROXY_VERSION)"
  LIBKRUN_VERSION="$(lock_value_or_unknown LIBKRUN_VERSION)"
  LIBKRUNFW_VERSION="$(lock_value_or_unknown LIBKRUNFW_VERSION)"
  GVPROXY_EXPECTED_VERSION="$(lock_value_or_unknown GVPROXY_VERSION)"
  GVPROXY_SOURCE_COMMIT="$(lock_value_or_unknown GVPROXY_COMMIT)"
  VMNET_HELPER_EXPECTED_VERSION="$(lock_value_or_unknown VMNET_HELPER_VERSION)"

  local runtime_home
  runtime_home="${NTFSMAC_RUNTIME_HOME_OVERRIDE-${HOME:-}}"
  if [[ -z "$runtime_home" ]]; then
    runtime_home="$(cd ~ 2>/dev/null && pwd)"
  fi
  [[ -n "$runtime_home" ]] || return 1

  ALPINE_RUNTIME_STATE="$(runtime_alpine_cache_state "$runtime_home")" || {
    ALPINE_RUNTIME_STATE="unknown"
    return 1
  }
  inspect_alpine_installation "$runtime_home" "$ALPINE_RUNTIME_STATE"
  return 0
}

check_bridge_up() {
  if [[ -n "${NTFSMAC_BRIDGE_OVERRIDE-}" ]]; then
    case "$NTFSMAC_BRIDGE_OVERRIDE" in
      up|down) printf '%s\n' "$NTFSMAC_BRIDGE_OVERRIDE" ;;
      *) printf 'unknown\n' ;;
    esac
    return
  fi
  # A gvproxy/anylinuxfs process is not a vmnet bridge. The previous broad pgrep made a
  # loopback-backed mount look like the documented private transport, creating the exact false
  # green found by the live audit. Require vmnet-helper or an interface in its configured pool.
  if pgrep -x 'vmnet-helper' >/dev/null 2>&1 || \
     /sbin/ifconfig | awk '
       /^[^[:space:]]/ { interface=$1; sub(/:$/, "", interface) }
       interface ~ /^bridge/ && $1 == "inet" && $2 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ { found=1 }
       END { exit(found ? 0 : 1) }
     '; then
    echo "up"
  else
    echo "down"
  fi
}

# Fixed privacy-safe tokens only: no PID, interface, hostname, address, route, or provider name is
# emitted. `mixed` is fail-closed because the active mount cannot be attributed confidently.
check_network_helper() {
  if [[ -n "${NTFSMAC_NETWORK_HELPER_OVERRIDE-}" ]]; then
    case "$NTFSMAC_NETWORK_HELPER_OVERRIDE" in
      vmnet|gvproxy|mixed|none|unknown) printf '%s\n' "$NTFSMAC_NETWORK_HELPER_OVERRIDE" ;;
      *) printf 'unknown\n' ;;
    esac
    return
  fi

  local vmnet_running=0 gvproxy_running=0
  pgrep -x 'vmnet-helper' >/dev/null 2>&1 && vmnet_running=1
  pgrep -x 'gvproxy' >/dev/null 2>&1 && gvproxy_running=1
  if [[ "$vmnet_running" -eq 1 && "$gvproxy_running" -eq 1 ]]; then
    printf 'mixed\n'
  elif [[ "$vmnet_running" -eq 1 ]]; then
    printf 'vmnet\n'
  elif [[ "$gvproxy_running" -eq 1 ]]; then
    printf 'gvproxy\n'
  else
    printf 'none\n'
  fi
}

check_nfs_transport_contract() {
  local helper="$1" bridge="$2" mounts="$3" nfs_parameters="$4"
  local line source host mount_point resolved route_interface listener_count identified=0

  # Classify only ntfsmac's stable synthetic hostnames. An unrelated NAS mount must not degrade
  # ntfsmac health merely because it also uses NFS.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    source="${line%% on *}"
    [[ "$source" != "$line" ]] || continue
    host="${source%%:*}"
    if [[ "$host" =~ ^disk[0-9]+(s[0-9]+)?(-[0-9]+)?\.local$ ]]; then
      :
    elif [[ "$helper" == "vmnet" && "$host" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+$ ]]; then
      :
    elif [[ "$helper" == "gvproxy" && "$host" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      :
    else
      continue
    fi
    identified=$((identified + 1))

    if [[ "$helper" == "gvproxy" ]]; then
      printf 'loopback_proxy\n'
      return
    elif [[ "$helper" == "mixed" ]]; then
      printf 'ambiguous\n'
      return
    elif [[ "$helper" != "vmnet" || "$bridge" != "up" ]]; then
      printf 'unverified\n'
      return
    fi

    mount_point="${line#* on }"
    mount_point="${mount_point%% (nfs*}"
    if ! nfs_mount_is_soft "$source" "$mount_point" "$nfs_parameters"; then
      printf 'unverified\n'
      return
    fi

    resolved="${NTFSMAC_RESOLVED_IP_OVERRIDE-}"
    if [[ -z "$resolved" ]]; then
      if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved="$host"
      else
        resolved="$(/usr/bin/dscacheutil -q host -a name "$host" 2>/dev/null \
          | awk '/^ip_address: / { print $2 }')"
      fi
    fi
    if printf '%s\n' "$resolved" | grep -E '^127\.' >/dev/null 2>&1; then
      printf 'loopback_proxy\n'
      return
    fi
    resolved="$(printf '%s\n' "$resolved" \
      | grep -E '^172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+$' \
      | sed -n '1p')"
    [[ -n "$resolved" ]] || { printf 'unverified\n'; return; }

    route_interface="${NTFSMAC_ROUTE_INTERFACE_OVERRIDE-}"
    if [[ -z "$route_interface" ]]; then
      route_interface="$(/sbin/route -n get "$resolved" 2>/dev/null \
        | awk '/interface:/{print $2; exit}')"
    fi
    [[ "$route_interface" == bridge* ]] || { printf 'unverified\n'; return; }
  done <<< "$mounts"

  if [[ "$identified" -eq 0 ]]; then
    printf 'inactive\n'
    return
  fi

  listener_count="${NTFSMAC_LOOPBACK_LISTENER_COUNT_OVERRIDE-}"
  if [[ -z "$listener_count" ]]; then
    if /usr/sbin/lsof -nP -iTCP@127.0.0.1:2049 -sTCP:LISTEN >/dev/null 2>&1 || \
       /usr/sbin/lsof -nP -iUDP@127.0.0.1:2049 >/dev/null 2>&1; then
      listener_count=1
    else
      listener_count=0
    fi
  fi
  if [[ "$listener_count" != "0" ]]; then
    printf 'loopback_proxy\n'
  elif [[ "$identified" -gt 0 ]]; then
    printf 'expected_vmnet\n'
  else
    printf 'unverified\n'
  fi
}

# `/sbin/mount -t nfs` on current macOS releases reports only generic VFS flags and can omit
# NFS-specific parameters such as `soft`, even when the kernel mount is demonstrably soft.
# `nfsstat -m` is the authoritative effective-parameter view. Match the exact mount header so a
# soft unrelated NAS mount cannot accidentally validate an ntfsmac mount.
nfs_mount_is_soft() {
  local source="$1" mount_point="$2" nfs_parameters="$3"
  awk -v header="$mount_point from $source" '
    $0 == header { in_mount = 1; next }
    in_mount && $0 !~ /^[[:space:]]/ { exit }
    in_mount && /NFS parameters:/ {
      parameters = $0
      gsub(/[[:space:]]/, "", parameters)
      if (parameters ~ /(^|,)soft(,|$)/) soft = 1
    }
    END { exit soft ? 0 : 1 }
  ' <<< "$nfs_parameters"
}

current_mounts() {
  if [[ -n "${NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE+x}" ]]; then
    printf '%s\n' "$NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE"
  else
    /sbin/mount -t nfs 2>/dev/null
  fi
}

current_nfs_parameters() {
  if [[ -n "${NTFSMAC_NFSSTAT_OUTPUT_OVERRIDE+x}" ]]; then
    printf '%s\n' "$NTFSMAC_NFSSTAT_OUTPUT_OVERRIDE"
  else
    /usr/bin/nfsstat -m 2>/dev/null
  fi
}

check_architecture() {
  printf '%s\n' "${NTFSMAC_ARCHITECTURE_OVERRIDE-$(uname -m 2>/dev/null)}"
}

check_helper_status() {
  if [[ -n "${NTFSMAC_HELPER_STATUS_OVERRIDE+x}" ]]; then
    printf '%s\n' "$NTFSMAC_HELPER_STATUS_OVERRIDE"
    return
  fi

  local helper_path
  helper_path="${NTFSMAC_HELPER_PATH_OVERRIDE-/Library/PrivilegedHelperTools/com.khr898.ntfsmac.helper}"
  if [[ -z "$helper_path" || ! -f "$helper_path" ]]; then
    printf 'not_installed\n'
    return
  fi

  local label="com.khr898.ntfsmac.helper"
  local disabled_output
  if [[ -n "${NTFSMAC_LAUNCHCTL_PRINT_DISABLED_OVERRIDE+x}" ]]; then
    disabled_output="$NTFSMAC_LAUNCHCTL_PRINT_DISABLED_OVERRIDE"
  else
    disabled_output="$(launchctl print-disabled system 2>/dev/null || true)"
  fi

  if [[ "$disabled_output" == *"\"$label\" => disabled"* || "$disabled_output" == *"\"$label\" => true"* ]]; then
    printf 'disabled\n'
    return
  fi

  local print_output print_rc=0
  if [[ -n "${NTFSMAC_LAUNCHCTL_PRINT_HELPER_OVERRIDE+x}" ]]; then
    print_output="$NTFSMAC_LAUNCHCTL_PRINT_HELPER_OVERRIDE"
    [[ "$print_output" == *"Could not find service"* ]] && print_rc=1
  else
    print_output="$(launchctl print "system/$label" 2>/dev/null)" || print_rc=$?
  fi

  if [[ $print_rc -ne 0 || "$print_output" == *"Could not find service"* ]]; then
    if [[ -n "${NTFSMAC_HELPER_PATH_OVERRIDE+x}" && -z "${NTFSMAC_LAUNCHCTL_PRINT_HELPER_OVERRIDE+x}" ]]; then
      printf 'installed\n'
      return
    fi
    printf 'unregistered\n'
    return
  fi

  printf 'installed\n'
}

check_helper_installed() {
  local status
  status="$(check_helper_status)"
  [[ "$status" == "installed" ]]
}

# Reports only whether the default route is carried by a tunnel. It deliberately omits the
# interface name, VPN provider, addresses, routes, and DNS details from both human and JSON output.
check_vpn_default_route() {
  local interface
  interface="${NTFSMAC_DEFAULT_INTERFACE_OVERRIDE-$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')}"
  case "$interface" in
    utun* | ppp* | tun*) return 0 ;;
    *) return 1 ;;
  esac
}

count_mounts() {
  local mounts="$1"
  if [[ -n "${NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE-}" ]]; then
    printf '%s\n' "$NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE"
    return
  fi
  printf '%s\n' "$mounts" | awk 'NF { count++ } END { print count + 0 }'
}

# Component names are fixed internal tokens (never paths or user-provided values), so this small
# Bash-3.2-compatible formatter can emit them without adding a jq/Python runtime dependency.
component_json_array() {
  local components="$1" component first=1
  printf '['
  for component in $components; do
    [[ "$first" -eq 1 ]] || printf ','
    printf '"%s"' "$component"
    first=0
  done
  printf ']'
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
  local kernel_pin bridge mounts nfs_parameters mount_count network_helper nfs_transport_contract architecture healthy=1
  local macos_version macos_major macos_supported=1
  local helper_installed=0 helper_status="not_installed" vpn_default_route=0
  local helper_json vpn_json missing_json quarantined_json healthy_json
  local anylinuxfs_version anylinuxfs_version_status
  local gvproxy_version gvproxy_version_status
  local vmnet_helper_version vmnet_helper_version_status vmnet_helper_source_commit
  MISSING_BINS=0
  QUARANTINED_BINS=0
  MISSING_COMPONENTS=""
  QUARANTINED_COMPONENTS=""

  macos_version="$(check_macos_version)"
  architecture="$(check_architecture)"
  check_vendor_binaries
  kernel_pin="$(check_kernel_pin)"
  bridge="$(check_bridge_up)"
  mounts="$(current_mounts)"
  nfs_parameters="$(current_nfs_parameters)"
  mount_count="$(count_mounts "$mounts")"
  network_helper="$(check_network_helper)"
  nfs_transport_contract="$(check_nfs_transport_contract "$network_helper" "$bridge" "$mounts" "$nfs_parameters")"
  helper_status="$(check_helper_status)"
  [[ "$helper_status" == "installed" ]] && helper_installed=1
  check_vpn_default_route && vpn_default_route=1
  check_alpine_runtime || true
  anylinuxfs_version="$(component_version anylinuxfs)"
  anylinuxfs_version_status="$(version_status "$anylinuxfs_version" "$ANYLINUXFS_EXPECTED_VERSION")"
  gvproxy_version="$(component_version gvproxy)"
  gvproxy_version_status="$(version_status "$gvproxy_version" "$GVPROXY_EXPECTED_VERSION")"
  vmnet_helper_version="$(component_version vmnet-helper)"
  vmnet_helper_version_status="$(version_status "$vmnet_helper_version" "$VMNET_HELPER_EXPECTED_VERSION")"
  vmnet_helper_source_commit="$(vmnet_helper_commit)"

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
  [[ "$kernel_pin" == "mismatch" || "$kernel_pin" == "missing" ]] && healthy=0
  [[ "$architecture" != "arm64" ]] && healthy=0
  [[ "$helper_status" == "disabled" ]] && healthy=0
  case "$ALPINE_RUNTIME_STATE" in
    initialized|not_initialized|migration_available) ;;
    *) healthy=0 ;;
  esac
  [[ "$anylinuxfs_version_status" == "mismatch" ]] && healthy=0
  [[ "$gvproxy_version_status" == "mismatch" ]] && healthy=0
  [[ "$vmnet_helper_version_status" == "mismatch" ]] && healthy=0
  case "$nfs_transport_contract" in
    loopback_proxy|ambiguous|unverified) healthy=0 ;;
  esac

  local network_proxy_url network_proxy_source network_proxy_configured
  network_proxy_url="$(runtime_alpine_resolve_proxy 2>/dev/null || true)"
  network_proxy_source="$(runtime_alpine_proxy_source 2>/dev/null || echo "none")"
  if [[ -n "$network_proxy_url" && "$network_proxy_source" != "none" ]]; then
    network_proxy_configured=true
    network_proxy_url="$(runtime_alpine_sanitize_proxy "$network_proxy_url")"
  else
    network_proxy_configured=false
    network_proxy_url=""
    network_proxy_source="none"
  fi

  if [[ $json_mode -eq 1 ]]; then
    [[ "$healthy" -eq 1 ]] && healthy_json=true || healthy_json=false
    [[ "$helper_installed" -eq 1 ]] && helper_json=true || helper_json=false
    [[ "$vpn_default_route" -eq 1 ]] && vpn_json=true || vpn_json=false
    missing_json="$(component_json_array "$MISSING_COMPONENTS")"
    quarantined_json="$(component_json_array "$QUARANTINED_COMPONENTS")"
    printf '{"diagnostic_schema":%s,"healthy":%s,"ntfsmac_version":"%s","build_version":"%s","macos_version":"%s","architecture":"%s","helper_installed":%s,"helper_status":"%s","missing_binaries":%s,"missing_components":%s,"quarantined_binaries":%s,"quarantined_components":%s,"kernel_pin":"%s","anylinuxfs_version":"%s","anylinuxfs_expected_version":"%s","anylinuxfs_version_status":"%s","anylinuxfs_source_commit":"%s","vmproxy_source_version":"%s","libkrun_version":"%s","libkrunfw_version":"%s","gvproxy_version":"%s","gvproxy_expected_version":"%s","gvproxy_version_status":"%s","gvproxy_source_commit":"%s","vmnet_helper_version":"%s","vmnet_helper_expected_version":"%s","vmnet_helper_version_status":"%s","vmnet_helper_source_commit":"%s","alpine_runtime_tag":"%s","alpine_runtime_digest":"%s","alpine_runtime_state":"%s","alpine_installed_cache":"%s","alpine_installed_version":"%s","ntfs_3g_version":"%s","nfs_utils_version":"%s","bridge":"%s","network_helper":"%s","nfs_transport_contract":"%s","vpn_default_route":%s,"nfs_mount_count":%s,"network_proxy_configured":%s,"network_proxy_source":"%s","network_proxy_url":"%s"}\n' \
      "$NTFSMAC_DIAGNOSTIC_SCHEMA_VERSION" "$healthy_json" "$NTFSMAC_VERSION" \
      "$NTFSMAC_BUILD_VERSION" "$macos_version" "$architecture" "$helper_json" "$helper_status" \
      "$MISSING_BINS" "$missing_json" "$QUARANTINED_BINS" "$quarantined_json" \
      "$kernel_pin" "$anylinuxfs_version" "$ANYLINUXFS_EXPECTED_VERSION" \
      "$anylinuxfs_version_status" "$ANYLINUXFS_SOURCE_COMMIT" "$VMPROXY_SOURCE_VERSION" \
      "$LIBKRUN_VERSION" "$LIBKRUNFW_VERSION" "$gvproxy_version" \
      "$GVPROXY_EXPECTED_VERSION" "$gvproxy_version_status" "$GVPROXY_SOURCE_COMMIT" \
      "$vmnet_helper_version" "$VMNET_HELPER_EXPECTED_VERSION" \
      "$vmnet_helper_version_status" "$vmnet_helper_source_commit" \
      "$ALPINE_RUNTIME_TAG" "$ALPINE_RUNTIME_DIGEST" "$ALPINE_RUNTIME_STATE" \
      "$ALPINE_INSTALLED_CACHE" "$ALPINE_INSTALLED_VERSION" "$NTFS_3G_VERSION" \
      "$NFS_UTILS_VERSION" "$bridge" "$network_helper" "$nfs_transport_contract" \
      "$vpn_json" "$mount_count" \
      "$network_proxy_configured" "$network_proxy_source" "$network_proxy_url"
  else
    echo "diagnose: ntfsmac version: $NTFSMAC_VERSION ($NTFSMAC_BUILD_VERSION)"
    echo "diagnose: macOS version: $macos_version"
    [[ "$macos_supported" -eq 0 ]] && echo "diagnose:   unsupported — ntfsmac requires macOS 13.0+"
    echo "diagnose: architecture: $architecture"
    [[ "$architecture" != "arm64" ]] && echo "diagnose:   unsupported — ntfsmac requires Apple Silicon"
    if [[ "$network_proxy_configured" == "true" ]]; then
      echo "diagnose: network proxy: $network_proxy_url (source: $network_proxy_source)"
    else
      echo "diagnose: network proxy: direct (none configured)"
    fi
    case "$helper_status" in
      installed)
        echo "diagnose: privileged helper: installed"
        ;;
      disabled)
        echo "diagnose: privileged helper: disabled in launchd"
        echo "diagnose:   re-enable with: sudo launchctl enable system/com.khr898.ntfsmac.helper && sudo launchctl bootstrap system /Library/LaunchDaemons/com.khr898.ntfsmac.helper.plist"
        echo "diagnose:   or toggle ON in System Settings ▸ General ▸ Login Items & Extensions"
        ;;
      unregistered)
        echo "diagnose: privileged helper: not registered in launchd"
        echo "diagnose:   register with: sudo launchctl bootstrap system /Library/LaunchDaemons/com.khr898.ntfsmac.helper.plist"
        ;;
      *)
        echo "diagnose: privileged helper: not installed"
        ;;
    esac
    echo "diagnose: vendor binaries missing: $MISSING_BINS"
    [[ -n "$MISSING_COMPONENTS" ]] && echo "diagnose:   missing components: $MISSING_COMPONENTS"
    echo "diagnose: quarantined binaries: $QUARANTINED_BINS"
    [[ -n "$QUARANTINED_COMPONENTS" ]] && echo "diagnose:   quarantined components: $QUARANTINED_COMPONENTS"
    echo "diagnose: kernel pin: $kernel_pin"
    echo "diagnose: anylinuxfs: $anylinuxfs_version (expected $ANYLINUXFS_EXPECTED_VERSION, $anylinuxfs_version_status; source $ANYLINUXFS_SOURCE_COMMIT)"
    echo "diagnose: vmproxy source version: $VMPROXY_SOURCE_VERSION"
    echo "diagnose: libkrun: $LIBKRUN_VERSION"
    echo "diagnose: libkrunfw: $LIBKRUNFW_VERSION"
    echo "diagnose: gvproxy: $gvproxy_version (expected $GVPROXY_EXPECTED_VERSION, $gvproxy_version_status; source $GVPROXY_SOURCE_COMMIT)"
    echo "diagnose: vmnet-helper: $vmnet_helper_version (expected $VMNET_HELPER_EXPECTED_VERSION, $vmnet_helper_version_status; source $vmnet_helper_source_commit)"
    echo "diagnose: Alpine approved runtime: $ALPINE_RUNTIME_TAG ($ALPINE_RUNTIME_DIGEST)"
    echo "diagnose: Alpine runtime state: $ALPINE_RUNTIME_STATE"
    echo "diagnose: Alpine installed: $ALPINE_INSTALLED_VERSION ($ALPINE_INSTALLED_CACHE cache)"
    echo "diagnose: ntfs-3g installed: $NTFS_3G_VERSION"
    echo "diagnose: nfs-utils installed: $NFS_UTILS_VERSION"
    echo "diagnose: vmnet bridge: $bridge"
    echo "diagnose: active network helper: $network_helper"
    echo "diagnose: NFS transport contract: $nfs_transport_contract"
    echo "diagnose: VPN default route: $([[ "$vpn_default_route" -eq 1 ]] && echo detected || echo not detected)"
    echo "diagnose: current NFS mount count: $mount_count"
    echo "diagnose: overall: $([[ $healthy -eq 1 ]] && echo healthy || echo degraded)"
  fi

  [[ $healthy -eq 1 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
