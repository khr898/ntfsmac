#!/usr/bin/env bats
# tests/build/build-all.bats — v-anylinuxfs-build acceptance (PLAN.md §6).
#
# Runs the real build (real cargo builds of anylinuxfs + vmproxy, real cargo test for all
# three crates, orchestrates fetch-prebuilt/build-gvproxy/init-rootfs) — same
# live-verification pattern as gvproxy.bats/rootfs.bats/fetch-prebuilt.bats. Slow (full
# release build from a clean cache dir); not mocked, since the acceptance criteria are a
# real arm64 anylinuxfs binary and real cargo test output.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/build-all.sh"
  BIN_ANYLINUXFS="$REPO_ROOT/vendor/bin/anylinuxfs"
  BIN_VMPROXY="$REPO_ROOT/vendor/bin/vmproxy"
}

@test "build-all.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "build-all.sh does not build freebsd-bootstrap or vmproxy-bsd targets" {
  # Comments legitimately name these (explaining why they're cut) — assert no
  # actual build invocation targets them, not that the words never appear.
  run grep -E '(cargo|go) build.*(freebsd|vmproxy-bsd)|--target aarch64-unknown-freebsd|-Z build-std' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "full build: anylinuxfs + vmproxy compile, cargo test passes for all three crates" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cargo test — common-utils"* ]]
  [[ "$output" == *"cargo test — anylinuxfs"* ]]
  [[ "$output" == *"cargo test — vmproxy"* ]]
}

@test "vendor/bin/anylinuxfs exists and is an arm64 (host) executable" {
  [ -x "$BIN_ANYLINUXFS" ]
  run file "$BIN_ANYLINUXFS"
  [[ "$output" == *"arm64"* ]]
}

@test "vendor/bin/anylinuxfs carries the hypervisor entitlement (build/sign.sh actually ran)" {
  # Regression for a real bare-metal failure: a bare `codesign -s -` with no entitlements
  # passes `codesign -v` fine but can't boot the VM (Hypervisor.framework needs
  # com.apple.security.hypervisor) — "start vm error: Invalid argument (errno 22)".
  run codesign -d --entitlements - --xml "$BIN_ANYLINUXFS"
  [[ "$output" == *"com.apple.security.hypervisor"* ]]
}

@test "vendor/bin/vmproxy exists and is an aarch64 Linux (guest) executable" {
  [ -x "$BIN_VMPROXY" ]
  run file "$BIN_VMPROXY"
  [[ "$output" == *"ARM aarch64"* ]]
}

@test "vmproxy is embedded into the generated rootfs vm-setup.sh flow (no vmproxy-bsd artifact produced)" {
  [ ! -e "$REPO_ROOT/vendor/bin/vmproxy-bsd" ]
}
