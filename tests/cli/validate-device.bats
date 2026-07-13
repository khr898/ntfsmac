#!/usr/bin/env bats
# tests/cli/validate-device.bats — 2-device-validation acceptance (PLAN.md §6, L6).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$REPO_ROOT/cli/lib/validate-device.sh"
}

@test "accepts disk2s1" {
  run validate_device "disk2s1"
  [ "$status" -eq 0 ]
}

@test "accepts disk10s3 (multi-digit disk and slice numbers)" {
  run validate_device "disk10s3"
  [ "$status" -eq 0 ]
}

@test "rejects disk2 (no slice)" {
  run validate_device "disk2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]
}

@test "rejects a shell-injection payload" {
  run validate_device "disk2s1; rm -rf /"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]
}

@test "rejects a /dev/ prefixed device" {
  run validate_device "/dev/disk2s1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]
}

@test "rejects an empty string" {
  run validate_device ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]
}

@test "rejects a whole-disk-only string (disk2s)" {
  run validate_device "disk2s"
  [ "$status" -ne 0 ]
}

@test "rejects trailing garbage after a valid device" {
  run validate_device "disk2s1foo"
  [ "$status" -ne 0 ]
}
