#!/usr/bin/env bats
# tests/build/make-dmg.bats — build/make-dmg.sh acceptance checks.
#
# Wraps an already-assembled .app bundle (build/package-app.sh's output) into an
# ad-hoc, DMG-only distributable (L4: DMG-only, never a Homebrew cask).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/make-dmg.sh"

  APP_PARENT="$(mktemp -d)"
  OUT_DIR="$(mktemp -d)"
  APP="$APP_PARENT/ntfsmac.app"

  # A minimal but real .app shape — make-dmg.sh only cares that it's a directory
  # named *.app with something inside, not that it's fully signed (that's
  # package-app.sh's job, covered separately in package-app.bats).
  mkdir -p "$APP/Contents/MacOS"
  cp /bin/echo "$APP/Contents/MacOS/ntfsmac-gui"

  export NTFSMAC_APP_BUNDLE="$APP"
  export NTFSMAC_DMG_OUT="$OUT_DIR/ntfsmac.dmg"
}

teardown() {
  rm -rf "$APP_PARENT" "$OUT_DIR"
}

@test "make-dmg.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "creates a dmg containing the app bundle and an Applications symlink" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$NTFSMAC_DMG_OUT" ]

  MOUNT_DIR="$(mktemp -d)"
  run hdiutil attach "$NTFSMAC_DMG_OUT" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -noautoopen
  [ "$status" -eq 0 ]

  [ -d "$MOUNT_DIR/ntfsmac.app" ]
  [ -L "$MOUNT_DIR/Applications" ]

  hdiutil detach "$MOUNT_DIR" -quiet
  rm -rf "$MOUNT_DIR"
}

@test "fails clearly when the app bundle is missing" {
  rm -rf "$APP"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HARD-STOP"* ]]
}
