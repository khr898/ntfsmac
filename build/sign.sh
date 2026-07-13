#!/bin/bash
# build/sign.sh — 2-signing (PLAN.md §6, L4).
#
# Ad-hoc signs (`codesign -s -`) every shipped macOS binary we build ourselves.
# Deliberately excludes: vmnet-helper (Apple-signed prebuilt — re-signing would strip
# Apple's real entitlements and break vmnet framework access) and vmproxy (a Linux ELF
# guest binary — codesign doesn't apply to it). Still ad-hoc only (`-s -`), no paid
# Developer ID, no notarization — per L4.
#
# anylinuxfs additionally gets build/entitlements/anylinuxfs.entitlements embedded:
# com.apple.security.hypervisor (needed to actually boot the libkrun microVM) and
# com.apple.security.cs.disable-library-validation (libkrun.dylib is dlopen'd and isn't
# signed with our identity). Confirmed real and necessary by inspecting upstream's own
# vendor/src/anylinuxfs/anylinuxfs.entitlements — though that file has a real typo,
# "com.apple.security.cs.disable-library-validationr" (trailing "r"), which silently
# no-ops the key. Our copy fixes the spelling; not a byte-for-byte vendor of theirs.
# gvproxy needs neither entitlement — plain ad-hoc, no plist.
#
# init-rootfs gets the same entitlements as anylinuxfs: it calls Hypervisor.framework
# directly via vmrunner-sys/vmrunner.go (cgo) to boot the VM itself on first rootfs
# init — same real requirement as anylinuxfs, confirmed by reading vmrunner.go's
# `#cgo darwin LDFLAGS: -framework Hypervisor`. Upstream's own build-app.sh signs it
# with the identical entitlements plist for this reason.
#
# Decided 2026-07-10 (Kaveen, via AskUserQuestion): add the entitlement now rather than
# leave it deferred, so GATE-CLI-BEFORE-GUI can actually fire. Recorded here since this
# deviates from PLAN.md's literal 2-signing Do/Don't/Acceptance wording, which didn't
# originally mention entitlements at all — see SHARED_TASK_NOTES.md.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"
ENTITLEMENTS="${NTFSMAC_ANYLINUXFS_ENTITLEMENTS:-$SCRIPT_DIR/entitlements/anylinuxfs.entitlements}"

SIGNABLE=(anylinuxfs gvproxy init-rootfs)

main() {
  local bin path failed=0
  for bin in "${SIGNABLE[@]}"; do
    path="$BIN_DIR/$bin"
    if [[ ! -f "$path" ]]; then
      echo "sign.sh: $path missing, skipping" >&2
      continue
    fi

    local -a codesign_args=(-s - --force "$path")
    if [[ "$bin" == "anylinuxfs" || "$bin" == "init-rootfs" ]]; then
      if [[ ! -f "$ENTITLEMENTS" ]]; then
        echo "sign.sh: HARD-STOP — entitlements plist not found: $ENTITLEMENTS" >&2
        failed=1
        continue
      fi
      codesign_args=(-s - --force --entitlements "$ENTITLEMENTS" "$path")
    fi

    if ! codesign "${codesign_args[@]}" 2>&1; then
      echo "sign.sh: HARD-STOP — failed to ad-hoc sign $path" >&2
      failed=1
      continue
    fi
    echo "sign.sh: ad-hoc signed $path"
  done
  [[ $failed -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
