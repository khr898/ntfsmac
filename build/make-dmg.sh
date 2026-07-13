#!/bin/bash
# build/make-dmg.sh — wraps build/package-app.sh's dist/ntfsmac.app into an ad-hoc DMG
# (L4: GUI ships DMG-only, never a Homebrew cask — no notarization, no paid Developer ID).
#
# Just hdiutil + a drag-to-Applications layout — nothing here re-signs the .app (that
# already happened in package-app.sh); Gatekeeper's ad-hoc-signature warning on first open
# is expected and documented (right-click → Open), per PLAN.md R3.
#
# hdiutil writes its output to a space-free, off-volume temp path, then a plain `cp` lands
# the finished .dmg in dist/. Real bug, reproduced: writing UDZO output straight to dist/
# (this repo's own volume — a network-mounted NTFS share, "Windows Shared Folder")
# produced a DMG Finder reports as "disk image is corrupted" on mount. hdiutil's
# compressed-format finalization does block-level writes/fsyncs this volume doesn't handle
# correctly — same class of issue build/init-rootfs.sh already documents for the OCI
# blob-copy step ("inappropriate ioctl for device"). Plain sequential writes/copies are
# confirmed fine on this volume; only that finalization pattern isn't.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

APP="${NTFSMAC_APP_BUNDLE:-$REPO_ROOT/dist/ntfsmac.app}"
DMG_OUT="${NTFSMAC_DMG_OUT:-$REPO_ROOT/dist/ntfsmac.dmg}"
VOLUME_NAME="ntfsmac"

main() {
  if [[ ! -d "$APP" ]]; then
    echo "make-dmg: HARD-STOP — app bundle not found: $APP (run build/package-app.sh first)" >&2
    exit 1
  fi

  # Not `local`: the EXIT trap fires after main() returns (at actual process exit, not
  # function return) — a `local` would already be out of scope by then, making `$stage`
  # unbound under `set -u` and skipping cleanup entirely.
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT

  payload="$stage/payload"
  mkdir -p "$payload"

  if ! cp -R "$APP" "$payload/"; then
    echo "make-dmg: HARD-STOP — failed to stage $APP" >&2
    exit 1
  fi
  if ! ln -s /Applications "$payload/Applications"; then
    echo "make-dmg: HARD-STOP — failed to create Applications symlink" >&2
    exit 1
  fi

  # Write the image itself into $stage (off-volume, space-free), not $DMG_OUT directly —
  # see header note on this volume's fsync/finalization quirk.
  tmp_dmg="$stage/ntfsmac.dmg"

  if ! hdiutil create -volname "$VOLUME_NAME" -srcfolder "$payload" -ov -format UDZO "$tmp_dmg" 2>&1; then
    echo "make-dmg: HARD-STOP — hdiutil create failed" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$DMG_OUT")"
  rm -f "$DMG_OUT"

  if ! cp "$tmp_dmg" "$DMG_OUT"; then
    echo "make-dmg: HARD-STOP — failed to copy built DMG to $DMG_OUT" >&2
    exit 1
  fi

  echo "make-dmg: done — $DMG_OUT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
