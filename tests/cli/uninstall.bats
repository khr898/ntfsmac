#!/usr/bin/env bats
# tests/cli/uninstall.bats — full CLI + vendored-dependency removal, no leftovers.
# Stubs mount/launchctl/id (via PATH) and points HOME/NTFSMAC_PREFIX/NTFSMAC_HELPER_* at a
# scratch dir so nothing under this system's real /Library or ~/.anylinuxfs is ever touched.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/commands/uninstall.sh"
  SCRATCH="$(mktemp -d)"
  STUB_DIR="$SCRATCH/stubs"
  mkdir -p "$STUB_DIR"

  export NTFSMAC_PREFIX="$SCRATCH/prefix"
  # Scratch, never the real /usr/local/bin — a test run must never touch shared system state.
  export NTFSMAC_PATH_SYMLINK="$SCRATCH/path-bin/ntfsmac"
  export HOME="$SCRATCH/home"
  export NTFSMAC_HELPER_PLIST="$SCRATCH/LaunchDaemons/com.khr898.ntfsmac.helper.plist"
  export NTFSMAC_HELPER_BIN="$SCRATCH/PrivilegedHelperTools/com.khr898.ntfsmac.helper"
  mkdir -p "$NTFSMAC_PREFIX/bin" "$NTFSMAC_PREFIX/libexec/ntfsmac/lib" "$HOME/.anylinuxfs" "$HOME/Library/Logs"
  touch "$NTFSMAC_PREFIX/bin/anylinuxfs" "$NTFSMAC_PREFIX/bin/ntfsmac"
  touch "$HOME/.anylinuxfs/config.toml"
  touch "$HOME/Library/Logs/anylinuxfs-abc12345.log" "$HOME/Library/Logs/anylinuxfs_kernel-abc12345.log"
  touch "$HOME/Library/Logs/some-other-app.log"

  # Default stubs: not mounted, id -u = 501 (non-root).
  cat > "$STUB_DIR/mount" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$STUB_DIR/id" <<'STUB'
#!/bin/bash
echo 501
STUB
  cat > "$STUB_DIR/launchctl" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$STUB_DIR"/*
  export PATH="$STUB_DIR:$PATH"
  export NTFSMAC_SKIP_ROOT_CHECK=1
}

teardown() {
  rm -rf "$SCRATCH"
}

@test "removes the full prefix tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$NTFSMAC_PREFIX" ]
}

@test "removes ~/.anylinuxfs (rootfs cache + config) by default" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.anylinuxfs" ]
}

@test "--keep-cache leaves ~/.anylinuxfs in place" {
  run "$SCRIPT" --keep-cache
  [ "$status" -eq 0 ]
  [ -d "$HOME/.anylinuxfs" ]
}

@test "removes only anylinuxfs-prefixed logs, never other apps' logs" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/Library/Logs/anylinuxfs-abc12345.log" ]
  [ ! -f "$HOME/Library/Logs/anylinuxfs_kernel-abc12345.log" ]
  [ -f "$HOME/Library/Logs/some-other-app.log" ]
}

@test "removes the PATH symlink when it points into the prefix being removed" {
  mkdir -p "$(dirname "$NTFSMAC_PATH_SYMLINK")"
  ln -s "$NTFSMAC_PREFIX/bin/ntfsmac" "$NTFSMAC_PATH_SYMLINK"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$NTFSMAC_PATH_SYMLINK" ]
}

@test "leaves an unrelated symlink at the same path alone" {
  mkdir -p "$(dirname "$NTFSMAC_PATH_SYMLINK")"
  local unrelated="$SCRATCH/some-other-target"
  touch "$unrelated"
  ln -s "$unrelated" "$NTFSMAC_PATH_SYMLINK"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$NTFSMAC_PATH_SYMLINK" ]
  [ "$(readlink "$NTFSMAC_PATH_SYMLINK")" = "$unrelated" ]
}

@test "refuses when an NFS mount is active" {
  cat > "$STUB_DIR/mount" <<'STUB'
#!/bin/bash
echo "//server on /Volumes/Drive (nfs)"
STUB
  chmod +x "$STUB_DIR/mount"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -d "$NTFSMAC_PREFIX" ]
}

@test "--force skips the active-mount check" {
  cat > "$STUB_DIR/mount" <<'STUB'
#!/bin/bash
echo "//server on /Volumes/Drive (nfs)"
STUB
  chmod +x "$STUB_DIR/mount"
  run "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ ! -d "$NTFSMAC_PREFIX" ]
}

@test "as non-root: leaves the privileged helper files in place" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running as root"* ]]
}

@test "as root: removes the privileged helper's launchd plist and binary" {
  mkdir -p "$(dirname "$NTFSMAC_HELPER_PLIST")" "$(dirname "$NTFSMAC_HELPER_BIN")"
  touch "$NTFSMAC_HELPER_PLIST" "$NTFSMAC_HELPER_BIN"
  cat > "$STUB_DIR/id" <<'STUB'
#!/bin/bash
echo 0
STUB
  chmod +x "$STUB_DIR/id"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$NTFSMAC_HELPER_PLIST" ]
  [ ! -f "$NTFSMAC_HELPER_BIN" ]
}

@test "self-elevates via sudo when not root, so the privileged helper actually gets removed" {
  unset NTFSMAC_SKIP_ROOT_CHECK
  cat > "$STUB_DIR/sudo" <<STUB
#!/bin/bash
echo "\$@" >> "$SCRATCH/sudo.calls"
exit 0
STUB
  chmod +x "$STUB_DIR/sudo"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SCRATCH/sudo.calls" ]
  run cat "$SCRATCH/sudo.calls"
  [[ "$output" == *"uninstall.sh"* ]]
}

@test "resolve_invoker_home: uses SUDO_USER's real home via dscl when running as root, not root's own HOME" {
  local real_home="$HOME"
  cat > "$STUB_DIR/id" <<'STUB'
#!/bin/bash
echo 0
STUB
  cat > "$STUB_DIR/dscl" <<STUB
#!/bin/bash
echo "NFSHomeDirectory: $real_home"
STUB
  chmod +x "$STUB_DIR/id" "$STUB_DIR/dscl"
  export SUDO_USER="kaveenhimash"
  export HOME="/var/root"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -d "$real_home/.anylinuxfs" ]
}

@test "refuses to run against a suspicious (unset-like) prefix" {
  export NTFSMAC_PREFIX="/usr/local"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "tears down the pf anchor when the script is present" {
  cat > "$NTFSMAC_PREFIX/libexec/ntfsmac/lib/pf-teardown.sh" <<'STUB'
#!/bin/bash
echo "pf-teardown: called" >> "PF_TEARDOWN_LOG"
exit 0
STUB
  sed -i '' "s#PF_TEARDOWN_LOG#$SCRATCH/pf-teardown.log#" "$NTFSMAC_PREFIX/libexec/ntfsmac/lib/pf-teardown.sh"
  chmod +x "$NTFSMAC_PREFIX/libexec/ntfsmac/lib/pf-teardown.sh"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$SCRATCH/pf-teardown.log" ]
}
