#!/usr/bin/env bats
# tests/cli/unmount.bats — 2-unmount acceptance (PLAN.md §6).
# Mocks anylinuxfs (records argv) and umount (proves our layer never shells out to it
# directly). Asserts graceful busy/already-unmounted handling and no VM-exit wait.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/commands/unmount.sh"
  STUB_DIR="$(mktemp -d)"
  CALL_LOG="$STUB_DIR/anylinuxfs.calls"

  cat > "$STUB_DIR/anylinuxfs" <<STUB
#!/bin/bash
echo "\$@" >> "$CALL_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/anylinuxfs"

  cat > "$STUB_DIR/umount" <<STUB
#!/bin/bash
echo "\$@" >> "$STUB_DIR/umount.calls"
exit 0
STUB
  chmod +x "$STUB_DIR/umount"

  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

@test "unmounts a bare device by adding /dev/ prefix" {
  run "$SCRIPT" disk2s1
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" == "unmount /dev/disk2s1" ]]
}

@test "unmounts a mount point path as-is" {
  run "$SCRIPT" /Volumes/MyDrive
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" == "unmount /Volumes/MyDrive" ]]
}

@test "never passes --wait-for-vm (would risk hanging on a dead VM)" {
  run "$SCRIPT" disk2s1
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" != *"wait-for-vm"* ]]
}

@test "does not shell out to umount directly (anylinuxfs owns the host unmount)" {
  run "$SCRIPT" disk2s1
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_DIR/umount.calls" ]
}

@test "handles an already-unmounted drive gracefully (anylinuxfs exits 0 with a warning)" {
  cat > "$STUB_DIR/anylinuxfs" <<STUB
#!/bin/bash
echo "\$@" >> "$CALL_LOG"
echo "Drive /dev/disk2s1 no longer mounted but anylinuxfs is still running; try \`anylinuxfs stop\`." >&2
exit 0
STUB
  chmod +x "$STUB_DIR/anylinuxfs"
  run "$SCRIPT" disk2s1
  [ "$status" -eq 0 ]
}

@test "propagates a real unmount failure (e.g. busy) as non-zero" {
  cat > "$STUB_DIR/anylinuxfs" <<STUB
#!/bin/bash
echo "\$@" >> "$CALL_LOG"
echo "device busy" >&2
exit 1
STUB
  chmod +x "$STUB_DIR/anylinuxfs"
  run "$SCRIPT" disk2s1
  [ "$status" -ne 0 ]
}

@test "a wedged anylinuxfs unmount gets killed and reported instead of hanging forever" {
  cat > "$STUB_DIR/anylinuxfs" <<STUB
#!/bin/bash
echo "\$@" >> "$CALL_LOG"
sleep 30
STUB
  chmod +x "$STUB_DIR/anylinuxfs"
  export NTFSMAC_UNMOUNT_TIMEOUT=1
  run "$SCRIPT" disk2s1
  [ "$status" -ne 0 ]
  [[ "$output" == *"no response after 1s"* ]]
}

@test "rejects missing argument" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "rejects a garbage target instead of faking success (e.g. a mistyped 'help')" {
  run "$SCRIPT" help
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid target"* ]]
  [ ! -f "$CALL_LOG" ]
}

@test "no target given: lists currently mounted drives and unmounts the chosen one" {
  cat > "$STUB_DIR/mount" <<STUB
#!/bin/bash
echo "192.168.127.2:/export/a on /Volumes/MyDrive (nfs, nodev, nosuid, mounted by test)"
echo "192.168.127.2:/export/b on /Volumes/OtherDrive (nfs, nodev, nosuid, mounted by test)"
STUB
  chmod +x "$STUB_DIR/mount"

  run "$SCRIPT" <<< "2"
  [ "$status" -eq 0 ]
  run cat "$CALL_LOG"
  [[ "$output" == "unmount /Volumes/OtherDrive" ]]
}

@test "no target given, nothing mounted: clear message, no anylinuxfs call" {
  cat > "$STUB_DIR/mount" <<STUB
#!/bin/bash
exit 0
STUB
  chmod +x "$STUB_DIR/mount"

  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing is currently mounted"* ]]
  [ ! -f "$CALL_LOG" ]
}

@test "no target given, cancel with 'q': does not unmount anything" {
  cat > "$STUB_DIR/mount" <<STUB
#!/bin/bash
echo "192.168.127.2:/export/a on /Volumes/MyDrive (nfs, nodev, nosuid, mounted by test)"
STUB
  chmod +x "$STUB_DIR/mount"

  run "$SCRIPT" <<< "q"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelled"* ]]
  [ ! -f "$CALL_LOG" ]
}
