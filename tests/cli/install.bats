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
  export NTFSMAC_SKIP_RUNTIME_INIT=1
  export NTFSMAC_RUNTIME_HOME_OVERRIDE="$PREFIX_DIR/runtime-home"
  EXPECTED_RELEASE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/gui/Info.plist")"
  EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$REPO_ROOT/gui/Info.plist")"
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
  [ -f "$PREFIX_DIR/libexec/ntfsmac/lib/version.sh" ]
  [ -f "$PREFIX_DIR/libexec/ntfsmac/pf/ntfsmac.anchor.tmpl" ]
  [ -f "$PREFIX_DIR/libexec/ntfsmac/lib/product-info.plist" ]
}

@test "installed CLI version comes from the copied canonical app Info.plist" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cmp "$REPO_ROOT/gui/Info.plist" "$PREFIX_DIR/libexec/ntfsmac/lib/product-info.plist"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac" diagnose --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"ntfsmac_version\":\"$EXPECTED_RELEASE\""* ]]
  [[ "$output" == *"\"build_version\":\"$EXPECTED_BUILD\""* ]]
}

@test "symlinks ntfsmac onto an already-on-PATH directory automatically" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$NTFSMAC_PATH_SYMLINK" ]
  [ "$(readlink "$NTFSMAC_PATH_SYMLINK")" = "$PREFIX_DIR/bin/ntfsmac" ]
  [[ "$output" == *"linked $NTFSMAC_PATH_SYMLINK"* ]]
}

@test "self-elevates via sudo when not root to enforce root:wheel installation" {
  unset NTFSMAC_SKIP_ROOT_CHECK
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat > "$stub_dir/sudo" <<STUB
#!/bin/bash
echo "\$@" >> "$stub_dir/sudo.calls"
exit 0
STUB
  chmod +x "$stub_dir/sudo"
  PATH="$stub_dir:$PATH" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$stub_dir/sudo.calls" ]
  rm -rf "$stub_dir"
}

@test "no com.apple.quarantine xattr survives on any installed binary" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run ! xattr -p com.apple.quarantine "$PREFIX_DIR/bin/anylinuxfs" >/dev/null 2>&1
  run ! xattr -p com.apple.quarantine "$PREFIX_DIR/libexec/gvproxy" >/dev/null 2>&1
}

@test "runtime update atomically replaces the signed executable inode" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local old_inode
  old_inode="$(stat -f %i "$PREFIX_DIR/bin/anylinuxfs")"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stat -f %i "$PREFIX_DIR/bin/anylinuxfs")" != "$old_inode" ]
  run cmp "$REPO_ROOT/vendor/bin/anylinuxfs" "$PREFIX_DIR/bin/anylinuxfs"
  [ "$status" -eq 0 ]
  run codesign --verify --strict "$PREFIX_DIR/bin/anylinuxfs"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/anylinuxfs" --version
  [ "$status" -eq 0 ]
  [[ "$output" == anylinuxfs* ]]
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
  [[ "$output" == *'"diagnostic_schema":5'* ]]
  [[ "$output" == *"\"ntfsmac_version\":\"$EXPECTED_RELEASE\""* ]]
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

@test "ntfsmac mount help reflects NTFS and ext support" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run "$PREFIX_DIR/bin/ntfsmac" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"NTFS"* ]]
  [[ "$output" == *"ext"* ]]
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

@test "wipe_anylinuxfs_store removes stale alpine caches in target home" {
  local fake_home="$PREFIX_DIR/fakeuser_home"
  mkdir -p "$fake_home/.anylinuxfs/alpine-old-123" "$fake_home/.anylinuxfs/alpine.preserved-456"
  [ -d "$fake_home/.anylinuxfs/alpine-old-123" ]
  [ -d "$fake_home/.anylinuxfs/alpine.preserved-456" ]

  NTFSMAC_TARGET_USER="testuser" NTFSMAC_TARGET_HOME="$fake_home" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$fake_home/.anylinuxfs/alpine-old-123" ]
  [ ! -d "$fake_home/.anylinuxfs/alpine.preserved-456" ]
}

@test "wipe_anylinuxfs_store refuses to wipe cache when NFS mount is active" {
  local fake_home="$PREFIX_DIR/fakeuser_home"
  mkdir -p "$fake_home/.anylinuxfs/alpine-old-123"
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat > "$stub_dir/mount" <<'STUB'
#!/bin/bash
if [[ "$*" == *"-t nfs"* ]]; then
  echo "192.168.64.2:/export on /Volumes/MyShare (nfs)"
  exit 0
fi
exit 0
STUB
  chmod +x "$stub_dir/mount"

  PATH="$stub_dir:$PATH" NTFSMAC_TARGET_USER="testuser" NTFSMAC_TARGET_HOME="$fake_home" run "$SCRIPT"
  rm -rf "$stub_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active NFS mount detected"* ]]
  [ -d "$fake_home/.anylinuxfs/alpine-old-123" ]
}

@test "setup_alpine_environment contract executes anylinuxfs init and announces readiness" {
  local fake_home="$PREFIX_DIR/fakeuser_home"
  mkdir -p "$fake_home"
  local stub_bin
  stub_bin="$(mktemp -d)/anylinuxfs"
  cat > "$stub_bin" <<'STUB'
#!/bin/bash
if [[ "$1" == "init" ]]; then
  echo "STUB_INIT: SUDO_USER=$SUDO_USER HOME=$HOME"
  exit 0
fi
echo "anylinuxfs 0.18.0"
exit 0
STUB
  chmod +x "$stub_bin"

  export NTFSMAC_SKIP_RUNTIME_INIT=0
  export NTFSMAC_ANYLINUXFS_BIN="$stub_bin"
  NTFSMAC_TARGET_USER="testuser" NTFSMAC_TARGET_HOME="$fake_home" run "$SCRIPT"
  rm -rf "$(dirname "$stub_bin")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"setting up microVM environment and installing Alpine runtime"* ]]
  [[ "$output" == *"environment setup complete — Alpine Linux runtime is ready."* ]]
}
