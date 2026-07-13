#!/bin/bash
# build/package-app.sh — assembles dist/ntfsmac.app (Phase 3 exit criterion, PLAN.md §4:
# "ships as an ad-hoc-signed DMG that runs on a fresh M-series machine").
#
# Release-builds the gui + helper SPM executables, lays them into a real .app bundle
# (Contents/MacOS, Contents/Resources, Contents/Library/LaunchServices for the raw
# SMJobBless helper tool), then ad-hoc signs (`codesign -s -`, L4 — never a real identity)
# the helper binary, the gui binary, and finally the outer bundle, in that order (inner
# code must be signed before the bundle that contains it).
#
# Bundles vendor/bin/* + cli/{commands,lib} + install.sh into Contents/Resources/cli-src/
# (REPO_ROOT-relative layout install.sh already expects, unchanged) — explicit product
# decision, supersedes this script's prior "CLI installed separately via install.sh/tap"
# note: `HelperService.stageCLI` now runs this same bundled install.sh, already root, right
# after a successful `SMJobBless`, so a GUI-only install is fully self-sufficient with no
# separate Terminal step. `--no-path-link` (install.sh) keeps `ntfsmac` off the user's
# Terminal PATH for this path — CLI stays reachable only via the privileged helper the GUI
# already drives, never a bare shell command, per explicit instruction.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

RELEASE_DIR="${NTFSMAC_SWIFT_RELEASE_DIR:-$REPO_ROOT/.build/release}"
OUT_DIR="${NTFSMAC_APP_OUT_DIR:-$REPO_ROOT/dist}"
APP="$OUT_DIR/ntfsmac.app"

GUI_BIN_NAME="ntfsmac-gui"
HELPER_BIN_NAME="ntfsmac-helper"

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

main() {
  local manifest_file="$REPO_ROOT/helper/GeneratedCLIManifest.swift"
  local restore_manifest=1
  [[ -n "${NTFSMAC_KEEP_GENERATED_MANIFEST:-}" ]] && restore_manifest=0
  # `GeneratedCLIManifest.swift` gets a real hash written into it below, then this trap restores
  # the checked-in placeholder afterward so a local packaging run never leaves the working tree
  # dirty with one machine's real hash — the file's own header comment says "overwritten on
  # every real packaging run", not "committed with a real value". Restoring via a plain file
  # backup, not `git checkout --`: the manifest is a *new*, not-yet-committed file the first time
  # this runs, and `git checkout --` on an untracked path always fails ("did not match any
  # file(s) known to git") — confirmed on the first real run of this script. A backup copy works
  # regardless of git tracking state. The trap references literal, already-substituted paths
  # (not `$manifest_file`/`$REPO_ROOT` as variables) because an EXIT trap runs after `main()` has
  # already returned, outside any `local`'s scope — referencing a `local` var there trips `set
  # -u` (also confirmed on that same first run).
  if [[ "$restore_manifest" -eq 1 ]]; then
    local manifest_backup
    manifest_backup="$(mktemp)"
    cp "$manifest_file" "$manifest_backup"
    # shellcheck disable=SC2064
    trap "cp '$manifest_backup' '$manifest_file' 2>/dev/null; rm -f '$manifest_backup'" EXIT
  fi

  if [[ -z "${NTFSMAC_SKIP_SWIFT_BUILD:-}" ]]; then
    echo "package-app: swift build -c release (pass 1 — placeholder hash, hashing tool only)"
    if ! swift build -c release --package-path "$REPO_ROOT"; then
      echo "package-app: HARD-STOP — swift build -c release (pass 1) failed" >&2
      exit 1
    fi
  fi

  local gui_bin="$RELEASE_DIR/$GUI_BIN_NAME"
  local helper_bin="$RELEASE_DIR/$HELPER_BIN_NAME"
  if [[ ! -f "$gui_bin" ]]; then
    echo "package-app: HARD-STOP — $gui_bin missing (expected swift build -c release output)" >&2
    exit 1
  fi
  if [[ ! -f "$helper_bin" ]]; then
    echo "package-app: HARD-STOP — $helper_bin missing (expected swift build -c release output)" >&2
    exit 1
  fi

  # Assemble the cli-src staging tree once, in a scratch dir, before hashing or copying it
  # anywhere — hashed here (pass-1 helper, still carrying the placeholder) and later copied
  # byte-for-byte into Contents/Resources/cli-src/, so the hash pass-2's helper ships with is
  # guaranteed to match exactly what the bundle actually contains.
  local cli_stage
  cli_stage="$(mktemp -d)"
  mkdir -p "$cli_stage/vendor/bin" "$cli_stage/vendor/kernel" "$cli_stage/cli/commands" "$cli_stage/cli/lib"
  if ! cp "$REPO_ROOT/install.sh" "$cli_stage/install.sh"; then
    echo "package-app: HARD-STOP — failed to stage install.sh" >&2
    exit 1
  fi
  chmod +x "$cli_stage/install.sh"
  if ! cp "$REPO_ROOT"/vendor/bin/* "$cli_stage/vendor/bin/"; then
    echo "package-app: HARD-STOP — failed to stage vendor/bin/*" >&2
    exit 1
  fi
  if ! cp "$REPO_ROOT"/cli/commands/*.sh "$cli_stage/cli/commands/"; then
    echo "package-app: HARD-STOP — failed to stage cli/commands/*.sh" >&2
    exit 1
  fi
  if ! cp "$REPO_ROOT"/cli/lib/*.sh "$cli_stage/cli/lib/"; then
    echo "package-app: HARD-STOP — failed to stage cli/lib/*.sh" >&2
    exit 1
  fi
  if [[ -d "$REPO_ROOT/vendor/kernel" ]]; then
    cp "$REPO_ROOT"/vendor/kernel/* "$cli_stage/vendor/kernel/" 2>/dev/null || true
  fi

  echo "package-app: computing cli-src content hash (pass-1 helper binary as a hashing tool)"
  local tree_hash
  tree_hash="$("$helper_bin" --print-tree-hash "$cli_stage")" || {
    echo "package-app: HARD-STOP — failed to compute cli-src tree hash" >&2
    rm -rf "$cli_stage"
    exit 1
  }
  if [[ -z "$tree_hash" ]]; then
    echo "package-app: HARD-STOP — empty cli-src tree hash" >&2
    rm -rf "$cli_stage"
    exit 1
  fi

  echo "package-app: pinning cli-src hash into GeneratedCLIManifest.swift ($tree_hash)"
  cat > "$manifest_file" <<SWIFT
/// Auto-generated by build/package-app.sh — DO NOT EDIT BY HAND, overwritten on every real
/// packaging run (and restored to the checked-in placeholder afterward). SHA-256 tree hash of
/// Contents/Resources/cli-src/ exactly as staged for this build.
public enum GeneratedCLIManifest {
    public static let expectedTreeHashHex = "$tree_hash"
}
SWIFT
  # This repo lives on an SMB-mounted network share (confirmed elsewhere this session to have
  # coarse/laggy mtime resolution — the same class of issue that broke `swift test`'s generated
  # test-runner scaffold earlier). Writing this file and immediately invoking `swift build`
  # reproducibly hit "input file was modified during the build" here, every time — `sync` plus a
  # short settle gives the network mount's mtime a moment to catch up before SPM stats the file.
  sync
  sleep 1

  echo "package-app: swift build -c release (pass 2 — real hash baked into the shipped helper)"
  if ! swift build -c release --package-path "$REPO_ROOT"; then
    echo "package-app: HARD-STOP — swift build -c release (pass 2) failed" >&2
    rm -rf "$cli_stage"
    exit 1
  fi
  # Re-read: pass 2 rebuilt both binaries at the same $RELEASE_DIR paths — $helper_bin now
  # carries the real pinned hash, this is the one that actually gets signed and installed below.

  local helper_label
  helper_label="$(plist_get "$REPO_ROOT/helper/Info.plist" CFBundleIdentifier)" || {
    echo "package-app: HARD-STOP — couldn't read CFBundleIdentifier from helper/Info.plist" >&2
    exit 1
  }
  # helper_label becomes a path component below (Contents/Library/LaunchServices/$helper_label)
  # and a codesign --identifier value — reject anything that isn't a plain bundle-id-shaped
  # token before it touches a path, same discipline as the `^disk[0-9]+s[0-9]+$` device-name
  # check CLAUDE.md requires before any shell invocation.
  if [[ ! "$helper_label" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "package-app: HARD-STOP — helper/Info.plist CFBundleIdentifier '$helper_label' is not a safe path component" >&2
    exit 1
  fi

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"

  if ! cp "$gui_bin" "$APP/Contents/MacOS/$GUI_BIN_NAME"; then
    echo "package-app: HARD-STOP — failed to copy $gui_bin" >&2
    exit 1
  fi
  if ! cp "$REPO_ROOT/gui/Info.plist" "$APP/Contents/Info.plist"; then
    echo "package-app: HARD-STOP — failed to copy gui/Info.plist" >&2
    exit 1
  fi
  if ! cp "$REPO_ROOT/gui/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; then
    echo "package-app: HARD-STOP — failed to copy gui/Resources/AppIcon.icns" >&2
    exit 1
  fi
  if ! cp "$helper_bin" "$APP/Contents/Library/LaunchServices/$helper_label"; then
    echo "package-app: HARD-STOP — failed to copy $helper_bin" >&2
    exit 1
  fi

  # Copied from $cli_stage (already assembled + hashed above), not re-read from $REPO_ROOT — this
  # guarantees the bundle's actual content is byte-for-byte what GeneratedCLIManifest.swift's
  # pinned hash was computed over.
  local cli_src="$APP/Contents/Resources/cli-src"
  if ! cp -R "$cli_stage/." "$cli_src"; then
    echo "package-app: HARD-STOP — failed to copy staged cli-src into the bundle" >&2
    rm -rf "$cli_stage"
    exit 1
  fi
  rm -rf "$cli_stage"

  echo "package-app: ad-hoc signing helper binary"
  if ! codesign -s - --force --identifier "$helper_label" "$APP/Contents/Library/LaunchServices/$helper_label" 2>&1; then
    echo "package-app: HARD-STOP — failed to sign helper binary" >&2
    exit 1
  fi

  # The gui binary is intentionally not signed standalone here: it has no adjacent Info.plist
  # at this point (no meaningful identifier to set), and the outer-bundle sign below fully
  # re-signs it anyway once Contents/Info.plist is in place.
  echo "package-app: ad-hoc signing outer bundle"
  if ! codesign -s - --force "$APP" 2>&1; then
    echo "package-app: HARD-STOP — failed to sign $APP" >&2
    exit 1
  fi

  echo "package-app: done — $APP"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
