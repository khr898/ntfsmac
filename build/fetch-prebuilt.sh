#!/bin/bash
# build/fetch-prebuilt.sh — v-fetch-prebuilt (PLAN.md §6).
# Downloads libkrunfw (nohajc fork) kernel Image + modules.squashfs, and vmnet-helper
# (nirs/vmnet-helper), both at sources.lock pins. Verifies sha256 BEFORE unpacking;
# aborts and deletes the artifact on mismatch. Never fetches init-freebsd or
# containers/libkrunfw. HARD-STOPs if any pin is missing/TODO-KAVEEN.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

KERNEL_DIR="${NTFSMAC_VENDOR_KERNEL_DIR:-$REPO_ROOT/vendor/kernel}"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"

require_pin() {
  local key="$1" val
  val="$(lock_get "$key")" || { echo "fetch-prebuilt: HARD-STOP — pin '$key' missing from sources.lock" >&2; exit 1; }
  if [[ "$val" == "TODO-KAVEEN" || -z "$val" ]]; then
    echo "fetch-prebuilt: HARD-STOP — pin '$key' is unresolved (TODO-KAVEEN)" >&2
    exit 1
  fi
  printf '%s\n' "$val"
}

# verify_or_abort <file> <expected_sha256> <label>
# On mismatch: deletes the file and returns non-zero. Never unpacks a bad artifact.
verify_or_abort() {
  local file="$1" expected="$2" label="$3" actual
  if [[ ! -f "$file" ]]; then
    echo "fetch-prebuilt: $label — file not found: $file" >&2
    return 1
  fi
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "fetch-prebuilt: $label — sha256 mismatch (expected $expected, got $actual). Aborting, deleting artifact." >&2
    rm -f "$file"
    return 1
  fi
  echo "fetch-prebuilt: $label — sha256 OK"
  return 0
}

# fetch_asset <url> <dest_file> <expected_sha256> <label>
fetch_asset() {
  local url="$1" dest="$2" expected="$3" label="$4"
  echo "fetch-prebuilt: downloading $label from $url"
  if ! curl -fsSL -o "$dest" "$url"; then
    echo "fetch-prebuilt: $label — download failed" >&2
    rm -f "$dest"
    return 1
  fi
  verify_or_abort "$dest" "$expected" "$label"
}

main() {
  mkdir -p "$KERNEL_DIR" "$BIN_DIR"

  local libkrunfw_version images_asset images_sha256 modules_asset modules_sha256
  local vmnet_version vmnet_asset vmnet_sha256
  libkrunfw_version="$(require_pin LIBKRUNFW_VERSION)"
  images_asset="$(require_pin LIBKRUNFW_IMAGES_ASSET)"
  images_sha256="$(require_pin LIBKRUNFW_IMAGES_SHA256)"
  modules_asset="$(require_pin LIBKRUNFW_MODULES_ASSET)"
  modules_sha256="$(require_pin LIBKRUNFW_MODULES_SHA256)"
  vmnet_version="$(require_pin VMNET_HELPER_VERSION)"
  vmnet_asset="$(require_pin VMNET_HELPER_ASSET)"
  vmnet_sha256="$(require_pin VMNET_HELPER_SHA256)"

  local libkrunfw_release="https://github.com/nohajc/libkrunfw/releases/download/${libkrunfw_version}"
  local vmnet_release="https://github.com/nirs/vmnet-helper/releases/download/${vmnet_version}"

  local images_tmp="$KERNEL_DIR/${images_asset}"
  fetch_asset "${libkrunfw_release}/${images_asset}" "$images_tmp" "$images_sha256" "libkrunfw images" || exit 1
  tar xzf "$images_tmp" -C "$KERNEL_DIR"
  rm -f "$images_tmp"

  local modules_dest="$KERNEL_DIR/${modules_asset}"
  fetch_asset "${libkrunfw_release}/${modules_asset}" "$modules_dest" "$modules_sha256" "libkrunfw modules" || exit 1

  local vmnet_tmp="$BIN_DIR/${vmnet_asset}"
  fetch_asset "${vmnet_release}/${vmnet_asset}" "$vmnet_tmp" "$vmnet_sha256" "vmnet-helper" || exit 1
  tar xzf "$vmnet_tmp" -C "$BIN_DIR" --strip-components=4 ./opt/vmnet-helper/bin/vmnet-helper
  rm -f "$vmnet_tmp"
  chmod +x "$BIN_DIR/vmnet-helper"

  echo "fetch-prebuilt: done — $KERNEL_DIR, $BIN_DIR/vmnet-helper"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
