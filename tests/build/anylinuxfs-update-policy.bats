#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/audit-anylinuxfs-update.sh"
  POLICY="$REPO_ROOT/docs/dev/ANYLINUXFS_UPDATE_POLICY.md"
  FIXTURE="$BATS_TEST_TMPDIR/anylinuxfs"
  LOCK_FIXTURE="$BATS_TEST_TMPDIR/sources.lock"

  mkdir -p "$FIXTURE/anylinuxfs/src" "$FIXTURE/vmproxy" "$FIXTURE/init-rootfs" \
    "$FIXTURE/etc" "$FIXTURE/share/alpine"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/anylinuxfs/src/settings.rs" "$FIXTURE/anylinuxfs/src/settings.rs"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/anylinuxfs/src/vm_image.rs" "$FIXTURE/anylinuxfs/src/vm_image.rs"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/anylinuxfs/src/main.rs" "$FIXTURE/anylinuxfs/src/main.rs"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/anylinuxfs/Cargo.toml" "$FIXTURE/anylinuxfs/Cargo.toml"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/vmproxy/Cargo.toml" "$FIXTURE/vmproxy/Cargo.toml"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/init-rootfs/main.go" "$FIXTURE/init-rootfs/main.go"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/etc/anylinuxfs.toml" "$FIXTURE/etc/anylinuxfs.toml"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/etc/anylinuxfs-linux.toml" "$FIXTURE/etc/anylinuxfs-linux.toml"
  touch "$FIXTURE/share/alpine/.keep"

  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.name "ntfsmac tests"
  git -C "$FIXTURE" config user.email "tests@example.invalid"
  git -C "$FIXTURE" remote add origin https://github.com/nohajc/anylinuxfs.git
  git -C "$FIXTURE" add .
  git -C "$FIXTURE" commit -qm "pinned"
  PINNED_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
  printf 'fixture dependency lock\n' > "$FIXTURE/anylinuxfs/Cargo.lock"
  git -C "$FIXTURE" add anylinuxfs/Cargo.lock
  git -C "$FIXTURE" commit -qm "candidate dependency update"
  CANDIDATE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
  git -C "$FIXTURE" checkout -q --detach "$PINNED_COMMIT"

  printf 'ANYLINUXFS_VERSION=0.18.0\nANYLINUXFS_COMMIT=%s\nALPINE_TAG=3.23.5\nALPINE_DIGEST=sha256:d858bb5442632a31bd4bca6c5e601dbe6b536fd7942092ea6a08a0a95805693c\n' \
    "$PINNED_COMMIT" > "$LOCK_FIXTURE"
}

@test "candidate audit is read-only and leaves approval pending" {
  NTFSMAC_ANYLINUXFS_SOURCE="$FIXTURE" \
    NTFSMAC_SOURCES_LOCK="$LOCK_FIXTURE" \
    run "$SCRIPT" "$CANDIDATE_COMMIT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"commit_count=1"* ]]
  [[ "$output" == *"dependency_files_changed=true"* ]]
  [[ "$output" == *"local_patch_compatibility=pass"* ]]
  [[ "$output" == *"repository_mutated=false"* ]]
  [[ "$output" == *"decision=pending_manual_review"* ]]
  [ "$(git -C "$FIXTURE" rev-parse HEAD)" = "$PINNED_COMMIT" ]
  [ -z "$(git -C "$FIXTURE" status --porcelain)" ]
}

@test "candidate audit rejects an unavailable ref without fetching implicitly" {
  NTFSMAC_ANYLINUXFS_SOURCE="$FIXTURE" \
    NTFSMAC_SOURCES_LOCK="$LOCK_FIXTURE" \
    run "$SCRIPT" does-not-exist

  [ "$status" -ne 0 ]
  [[ "$output" == *"fetch origin explicitly"* ]]
}

@test "policy requires manual dependency build hardware and rollback evidence" {
  for phrase in "Trust-boundary source review" "Dependency and lock review" \
    "Automated gates" "Hardware gates" "Decision and rollback" \
    "decision=pending_manual_review"; do
    run grep -F "$phrase" "$POLICY"
    [ "$status" -eq 0 ]
  done
}

@test "policy records the exact v0.19.0 dry-run without changing the production pin" {
  run grep -F "28d308bb9ed15611118fa51d998b988b3ee62459" "$POLICY"
  [ "$status" -eq 0 ]
  run grep -F "deferred, not rejected" "$POLICY"
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/build/lib/lock.sh" get ANYLINUXFS_COMMIT
  [ "$status" -eq 0 ]
  [ "$output" = "8aa9ccd6504e64ca26ce769c1623ed1741c6b7d3" ]
}
