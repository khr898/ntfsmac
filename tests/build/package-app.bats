#!/usr/bin/env bats
# tests/build/package-app.bats — build/package-app.sh acceptance checks.
#
# Assembles dist/ntfsmac.app from the swift build release binaries + gui/Info.plist +
# gui/Resources/AppIcon.icns + the privileged helper. Ad-hoc signs everything (L4).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/build/package-app.sh"

  RELEASE_DIR="$(mktemp -d)"
  OUT_DIR="$(mktemp -d)"

  # Real Mach-O fixtures (codesign needs a real binary) standing in for the swift-build
  # release output, named exactly what `swift build -c release` would produce.
  cp /bin/echo "$RELEASE_DIR/ntfsmac-gui"
  cp /bin/cat "$RELEASE_DIR/ntfsmac-helper"
  chmod +x "$RELEASE_DIR/ntfsmac-gui" "$RELEASE_DIR/ntfsmac-helper"

  export NTFSMAC_SWIFT_RELEASE_DIR="$RELEASE_DIR"
  export NTFSMAC_APP_OUT_DIR="$OUT_DIR"
  export NTFSMAC_SKIP_SWIFT_BUILD=1
  APP="$OUT_DIR/ntfsmac.app"
}

teardown() {
  rm -rf "$RELEASE_DIR" "$OUT_DIR"
}

@test "package-app.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "assembles ntfsmac.app with the expected bundle structure" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$APP" ]
  [ -f "$APP/Contents/Info.plist" ]
  [ -f "$APP/Contents/MacOS/ntfsmac-gui" ]
  [ -f "$APP/Contents/Resources/AppIcon.icns" ]
  [ -f "$APP/Contents/Library/LaunchServices/com.khr898.ntfsmac.helper" ]
}

@test "Contents/Info.plist declares CFBundleExecutable matching the launcher binary" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist"
  [ "$status" -eq 0 ]
  [ "$output" = "ntfsmac-gui" ]
}

@test "ad-hoc signs the helper binary, the gui binary, and the outer bundle" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  run codesign -dv "$APP/Contents/Library/LaunchServices/com.khr898.ntfsmac.helper"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Signature=adhoc"* ]]

  run codesign -dv "$APP/Contents/MacOS/ntfsmac-gui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Signature=adhoc"* ]]

  run codesign -dv "$APP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Signature=adhoc"* ]]
}

@test "Package.swift embeds the helper's Info.plist/launchd.plist sections SMJobBless needs" {
  # The Mach-O __info_plist/__launchd_plist sections are added at `swift build` link time
  # (Package.swift's linkerSettings on the ntfsmac-helper target), not by this script — this
  # script only copies+signs the already-linked binary. A fixture binary standing in for the
  # real swift-build output has no such sections, so verify the linker wiring statically
  # instead of otool-ing a fixture that was never actually linked with these flags.
  run grep -c -- '__info_plist' "$REPO_ROOT/Package.swift"
  [ "$status" -eq 0 ]
  run grep -c -- '__launchd_plist' "$REPO_ROOT/Package.swift"
  [ "$status" -eq 0 ]
}

@test "still ad-hoc only — never a real Developer ID / paid cert signing identity (L4)" {
  run grep -E -- '-s\s+"?[A-Za-z0-9]' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "fails clearly when the swift release binaries are missing" {
  rm -f "$RELEASE_DIR/ntfsmac-gui"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HARD-STOP"* ]]
}
