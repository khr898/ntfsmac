#!/usr/bin/env bats
# tests/cli/diagnose.bats — 2-diagnose acceptance (PLAN.md §6).
# Covers healthy + each degraded branch and the --json shape. diagnose is read-only —
# no privileged op is ever exercised or mocked here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/commands/diagnose.sh"
  FIXTURE_DIR="$(mktemp -d)"

  printf '#!/bin/bash\n[[ "${1:-}" == "--version" ]] && echo "anylinuxfs 0.18.0"\nexit 0\n' > "$FIXTURE_DIR/anylinuxfs"
  printf '#!/bin/bash\n[[ "${1:-}" == "--version" ]] && echo "gvproxy version v0.8.9"\nexit 0\n' > "$FIXTURE_DIR/gvproxy"
  printf '#!/bin/bash\nif [[ "${1:-}" == "--version" ]]; then echo "version: v0.12.0"; echo "commit: 0caef043005c7d9f03422a9914bc9d3d4637dc84"; fi\nexit 0\n' > "$FIXTURE_DIR/vmnet-helper"
  printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_DIR/vmproxy"
  chmod +x "$FIXTURE_DIR/anylinuxfs" "$FIXTURE_DIR/gvproxy" "$FIXTURE_DIR/vmnet-helper" "$FIXTURE_DIR/vmproxy"
  export NTFSMAC_ANYLINUXFS_BIN="$FIXTURE_DIR/anylinuxfs"
  export NTFSMAC_GVPROXY_BIN="$FIXTURE_DIR/gvproxy"
  export NTFSMAC_VMNET_HELPER_BIN="$FIXTURE_DIR/vmnet-helper"
  export NTFSMAC_VMPROXY_BIN="$FIXTURE_DIR/vmproxy"
  export NTFSMAC_HELPER_PATH_OVERRIDE="$FIXTURE_DIR/ntfsmac-helper"
  cp "$FIXTURE_DIR/anylinuxfs" "$NTFSMAC_HELPER_PATH_OVERRIDE"
  export NTFSMAC_MACOS_VERSION_OVERRIDE="14.5"
  export NTFSMAC_ARCHITECTURE_OVERRIDE="arm64"
  export NTFSMAC_DEFAULT_INTERFACE_OVERRIDE="en0"
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="0"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE=""
  export NTFSMAC_NFSSTAT_OUTPUT_OVERRIDE=""
  export NTFSMAC_BRIDGE_OVERRIDE="down"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="none"
  export NTFSMAC_RESOLVED_IP_OVERRIDE=""
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE=""
  export NTFSMAC_LOOPBACK_LISTENER_COUNT_OVERRIDE="0"

  # Kernel pin fixture: a lock file + a modules.squashfs whose sha256 matches it.
  mkdir -p "$FIXTURE_DIR/kernel"
  printf 'fake modules content' > "$FIXTURE_DIR/kernel/modules.squashfs"
  local sha
  sha="$(shasum -a 256 "$FIXTURE_DIR/kernel/modules.squashfs" | awk '{print $1}')"
  printf 'LIBKRUNFW_MODULES_SHA256=%s\n' "$sha" > "$FIXTURE_DIR/sources.lock"
  printf 'ANYLINUXFS_VERSION=0.18.0\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'ALPINE_TAG=3.23.5\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'ALPINE_DIGEST=sha256:d858bb5442632a31bd4bca6c5e601dbe6b536fd7942092ea6a08a0a95805693c\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'ANYLINUXFS_COMMIT=8aa9ccd6504e64ca26ce769c1623ed1741c6b7d3\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'VMPROXY_VERSION=0.18.0\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'LIBKRUN_VERSION=1.19.3\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'LIBKRUNFW_VERSION=v6.12.62-rev1\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'GVPROXY_VERSION=v0.8.9\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'GVPROXY_COMMIT=9cfc86f66679ef0feed0f20ba1df558fe2bef5c6\n' >> "$FIXTURE_DIR/sources.lock"
  printf 'VMNET_HELPER_VERSION=v0.12.0\n' >> "$FIXTURE_DIR/sources.lock"
  export NTFSMAC_SOURCES_LOCK="$FIXTURE_DIR/sources.lock"
  export NTFSMAC_VENDOR_KERNEL_DIR="$FIXTURE_DIR/kernel"
  export NTFSMAC_RUNTIME_HOME_OVERRIDE="$FIXTURE_DIR/runtime-home"
}

set_nfs_parameters() {
  local mount_point="$1" source="$2" mode="$3"
  export NTFSMAC_NFSSTAT_OUTPUT_OVERRIDE="$mount_point from $source
  -- Current mount parameters:
     NFS parameters: vers=3,tcp,$mode,intr,nolocks"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

write_guest_versions() {
  local rootfs="$1" alpine="$2" ntfs="$3" nfs="$4"
  mkdir -p "$rootfs/etc" "$rootfs/lib/apk/db"
  printf '%s\n' "$alpine" > "$rootfs/etc/alpine-release"
  printf 'P:ntfs-3g\nV:%s\nA:aarch64\n\nP:nfs-utils\nV:%s\nA:aarch64\n' "$ntfs" "$nfs" > "$rootfs/lib/apk/db/installed"
}

@test "healthy: all binaries present, kernel pin matches, no quarantine" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ntfsmac version: 1.0 (1)"* ]]
  [[ "$output" == *"architecture: arm64"* ]]
  [[ "$output" == *"privileged helper: installed"* ]]
  [[ "$output" == *"kernel pin: match"* ]]
  [[ "$output" == *"VPN default route: not detected"* ]]
  [[ "$output" == *"current NFS mount count: 0"* ]]
  [[ "$output" == *"overall: healthy"* ]]
}

@test "degraded: missing binary" {
  rm "$FIXTURE_DIR/vmproxy"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing components: vmproxy"* ]]
  [[ "$output" == *"overall: degraded"* ]]
}

@test "degraded: quarantined binary" {
  xattr -w com.apple.quarantine "0083;00000000;Safari;" "$FIXTURE_DIR/anylinuxfs"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"quarantined binaries: 1"* ]]
}

@test "degraded: kernel pin mismatch" {
  printf 'LIBKRUNFW_MODULES_SHA256=0000000000000000000000000000000000000000000000000000000000000000\n' > "$FIXTURE_DIR/sources.lock"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kernel pin: mismatch"* ]]
}

@test "--json emits well-formed JSON with the expected fields" {
  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == \{*\} ]]
  [[ "$output" == *'"diagnostic_schema":5'* ]]
  [[ "$output" == *'"healthy":true'* ]]
  [[ "$output" == *'"ntfsmac_version":"1.0"'* ]]
  [[ "$output" == *'"build_version":"1"'* ]]
  [[ "$output" == *'"macos_version":"14.5"'* ]]
  [[ "$output" == *'"architecture":"arm64"'* ]]
  [[ "$output" == *'"helper_installed":true'* ]]
  [[ "$output" == *'"kernel_pin":"match"'* ]]
  [[ "$output" == *'"anylinuxfs_version":"0.18.0"'* ]]
  [[ "$output" == *'"anylinuxfs_expected_version":"0.18.0"'* ]]
  [[ "$output" == *'"anylinuxfs_version_status":"match"'* ]]
  [[ "$output" == *'"anylinuxfs_source_commit":"8aa9ccd6504e64ca26ce769c1623ed1741c6b7d3"'* ]]
  [[ "$output" == *'"vmproxy_source_version":"0.18.0"'* ]]
  [[ "$output" == *'"libkrun_version":"1.19.3"'* ]]
  [[ "$output" == *'"libkrunfw_version":"v6.12.62-rev1"'* ]]
  [[ "$output" == *'"gvproxy_version":"v0.8.9"'* ]]
  [[ "$output" == *'"gvproxy_version_status":"match"'* ]]
  [[ "$output" == *'"vmnet_helper_version":"v0.12.0"'* ]]
  [[ "$output" == *'"vmnet_helper_version_status":"match"'* ]]
  [[ "$output" == *'"vmnet_helper_source_commit":"0caef043005c7d9f03422a9914bc9d3d4637dc84"'* ]]
  [[ "$output" == *'"alpine_runtime_tag":"3.23.5"'* ]]
  [[ "$output" == *'"alpine_runtime_digest":"sha256:d858bb5442632a31bd4bca6c5e601dbe6b536fd7942092ea6a08a0a95805693c"'* ]]
  [[ "$output" == *'"alpine_runtime_state":"not_initialized"'* ]]
  [[ "$output" == *'"alpine_installed_cache":"none"'* ]]
  [[ "$output" == *'"alpine_installed_version":"not_installed"'* ]]
  [[ "$output" == *'"ntfs_3g_version":"not_installed"'* ]]
  [[ "$output" == *'"nfs_utils_version":"not_installed"'* ]]
  [[ "$output" == *'"missing_binaries":0'* ]]
  [[ "$output" == *'"missing_components":[]'* ]]
  [[ "$output" == *'"quarantined_binaries":0'* ]]
  [[ "$output" == *'"quarantined_components":[]'* ]]
  [[ "$output" == *'"vpn_default_route":false'* ]]
  [[ "$output" == *'"nfs_mount_count":0'* ]]
  [[ "$output" == *'"network_helper":"none"'* ]]
  [[ "$output" == *'"nfs_transport_contract":"inactive"'* ]]
  [[ "$output" == *'"network_proxy_configured":false'* ]]
  [[ "$output" == *'"network_proxy_source":"none"'* ]]
  [[ "$output" == *'"network_proxy_url":""'* ]]
}

@test "an active vmnet mount satisfies the transport contract" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  # macOS 26.6 omits NFS-specific options from `mount`; `nfsstat -m` is authoritative.
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, nodev, nosuid)"
  set_nfs_parameters "/Volumes/Test" "disk4s2.local:/mnt/Test" "soft"
  export NTFSMAC_BRIDGE_OVERRIDE="up"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="vmnet"
  export NTFSMAC_RESOLVED_IP_OVERRIDE="172.16.0.2"
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE="bridge100"

  run "$SCRIPT" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"network_helper":"vmnet"'* ]]
  [[ "$output" == *'"nfs_transport_contract":"expected_vmnet"'* ]]
  [[ "$output" == *'"healthy":true'* ]]
}

@test "a loopback gvproxy mount violates the vmnet-only transport contract" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, soft)"
  export NTFSMAC_BRIDGE_OVERRIDE="down"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="gvproxy"

  run "$SCRIPT" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"network_helper":"gvproxy"'* ]]
  [[ "$output" == *'"nfs_transport_contract":"loopback_proxy"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "an unrelated NFS mount does not violate the ntfsmac transport contract" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="nas.example:/share on /Volumes/Share (nfs, soft)"

  run "$SCRIPT" --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'"nfs_mount_count":1'* ]]
  [[ "$output" == *'"nfs_transport_contract":"inactive"'* ]]
  [[ "$output" == *'"healthy":true'* ]]
}

@test "a loopback-resolved ntfsmac endpoint fails closed even when vmnet is running" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, soft)"
  set_nfs_parameters "/Volumes/Test" "disk4s2.local:/mnt/Test" "soft"
  export NTFSMAC_BRIDGE_OVERRIDE="up"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="vmnet"
  export NTFSMAC_RESOLVED_IP_OVERRIDE="127.0.0.1"
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE="bridge100"

  run "$SCRIPT" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"nfs_transport_contract":"loopback_proxy"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "a loopback NFS listener fails closed even when the endpoint is private" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, soft)"
  set_nfs_parameters "/Volumes/Test" "disk4s2.local:/mnt/Test" "soft"
  export NTFSMAC_BRIDGE_OVERRIDE="up"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="vmnet"
  export NTFSMAC_RESOLVED_IP_OVERRIDE="172.16.0.2"
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE="bridge100"
  export NTFSMAC_LOOPBACK_LISTENER_COUNT_OVERRIDE="1"

  run "$SCRIPT" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"nfs_transport_contract":"loopback_proxy"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "a non-soft ntfsmac mount fails closed" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="1"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, hard)"
  set_nfs_parameters "/Volumes/Test" "disk4s2.local:/mnt/Test" "hard"
  export NTFSMAC_BRIDGE_OVERRIDE="up"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="vmnet"
  export NTFSMAC_RESOLVED_IP_OVERRIDE="172.16.0.2"
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE="bridge100"

  run "$SCRIPT" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"nfs_transport_contract":"unverified"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "a soft unrelated NFS mount cannot validate a hard ntfsmac mount" {
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="2"
  export NTFSMAC_NFS_MOUNT_OUTPUT_OVERRIDE="disk4s2.local:/mnt/Test on /Volumes/Test (nfs, nodev, nosuid)
nas.example:/share on /Volumes/Share (nfs, nodev, nosuid)"
  export NTFSMAC_NFSSTAT_OUTPUT_OVERRIDE="/Volumes/Test from disk4s2.local:/mnt/Test
  -- Current mount parameters:
     NFS parameters: vers=3,tcp,hard,intr,nolocks
/Volumes/Share from nas.example:/share
  -- Current mount parameters:
     NFS parameters: vers=3,tcp,soft,intr,nolocks"
  export NTFSMAC_BRIDGE_OVERRIDE="up"
  export NTFSMAC_NETWORK_HELPER_OVERRIDE="vmnet"
  export NTFSMAC_RESOLVED_IP_OVERRIDE="172.16.0.2"
  export NTFSMAC_ROUTE_INTERFACE_OVERRIDE="bridge100"

  run "$SCRIPT" --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"nfs_transport_contract":"unverified"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "a legacy Alpine cache is reported without exposing its path" {
  mkdir -p "$NTFSMAC_RUNTIME_HOME_OVERRIDE/.anylinuxfs/alpine/rootfs"
  write_guest_versions "$NTFSMAC_RUNTIME_HOME_OVERRIDE/.anylinuxfs/alpine/rootfs" "3.24.1" "2026.2.25-r0" "2.6.4-r6"
  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"alpine_runtime_state":"migration_available"'* ]]
  [[ "$output" == *'"alpine_installed_cache":"legacy"'* ]]
  [[ "$output" == *'"alpine_installed_version":"3.24.1"'* ]]
  [[ "$output" == *'"ntfs_3g_version":"2026.2.25-r0"'* ]]
  [[ "$output" == *'"nfs_utils_version":"2.6.4-r6"'* ]]
  [[ "$output" != *"$NTFSMAC_RUNTIME_HOME_OVERRIDE"* ]]
}

@test "an initialized pinned cache reports its installed guest package versions" {
  # shellcheck source=../../build/lib/lock.sh
  source "$REPO_ROOT/build/lib/lock.sh"
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"
  runtime_alpine_load
  local base rootfs
  base="$(runtime_alpine_cache_path "$NTFSMAC_RUNTIME_HOME_OVERRIDE")"
  rootfs="$base/rootfs"
  mkdir -p "$rootfs/bin" "$rootfs/usr/sbin" "$rootfs/usr/local/bin" "$rootfs/etc"
  printf '%s' "$ALPINE_RUNTIME_VERSION" > "$base/rootfs.ver"
  : > "$rootfs/bin/bash"
  : > "$rootfs/usr/sbin/rpc.nfsd"
  : > "$rootfs/usr/local/bin/entrypoint.sh"
  : > "$rootfs/vmproxy"
  printf 'rpc_pipefs\nnfsd\n' > "$rootfs/etc/fstab"
  write_guest_versions "$rootfs" "3.23.5" "2026.2.25-r0" "2.6.4-r6"

  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"alpine_runtime_state":"initialized"'* ]]
  [[ "$output" == *'"alpine_installed_cache":"pinned"'* ]]
  [[ "$output" == *'"alpine_installed_version":"3.23.5"'* ]]
  [[ "$output" == *'"ntfs_3g_version":"2026.2.25-r0"'* ]]
  [[ "$output" == *'"nfs_utils_version":"2.6.4-r6"'* ]]
}

@test "a vendor version mismatch is explicit and degrades health" {
  printf '#!/bin/bash\n[[ "${1:-}" == "--version" ]] && echo "gvproxy version v9.9.9"\nexit 0\n' > "$FIXTURE_DIR/gvproxy"
  chmod +x "$FIXTURE_DIR/gvproxy"
  run "$SCRIPT" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"gvproxy_version":"v9.9.9"'* ]]
  [[ "$output" == *'"gvproxy_expected_version":"v0.8.9"'* ]]
  [[ "$output" == *'"gvproxy_version_status":"mismatch"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "a missing versioned component is reported as not installed" {
  rm "$FIXTURE_DIR/anylinuxfs"
  run "$SCRIPT" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"anylinuxfs_version":"not_installed"'* ]]
  [[ "$output" == *'"anylinuxfs_version_status":"not_installed"'* ]]
}

@test "a mismatched pinned cache degrades health without exposing marker contents" {
  # shellcheck source=../../build/lib/lock.sh
  source "$REPO_ROOT/build/lib/lock.sh"
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"
  runtime_alpine_load
  local base
  base="$(runtime_alpine_cache_path "$NTFSMAC_RUNTIME_HOME_OVERRIDE")"
  mkdir -p "$base/rootfs"
  printf 'private-unapproved-marker' > "$base/rootfs.ver"

  run "$SCRIPT" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"alpine_runtime_state":"mismatch"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
  [[ "$output" != *"private-unapproved-marker"* ]]
  [[ "$output" != *"$base"* ]]
}

@test "--json names failing components without exposing local paths or network identity" {
  rm "$FIXTURE_DIR/vmproxy"
  xattr -w com.apple.quarantine "0083;00000000;Safari;" "$FIXTURE_DIR/gvproxy"
  export NTFSMAC_DEFAULT_INTERFACE_OVERRIDE="utun7"
  export NTFSMAC_NFS_MOUNT_COUNT_OVERRIDE="2"

  run "$SCRIPT" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"missing_components":["vmproxy"]'* ]]
  [[ "$output" == *'"quarantined_components":["gvproxy"]'* ]]
  [[ "$output" == *'"vpn_default_route":true'* ]]
  [[ "$output" == *'"nfs_mount_count":2'* ]]
  [[ "$output" != *"$FIXTURE_DIR"* ]]
  [[ "$output" != *'"vpn_interface"'* ]]
  [[ "$output" != *'"ip_address"'* ]]
  [[ "$output" != *'"mount_paths"'* ]]
  [[ "$output" != *'"volume_labels"'* ]]
  [[ "$output" != *'"username"'* ]]
  [[ "$output" != *'"serial"'* ]]
  [[ "$output" != *'"network_interface"'* ]]
  [[ "$output" != *'"nfs_endpoint"'* ]]
}

@test "reports a supported macOS version and stays healthy" {
  export NTFSMAC_MACOS_VERSION_OVERRIDE="14.5"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"macOS version: 14.5"* ]]
  [[ "$output" == *"overall: healthy"* ]]
}

@test "--json includes the macos_version field" {
  export NTFSMAC_MACOS_VERSION_OVERRIDE="14.5"
  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"macos_version":"14.5"'* ]]
}

@test "product version is resolved from project metadata rather than shell constants" {
  local product_info="$FIXTURE_DIR/Info.plist"
  cp "$REPO_ROOT/gui/Info.plist" "$product_info"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.8" "$product_info"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 765" "$product_info"
  export NTFSMAC_PRODUCT_INFO_PLIST_OVERRIDE="$product_info"

  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ntfsmac_version":"9.8"'* ]]
  [[ "$output" == *'"build_version":"765"'* ]]
}

@test "degraded: non-arm64 architecture is unsupported" {
  export NTFSMAC_ARCHITECTURE_OVERRIDE="x86_64"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"architecture: x86_64"* ]]
  [[ "$output" == *"requires Apple Silicon"* ]]
}

@test "helper absence is reported but remains valid for a CLI-only install" {
  export NTFSMAC_HELPER_PATH_OVERRIDE=""
  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"helper_installed":false'* ]]
  [[ "$output" == *'"healthy":true'* ]]
}

@test "helper presence does not depend on the unprivileged caller's execute permission" {
  chmod 400 "$NTFSMAC_HELPER_PATH_OVERRIDE"
  run "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"helper_installed":true'* ]]
}

@test "privileged helper disabled in launchd is reported as disabled with recovery instructions" {
  export NTFSMAC_LAUNCHCTL_PRINT_DISABLED_OVERRIDE='"com.khr898.ntfsmac.helper" => disabled'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"privileged helper: disabled in launchd"* ]]
  [[ "$output" == *"re-enable with: sudo launchctl enable system/com.khr898.ntfsmac.helper"* ]]
  [[ "$output" == *"overall: degraded"* ]]

  run "$SCRIPT" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"helper_installed":false'* ]]
  [[ "$output" == *'"helper_status":"disabled"'* ]]
  [[ "$output" == *'"healthy":false'* ]]
}

@test "privileged helper unregistered in launchd is reported as unregistered with bootstrap instructions" {
  export NTFSMAC_LAUNCHCTL_PRINT_DISABLED_OVERRIDE=""
  export NTFSMAC_LAUNCHCTL_PRINT_HELPER_OVERRIDE="Could not find service in domain for system"
  run "$SCRIPT"
  [[ "$output" == *"privileged helper: not registered in launchd"* ]]
  [[ "$output" == *"register with: sudo launchctl bootstrap system"* ]]

  run "$SCRIPT" --json
  [[ "$output" == *'"helper_installed":false'* ]]
  [[ "$output" == *'"helper_status":"unregistered"'* ]]
}

@test "degraded: macOS older than 13.0 is unsupported" {
  export NTFSMAC_MACOS_VERSION_OVERRIDE="12.6"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS version: 12.6"* ]]
  [[ "$output" == *"unsupported"* ]]
  [[ "$output" == *"overall: degraded"* ]]
}

@test "an undetected macOS version is reported as unknown but not fatal" {
  # Explicit empty override simulates sw_vers returning nothing (the `-` default in
  # check_macos_version keeps an empty *set* value rather than re-running sw_vers).
  export NTFSMAC_MACOS_VERSION_OVERRIDE=""
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"macOS version: unknown"* ]]
  [[ "$output" == *"overall: healthy"* ]]
}

@test "falls back to \$PREFIX/libexec when a binary isn't on PATH (install.sh layout, not PATH by design)" {
  # Real install.sh layout: gvproxy/vmnet-helper/vmproxy live in libexec, never on PATH.
  # Without an env override or PATH entry, the old PATH-only check misreported these as
  # missing on every correctly-installed system.
  unset NTFSMAC_GVPROXY_BIN NTFSMAC_VMNET_HELPER_BIN NTFSMAC_VMPROXY_BIN
  local prefix_dir="$FIXTURE_DIR/prefix"
  mkdir -p "$prefix_dir/bin" "$prefix_dir/libexec"
  cp "$FIXTURE_DIR/anylinuxfs" "$prefix_dir/bin/anylinuxfs"
  cp "$FIXTURE_DIR/gvproxy" "$prefix_dir/libexec/gvproxy"
  cp "$FIXTURE_DIR/vmnet-helper" "$prefix_dir/libexec/vmnet-helper"
  cp "$FIXTURE_DIR/vmproxy" "$prefix_dir/libexec/vmproxy"
  export NTFSMAC_PREFIX="$prefix_dir"
  unset NTFSMAC_ANYLINUXFS_BIN
  export PATH="$prefix_dir/bin:/usr/bin:/bin"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vendor binaries missing: 0"* ]]
}

@test "kernel pin and alpine runtime resolve correctly in a non-standard or Homebrew install prefix" {
  unset NTFSMAC_SOURCES_LOCK NTFSMAC_VENDOR_KERNEL_DIR
  local custom_prefix="$FIXTURE_DIR/custom-opt"
  mkdir -p "$custom_prefix/libexec/ntfsmac/commands" \
           "$custom_prefix/libexec/ntfsmac/lib" \
           "$custom_prefix/lib" \
           "$custom_prefix/bin"

  # Copy diagnose script into custom commands dir
  cp "$SCRIPT" "$custom_prefix/libexec/ntfsmac/commands/diagnose.sh"
  chmod +x "$custom_prefix/libexec/ntfsmac/commands/diagnose.sh"

  # Copy lock.sh, sources.lock, runtime-alpine.sh, version.sh, product-info.plist into custom lib
  cp "$REPO_ROOT/build/lib/lock.sh" "$custom_prefix/libexec/ntfsmac/lib/lock.sh"
  cp "$FIXTURE_DIR/sources.lock" "$custom_prefix/libexec/ntfsmac/sources.lock"
  cp "$REPO_ROOT/cli/lib/runtime-alpine.sh" "$custom_prefix/libexec/ntfsmac/lib/runtime-alpine.sh"
  cp "$REPO_ROOT/cli/lib/version.sh" "$custom_prefix/libexec/ntfsmac/lib/version.sh"
  cp "$REPO_ROOT/gui/Info.plist" "$custom_prefix/libexec/ntfsmac/lib/product-info.plist"
  chmod +x "$custom_prefix/libexec/ntfsmac/lib/lock.sh"

  # Copy modules.squashfs into $custom_prefix/lib
  cp "$FIXTURE_DIR/kernel/modules.squashfs" "$custom_prefix/lib/modules.squashfs"

  # binaries
  cp "$FIXTURE_DIR/anylinuxfs" "$custom_prefix/bin/anylinuxfs"
  cp "$FIXTURE_DIR/gvproxy" "$custom_prefix/libexec/gvproxy"
  cp "$FIXTURE_DIR/vmnet-helper" "$custom_prefix/libexec/vmnet-helper"
  cp "$FIXTURE_DIR/vmproxy" "$custom_prefix/libexec/vmproxy"

  export NTFSMAC_PREFIX="$custom_prefix"
  export PATH="$custom_prefix/bin:/usr/bin:/bin"

  run "$custom_prefix/libexec/ntfsmac/commands/diagnose.sh" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"kernel_pin":"match"'* ]]
  [[ "$output" == *'"alpine_runtime_tag":"3.23.5"'* ]]
  [[ "$output" == *'"healthy":true'* ]]
}

@test "never performs a mount/unmount/pf/route operation (read-only)" {
  run grep -E '\bmount\(|anylinuxfs" (mount|unmount)|pfctl|route add|route delete' "$SCRIPT"
  [ "$status" -ne 0 ]
}

