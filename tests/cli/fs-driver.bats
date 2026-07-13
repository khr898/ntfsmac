#!/usr/bin/env bats
# tests/cli/fs-driver.bats — 2-fs-driver-flag acceptance (PLAN.md §6, L1).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/commands/mount.sh"
  STUB_DIR="$(mktemp -d)"
  CALL_LOG="$STUB_DIR/anylinuxfs.calls"
  cat > "$STUB_DIR/anylinuxfs" <<STUB
#!/bin/bash
echo "\$@" >> "$CALL_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/anylinuxfs"
  export PATH="$STUB_DIR:$PATH"
  export NTFSMAC_SKIP_ROOT_CHECK=1
}

teardown() {
  rm -rf "$STUB_DIR"
}

@test "absent --fs-driver keeps default (no -t flag emitted)" {
  run "$SCRIPT" disk2s1
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" != *" -t "* ]]
}

@test "--fs-driver ntfs-3g is a no-op (still no -t flag, matches default)" {
  run "$SCRIPT" --fs-driver ntfs-3g disk2s1
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" != *" -t "* ]]
}

@test "--fs-driver ntfs3 selects ntfs3 via -t, never as an -o token" {
  run "$SCRIPT" --fs-driver ntfs3 disk2s1
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" == *" -t ntfs3"* ]]
  [[ "$output" != *"-o ntfs3"* ]]
}

@test "rejects an invalid --fs-driver value, never invoking anylinuxfs" {
  run "$SCRIPT" --fs-driver hfsplus disk2s1
  [ "$status" -ne 0 ]
  [ ! -f "$CALL_LOG" ]
}
