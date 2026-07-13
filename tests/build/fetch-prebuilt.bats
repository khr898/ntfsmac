#!/usr/bin/env bats
# tests/build/fetch-prebuilt.bats — v-fetch-prebuilt acceptance (PLAN.md §6).
# No network calls: exercises verify_or_abort() directly with local fixtures.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/fetch-prebuilt.sh"
  TMPDIR_TEST="$(mktemp -d)"
  source "$SCRIPT"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "fetch-prebuilt.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "verify_or_abort accepts a file matching its expected sha256" {
  local f="$TMPDIR_TEST/good.bin"
  printf 'ntfsmac-fixture' > "$f"
  local expected
  expected="$(shasum -a 256 "$f" | awk '{print $1}')"
  run verify_or_abort "$f" "$expected" "good-fixture"
  [ "$status" -eq 0 ]
  [ -f "$f" ]
}

@test "verify_or_abort rejects a wrong-checksum fixture: non-zero exit, artifact deleted" {
  local f="$TMPDIR_TEST/bad.bin"
  printf 'ntfsmac-fixture' > "$f"
  local wrong="0000000000000000000000000000000000000000000000000000000000000000"
  wrong="${wrong:0:64}"
  run verify_or_abort "$f" "$wrong" "bad-fixture"
  [ "$status" -ne 0 ]
  [ ! -f "$f" ]
}

@test "require_pin HARD-STOPs on an unresolved TODO-KAVEEN pin" {
  local lock="$TMPDIR_TEST/sources.lock"
  printf 'SOME_KEY=TODO-KAVEEN\n' > "$lock"
  NTFSMAC_SOURCES_LOCK="$lock" run bash -c "source '$SCRIPT'; require_pin SOME_KEY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HARD-STOP"* ]]
}

@test "does not fetch init-freebsd or containers/libkrunfw" {
  run bash -c "grep -v '^#' '$SCRIPT' | grep -i 'nohajc/libkrun/releases\|containers/libkrunfw'"
  [ "$status" -ne 0 ]
}
