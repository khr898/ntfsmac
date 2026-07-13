#!/usr/bin/env bats
# tests/build/rootfs.bats — v-alpine-rootfs acceptance (PLAN.md §6).
#
# Runs the real build (network pull of alpine at the locked tag+digest, real cargo/go
# build of a patched init-rootfs) — same live-verification pattern as fetch-prebuilt.bats
# and gvproxy.bats. Greps the generated vm-setup.sh (the package manifest for this rootfs
# — see build/init-rootfs.sh's header for why full VM-boot package installation isn't
# reachable yet: it needs vendor/bin/vmproxy, a v-anylinuxfs-build artifact) for our
# trimmed package list: ntfs-3g and nfs-utils (which provides rpc.nfsd) present; every
# audited-cut package absent.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/init-rootfs.sh"
}

@test "init-rootfs.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "init-rootfs.sh HARD-STOPs on an unresolved TODO-KAVEEN pin" {
  local lock
  lock="$(mktemp)"
  printf 'ALPINE_TAG=TODO-KAVEEN\nALPINE_DIGEST=TODO-KAVEEN\n' > "$lock"
  NTFSMAC_SOURCES_LOCK="$lock" run "$SCRIPT"
  rm -f "$lock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HARD-STOP"* ]]
}

@test "generated vm-setup.sh package manifest matches the trimmed list exactly" {
  run "$SCRIPT"
  local rootfs_home
  rootfs_home="$(echo "$output" | sed -n 's/^init-rootfs: NTFSMAC_ROOTFS_HOME=//p' | tail -1)"
  [ -n "$rootfs_home" ]

  local setup_script
  setup_script="$(find "$rootfs_home" -path '*/rootfs/usr/local/bin/vm-setup.sh' 2>/dev/null | head -1)"
  [ -n "$setup_script" ]
  [ -f "$setup_script" ]

  run grep 'apk --update --no-cache add' "$setup_script"
  [ "$status" -eq 0 ]

  # present: our trimmed list (nfs-utils provides rpc.nfsd; lvm2 provides /etc/lvm/{archive,
  # backup} that vmproxy's guest init hard-requires, see AUDIT.md's corrected lvm2 entry)
  for pkg in bash blkid cryptsetup lsblk lvm2 mount nfs-utils ntfs-3g squashfs-tools; do
    [[ "$output" == *"$pkg"* ]]
  done

  # absent: every audited-cut package
  for pkg in btrfs-progs mdadm ntfs-3g-progs zfs; do
    [[ "$output" != *"$pkg"* ]]
  done
}

@test "vendors the built init-rootfs binary to vendor/bin/init-rootfs" {
  run "$SCRIPT"
  [ -x "$REPO_ROOT/vendor/bin/init-rootfs" ]
  run file "$REPO_ROOT/vendor/bin/init-rootfs"
  [[ "$output" == *"arm64"* ]]
}

@test "vendor/bin/init-rootfs carries the hypervisor entitlement (build/sign.sh actually ran)" {
  run "$SCRIPT"
  run codesign -d --entitlements - --xml "$REPO_ROOT/vendor/bin/init-rootfs"
  [[ "$output" == *"com.apple.security.hypervisor"* ]]
}
