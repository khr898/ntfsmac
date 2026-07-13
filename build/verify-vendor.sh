#!/bin/bash
# build/verify-vendor.sh — v-integration (PLAN.md §6, Phase V exit gate).
#
# Checks what's real and verifiable without a live VM boot: binaries present, arm64
# (host) / aarch64-linux (guest), no com.apple.quarantine xattr, libkrunfw pin match,
# no freebsd-bootstrap/vmproxy-bsd artifacts, and that the anylinuxfs binary actually
# runs (dyld/libkrun link check via --version, no config/VM needed).
#
# Deliberately DOES NOT run `vendor/bin/anylinuxfs list` end-to-end: that calls
# vm_image::init() unconditionally (main.rs:918-922), which needs the guest rootfs's
# apk packages installed — real anylinuxfs Go tool does that by booting a VM at first
# use, and VM boot on an ad-hoc-signed binary needs the com.apple.security.hypervisor
# entitlement. Adding that entitlement is a signing change — PLAN.md §0.3 HARD-STOPs
# any unit that touches signing/entitlements outside §3's plan; that's `2-signing`'s
# job, not this one. See SHARED_TASK_NOTES.md for the full real finding.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"
KERNEL_DIR="${NTFSMAC_VENDOR_KERNEL_DIR:-$REPO_ROOT/vendor/kernel}"

fail() { echo "verify-vendor: FAIL — $1" >&2; }

check_binaries_present() {
  local ok=0
  for bin in anylinuxfs gvproxy vmnet-helper vmproxy init-rootfs; do
    if [[ ! -x "$BIN_DIR/$bin" ]]; then
      fail "$BIN_DIR/$bin missing or not executable"
      ok=1
    fi
  done
  return $ok
}

check_host_binaries_arm64() {
  local ok=0
  for bin in anylinuxfs gvproxy init-rootfs; do
    if ! file "$BIN_DIR/$bin" | grep -q "arm64"; then
      fail "$BIN_DIR/$bin is not arm64"
      ok=1
    fi
  done
  if ! file "$BIN_DIR/vmnet-helper" | grep -q "arm64"; then
    fail "$BIN_DIR/vmnet-helper has no arm64 slice"
    ok=1
  fi
  return $ok
}

check_guest_vmproxy_aarch64_linux() {
  if ! file "$BIN_DIR/vmproxy" | grep -q "ARM aarch64"; then
    fail "$BIN_DIR/vmproxy is not an aarch64 Linux (guest) executable"
    return 1
  fi
  return 0
}

check_no_freebsd_artifacts() {
  local ok=0
  for artifact in vmproxy-bsd freebsd-bootstrap; do
    if [[ -e "$BIN_DIR/$artifact" ]]; then
      fail "$BIN_DIR/$artifact exists — freebsd targets must never be built (L9)"
      ok=1
    fi
  done
  return $ok
}

check_no_quarantine_xattr() {
  local ok=0
  local target
  for target in "$BIN_DIR"/anylinuxfs "$BIN_DIR"/gvproxy "$BIN_DIR"/vmnet-helper "$BIN_DIR"/vmproxy "$BIN_DIR"/init-rootfs; do
    if xattr -p com.apple.quarantine "$target" >/dev/null 2>&1; then
      fail "$target carries com.apple.quarantine"
      ok=1
    fi
  done
  return $ok
}

check_kernel_pin_match() {
  local expected_modules_sha256 actual_modules_sha256
  expected_modules_sha256="$(lock_get LIBKRUNFW_MODULES_SHA256)" || { fail "LIBKRUNFW_MODULES_SHA256 missing from sources.lock"; return 1; }
  if [[ ! -f "$KERNEL_DIR/modules.squashfs" ]]; then
    fail "$KERNEL_DIR/modules.squashfs missing"
    return 1
  fi
  actual_modules_sha256="$(shasum -a 256 "$KERNEL_DIR/modules.squashfs" | awk '{print $1}')"
  if [[ "$actual_modules_sha256" != "$expected_modules_sha256" ]]; then
    fail "modules.squashfs sha256 mismatch — expected $expected_modules_sha256, got $actual_modules_sha256 (libkrunfw build-time leak into runtime kernel pin — HARD-STOP per PLAN.md v-integration Don't clause)"
    return 1
  fi
  if [[ ! -f "$KERNEL_DIR/Image" ]]; then
    fail "$KERNEL_DIR/Image missing"
    return 1
  fi
  echo "verify-vendor: kernel pin OK — modules.squashfs sha256 matches LIBKRUNFW_MODULES_SHA256 ($expected_modules_sha256)"
  return 0
}

check_anylinuxfs_runs() {
  local out
  # Never exec a quarantined binary: executing an ad-hoc/entitled Mach-O with
  # com.apple.quarantine set triggers a Gatekeeper assessment that hangs
  # indefinitely in this environment (real hang observed, root-caused via
  # `sample` on the blocked process — stuck in _dyld_start). Production
  # (install.sh) always strips quarantine before ever executing a binary; this
  # is a safety guard for this diagnostic script, and what lets the
  # quarantine-xattr fixture test (which deliberately sets this xattr) report
  # a clean FAIL instead of hanging.
  if xattr -p com.apple.quarantine "$BIN_DIR/anylinuxfs" >/dev/null 2>&1; then
    fail "$BIN_DIR/anylinuxfs carries com.apple.quarantine, refusing to execute it"
    return 1
  fi
  if ! out="$("$BIN_DIR/anylinuxfs" --version 2>&1)"; then
    fail "anylinuxfs --version failed: $out"
    return 1
  fi
  echo "verify-vendor: anylinuxfs runs — $out"
  return 0
}

main() {
  local failed=0
  check_binaries_present || failed=1
  check_host_binaries_arm64 || failed=1
  check_guest_vmproxy_aarch64_linux || failed=1
  check_no_freebsd_artifacts || failed=1
  check_no_quarantine_xattr || failed=1
  check_kernel_pin_match || failed=1
  check_anylinuxfs_runs || failed=1

  if [[ $failed -ne 0 ]]; then
    echo "verify-vendor: one or more checks failed, see above" >&2
    exit 1
  fi

  echo "verify-vendor: all checks passed."
  echo "verify-vendor: NOTE — live 'anylinuxfs list' (VM boot / real apk install) deferred to"
  echo "verify-vendor: 2-signing (needs com.apple.security.hypervisor entitlement). Not run here"
  echo "verify-vendor: by design — see this script's header and SHARED_TASK_NOTES.md."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
