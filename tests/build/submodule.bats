#!/usr/bin/env bats
# tests/build/submodule.bats — p0-submodule-anylinuxfs acceptance checks (PLAN.md §6).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK_SH="$REPO_ROOT/build/lib/lock.sh"
  SUBMODULE_PATH="$REPO_ROOT/vendor/src/anylinuxfs"
}

@test "submodule URL is exactly the upstream nohajc/anylinuxfs repo" {
  run git config -f "$REPO_ROOT/.gitmodules" submodule.vendor/src/anylinuxfs.url
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/nohajc/anylinuxfs.git" ]
}

@test "submodule checked-out commit matches sources.lock pin" {
  run "$LOCK_SH" get ANYLINUXFS_COMMIT
  [ "$status" -eq 0 ]
  local expected="$output"
  run git -C "$SUBMODULE_PATH" rev-parse HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
