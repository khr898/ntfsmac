#!/usr/bin/env bats
# tests/build/verify-vendor.bats — v-integration acceptance (PLAN.md §6, Phase V exit gate).
# Real run against the already-built vendor tree — same live-verification pattern as
# build-all.bats/gvproxy.bats/rootfs.bats. Live 'anylinuxfs list' (VM boot) is
# deliberately out of scope here — see verify-vendor.sh's header.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/verify-vendor.sh"
}

@test "verify-vendor.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "verify-vendor.sh passes: binaries present, arm64/aarch64 correct, kernel pin matches, no quarantine xattr" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel pin OK"* ]]
  [[ "$output" == *"anylinuxfs runs"* ]]
  [[ "$output" == *"all checks passed"* ]]
}

@test "verify-vendor.sh HARD-STOPs on a kernel pin mismatch" {
  local lock
  lock="$(mktemp)"
  # Copy the real lock but corrupt the modules sha256 pin.
  sed 's/^LIBKRUNFW_MODULES_SHA256=.*/LIBKRUNFW_MODULES_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$REPO_ROOT/build/sources.lock" > "$lock"
  NTFSMAC_SOURCES_LOCK="$lock" run "$SCRIPT"
  rm -f "$lock"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha256 mismatch"* ]]
}

@test "verify-vendor.sh flags a quarantine xattr as a failure" {
  local bindir fixture
  bindir="$(mktemp -d)"
  cp "$REPO_ROOT/vendor/bin/anylinuxfs" "$REPO_ROOT/vendor/bin/gvproxy" \
     "$REPO_ROOT/vendor/bin/vmnet-helper" "$REPO_ROOT/vendor/bin/vmproxy" \
     "$REPO_ROOT/vendor/bin/init-rootfs" "$bindir/"
  fixture="$bindir/anylinuxfs"
  xattr -w com.apple.quarantine "0083;00000000;Safari;" "$fixture"
  NTFSMAC_VENDOR_BIN_DIR="$bindir" run "$SCRIPT"
  rm -rf "$bindir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"com.apple.quarantine"* ]]
}

@test "verify-vendor.sh does not attempt a live VM boot (no 'list' invocation)" {
  run bash -c "grep -v '^[[:space:]]*#' '$SCRIPT' | grep -E '\"list\"|[^-]list\\\$'"
  [ "$status" -ne 0 ]
}
