#!/usr/bin/env bats
# tests/build/audit.bats — v-audit acceptance checks (PLAN.md §6, per §0.1 rule 3: every unit ships a test).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AUDIT="$REPO_ROOT/build/AUDIT.md"
  TRIMMED="$REPO_ROOT/build/alpine-packages.trimmed.txt"
}

@test "AUDIT.md and trimmed package list exist" {
  [ -f "$AUDIT" ]
  [ -f "$TRIMMED" ]
}

@test "AUDIT.md covers every default Alpine package with a decision" {
  for pkg in bash blkid btrfs-progs cryptsetup lsblk lvm2 mdadm mount \
             nfs-utils ntfs-3g ntfs-3g-progs squashfs-tools zfs; do
    run grep -F "$pkg" "$AUDIT"
    [ "$status" -eq 0 ]
  done
}

@test "blkid is explicitly kept" {
  run grep -A1 '| `blkid` |' "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEEP"* ]]
}

@test "freebsd Cargo feature is marked test-drop" {
  run grep -i "freebsd.*test-drop\|test-drop.*freebsd" "$AUDIT"
  [ "$status" -eq 0 ]
}

@test "trimmed package list matches the KEEP decisions exactly" {
  run sort "$TRIMMED"
  [ "$status" -eq 0 ]
  expected=$'bash\nblkid\ncryptsetup\nlsblk\nlvm2\nmount\nnfs-utils\nntfs-3g\nsquashfs-tools'
  [ "$output" = "$expected" ]
}

@test "trimmed list excludes every cut package" {
  for pkg in btrfs-progs mdadm ntfs-3g-progs zfs; do
    run grep -Fx "$pkg" "$TRIMMED"
    [ "$status" -ne 0 ]
  done
}

@test "lvm2 is kept, not cut (corrected: vmproxy's guest init hard-bails without /etc/lvm/{archive,backup})" {
  run grep -Fx "lvm2" "$TRIMMED"
  [ "$status" -eq 0 ]
}

@test "cryptsetup is explicitly kept (BitLocker/LUKS support preserved)" {
  run grep -A1 '| `cryptsetup` |' "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEEP"* ]]
}
