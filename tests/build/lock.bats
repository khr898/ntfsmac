#!/usr/bin/env bats
# tests/build/lock.bats — p0-sources-lock acceptance checks (PLAN.md §6).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LOCK_SH="$REPO_ROOT/build/lib/lock.sh"
  LOCK_FILE="$REPO_ROOT/build/sources.lock"
}

@test "sources.lock exists" {
  [ -f "$LOCK_FILE" ]
}

@test "every required pin key is present" {
  for key in ANYLINUXFS_COMMIT LIBKRUN_BRANCH LIBKRUN_COMMIT \
             LIBKRUNFW_VERSION LIBKRUNFW_IMAGES_SHA256 LIBKRUNFW_MODULES_SHA256 \
             VMNET_HELPER_VERSION VMNET_HELPER_SHA256 \
             GVPROXY_VERSION GVPROXY_COMMIT \
             ALPINE_TAG ALPINE_DIGEST; do
    run "$LOCK_SH" get "$key"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "init-freebsd key is absent" {
  run grep -i "init-freebsd\|INIT_FREEBSD" "$LOCK_FILE"
  [ "$status" -ne 0 ]
}

@test "no key holds the literal :latest" {
  run bash -c "grep -v '^#' '$LOCK_FILE' | grep -i ':latest'"
  [ "$status" -ne 0 ]
}

@test "lock.sh get returns non-zero for unknown key" {
  run "$LOCK_SH" get NOT_A_REAL_KEY
  [ "$status" -ne 0 ]
}

@test "alpine tag is a specific patch version, not a floating tag" {
  run "$LOCK_SH" get ALPINE_TAG
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
