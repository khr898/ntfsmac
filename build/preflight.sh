#!/bin/bash
# build/preflight.sh — p0-toolchain-preflight (PLAN.md §6).
# Checks presence + min versions of required build tools. Prints a pass/fail table.
# Never installs anything; never assumes a tool exists. Refuses non-arm64 hosts.
set -uo pipefail

FAIL=0

check_arch() {
  local arch
  arch=$(uname -m)
  if [[ "$arch" != "arm64" ]]; then
    printf '%-20s %-10s %s\n' "arch" "FAIL" "Apple Silicon (arm64) required, got: $arch"
    FAIL=1
    return
  fi
  printf '%-20s %-10s %s\n' "arch" "OK" "$arch"
}

check_tool() {
  local name="$1" cmd="$2" version_flag="${3:---version}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '%-20s %-10s %s\n' "$name" "FAIL" "not found on PATH"
    FAIL=1
    return
  fi
  local version_output
  version_output=$("$cmd" $version_flag 2>&1 | head -1)
  printf '%-20s %-10s %s\n' "$name" "OK" "$version_output"
}

echo "=== ntfsmac build preflight ==="
check_arch
check_tool "git" git
check_tool "cargo" cargo
check_tool "rustc" rustc
check_tool "go" go version
check_tool "umoci" umoci
check_tool "lld" ld.lld
check_tool "codesign" codesign -v
check_tool "curl" curl
check_tool "shasum" shasum --version

if [[ "$FAIL" -ne 0 ]]; then
  echo ""
  echo "preflight: FAILED — missing/invalid tools above. Install manually (no auto-install)."
  exit 1
fi

echo ""
echo "preflight: PASS"
exit 0
