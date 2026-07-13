#!/usr/bin/env bats
# tests/cli/diagnose.bats — 2-diagnose acceptance (PLAN.md §6).
# Covers healthy + each degraded branch and the --json shape. diagnose is read-only —
# no privileged op is ever exercised or mocked here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/commands/diagnose.sh"
  FIXTURE_DIR="$(mktemp -d)"

  for name in anylinuxfs gvproxy vmnet-helper vmproxy; do
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_DIR/$name"
    chmod +x "$FIXTURE_DIR/$name"
  done
  export NTFSMAC_ANYLINUXFS_BIN="$FIXTURE_DIR/anylinuxfs"
  export NTFSMAC_GVPROXY_BIN="$FIXTURE_DIR/gvproxy"
  export NTFSMAC_VMNET_HELPER_BIN="$FIXTURE_DIR/vmnet-helper"
  export NTFSMAC_VMPROXY_BIN="$FIXTURE_DIR/vmproxy"

  # Kernel pin fixture: a lock file + a modules.squashfs whose sha256 matches it.
  mkdir -p "$FIXTURE_DIR/kernel"
  printf 'fake modules content' > "$FIXTURE_DIR/kernel/modules.squashfs"
  local sha
  sha="$(shasum -a 256 "$FIXTURE_DIR/kernel/modules.squashfs" | awk '{print $1}')"
  printf 'LIBKRUNFW_MODULES_SHA256=%s\n' "$sha" > "$FIXTURE_DIR/sources.lock"
  export NTFSMAC_SOURCES_LOCK="$FIXTURE_DIR/sources.lock"
  export NTFSMAC_VENDOR_KERNEL_DIR="$FIXTURE_DIR/kernel"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "healthy: all binaries present, kernel pin matches, no quarantine" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel pin: match"* ]]
  [[ "$output" == *"overall: healthy"* ]]
}

@test "degraded: missing binary" {
  rm "$FIXTURE_DIR/vmproxy"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
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
  [[ "$output" == *'"healthy":true'* ]]
  [[ "$output" == *'"kernel_pin":"match"'* ]]
  [[ "$output" == *'"missing_binaries":0'* ]]
  [[ "$output" == *'"quarantined_binaries":0'* ]]
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

@test "never performs a mount/unmount/pf/route operation (read-only)" {
  run grep -E '\bmount\(|anylinuxfs" (mount|unmount)|pfctl|route add|route delete' "$SCRIPT"
  [ "$status" -ne 0 ]
}
