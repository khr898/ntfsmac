#!/bin/bash
# build/verify-signature.sh — 2-signing (PLAN.md §6, L4).
#
# Asserts every signable shipped binary is validly signed, ad-hoc specifically (not a
# real Developer ID — that would be an L4 violation), and carries no
# com.apple.quarantine xattr. anylinuxfs additionally must carry the
# com.apple.security.hypervisor entitlement (needed for real VM boot — see sign.sh).
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"

SIGNABLE=(anylinuxfs gvproxy init-rootfs)

verify_one() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "verify-signature: FAIL — $path missing" >&2
    return 1
  fi
  if ! codesign -v "$path" >/dev/null 2>&1; then
    echo "verify-signature: FAIL — $path is not validly signed" >&2
    return 1
  fi
  local info
  info="$(codesign -dvvv "$path" 2>&1)"
  if [[ "$info" != *"Signature=adhoc"* ]]; then
    echo "verify-signature: FAIL — $path is not ad-hoc signed (L4 violation)" >&2
    return 1
  fi
  if xattr -p com.apple.quarantine "$path" >/dev/null 2>&1; then
    echo "verify-signature: FAIL — $path carries com.apple.quarantine" >&2
    return 1
  fi
  echo "verify-signature: OK — $path (ad-hoc, no quarantine)"
  return 0
}

verify_hypervisor_entitlement() {
  local path="$1" entitlements
  entitlements="$(codesign -d --entitlements - --xml "$path" 2>/dev/null)"
  if [[ "$entitlements" != *"com.apple.security.hypervisor"* ]]; then
    echo "verify-signature: FAIL — $path is missing the com.apple.security.hypervisor entitlement" >&2
    return 1
  fi
  echo "verify-signature: OK — $path carries the hypervisor entitlement"
  return 0
}

main() {
  local bin failed=0
  for bin in "${SIGNABLE[@]}"; do
    verify_one "$BIN_DIR/$bin" || failed=1
  done
  verify_hypervisor_entitlement "$BIN_DIR/anylinuxfs" || failed=1
  verify_hypervisor_entitlement "$BIN_DIR/init-rootfs" || failed=1
  [[ $failed -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
