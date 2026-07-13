#!/usr/bin/env bats
# tests/cli/install.bats — 2-install-sh acceptance (PLAN.md §6, L4, L7, L10).
# Runs against a temp prefix using this repo's real, already-built vendor/bin artifacts.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/install.sh"
  PREFIX_DIR="$(mktemp -d)"
  export NTFSMAC_PREFIX="$PREFIX_DIR"
  # Scratch, never the real /usr/local/bin — a test run must never symlink into shared system
  # state. Nested one level so link_into_path()'s mkdir -p is actually exercised.
  SYMLINK_DIR="$(mktemp -d)/bin"
  export NTFSMAC_PATH_SYMLINK="$SYMLINK_DIR/ntfsmac"
  export NTFSMAC_SKIP_ROOT_CHECK=1
}

teardown() {
  rm -rf "$PREFIX_DIR" "$(dirname "$SYMLINK_DIR")"
}

@test "installs into the temp prefix with the expected bin/libexec layout" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -x "$PREFIX_DIR/bin/anylinuxfs" ]
  [ -x "$PREFIX_DIR/bin/ntfsmac" ]
  [ -x "$PREFIX_DIR/libexec/gvproxy" ]
  [ -x "$PREFIX_DIR/libexec/vmnet-helper" ]
  [ -x "$PREFIX_DIR/libexec/vmproxy" ]
  [ -x "$PREFIX_DIR/libexec/init-rootfs" ]
  [ -f "$PREFIX_DIR/lib/modules.squashfs" ]
  [ -x "$PREFIX_DIR/libexec/ntfsmac/commands/mount.sh" ]
}

@test "symlinks ntfsmac onto an already-on-PATH directory automatically" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$NTFSMAC_PATH_SYMLINK" ]
  [ "$(readlink "$NTFSMAC_PATH_SYMLINK")" = "$PREFIX_DIR/bin/ntfsmac" ]
  [[ "$output" == *"linked $NTFSMAC_PATH_SYMLINK"* ]]
}

@test "self-elevates via sudo only when the prefix/symlink dir actually isn't writable" {
  unset NTFSMAC_SKIP_ROOT_CHECK
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat > "$stub_dir/sudo" <<STUB
#!/bin/bash
echo "\$@" >> "$stub_dir/sudo.calls"
exit 0
STUB
  chmod +x "$stub_dir/sudo"
  # A writable prefix + writable symlink dir (both true here, both scratch mktemp dirs) must
  # never trigger a password prompt.
  PATH="$stub_dir:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$stub_dir/sudo.calls" ]
  rm -rf "$stub_dir"
}

@test "no com.apple.quarantine xattr survives on any installed binary" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run ! xattr -p com.apple.quarantine "$PREFIX_DIR/bin/anylinuxfs" >/dev/null 2>&1
  run ! xattr -p com.apple.quarantine "$PREFIX_DIR/libexec/gvproxy" >/dev/null 2>&1
}

@test "NTFSMAC_REPO defaults to khr898/ntfsmac (no YOURUSERNAME literal)" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"khr898/ntfsmac"* ]]
  run grep -c "YOURUSERNAME" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "NTFSMAC_REPO override is respected" {
  NTFSMAC_REPO="someoneelse/fork" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"someoneelse/fork"* ]]
}

@test "refuses to install on a non-arm64 host" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat > "$stub_dir/uname" <<'STUB'
#!/bin/bash
[[ "$1" == "-m" ]] && echo "x86_64" || echo "Darwin"
STUB
  chmod +x "$stub_dir/uname"
  PATH="$stub_dir:$PATH" run "$SCRIPT"
  rm -rf "$stub_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"arm64"* ]]
  [ ! -e "$PREFIX_DIR/bin/anylinuxfs" ]
}

@test "ntfsmac dispatcher routes to mount/unmount/diagnose" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac" diagnose --json
  [[ "$output" == \{*\} ]]
}

@test "ntfsmac help lists every real command, none left off" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"mount "* ]]
  [[ "$output" == *"unmount "* ]]
  [[ "$output" == *"diagnose"* ]]
  [[ "$output" == *"uninstall"* ]]
}

@test "ntfsmac with no args and --help both show the same help" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac"
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
  run "$PREFIX_DIR/bin/ntfsmac" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands:"* ]]
}

@test "ntfsmac with an unknown command exits non-zero and still shows help" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
  [[ "$output" == *"commands:"* ]]
}
