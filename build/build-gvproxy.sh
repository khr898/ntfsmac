#!/bin/bash
# build/build-gvproxy.sh — v-gvproxy (PLAN.md §6).
# Builds gvproxy from source (containers/gvisor-tap-vsock) at the sources.lock pin,
# NOT anylinuxfs's prebuilt gvproxy-darwin (that's a settled PLAN.md cut). Cross-checks
# the pinned tag against anylinuxfs's own download-dependencies.sh and warns on drift.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

CACHE_DIR="${NTFSMAC_GVPROXY_CACHE_DIR:-$REPO_ROOT/build/.cache/gvisor-tap-vsock}"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"
UPSTREAM_URL="https://github.com/containers/gvisor-tap-vsock.git"

# warn_on_tag_drift <lock_version> <anylinuxfs_script>
# Non-fatal: anylinuxfs's own download-dependencies.sh pins its own GVPROXY_VERSION.
# If it has drifted from our sources.lock pin, warn loudly but don't block the build —
# we deliberately build from source instead of using anylinuxfs's prebuilt binary anyway.
warn_on_tag_drift() {
  local lock_version="$1" anylinuxfs_script="$2" upstream_version
  [[ -f "$anylinuxfs_script" ]] || { echo "build-gvproxy: WARN — anylinuxfs's download-dependencies.sh not found at $anylinuxfs_script, skipping drift check" >&2; return 0; }
  upstream_version="$(grep -E '^GVPROXY_VERSION=' "$anylinuxfs_script" | head -1 | cut -d'"' -f2)"
  if [[ -z "$upstream_version" ]]; then
    echo "build-gvproxy: WARN — could not parse GVPROXY_VERSION from $anylinuxfs_script" >&2
    return 0
  fi
  local lock_version_bare="${lock_version#v}"
  if [[ "$upstream_version" != "$lock_version_bare" ]]; then
    echo "build-gvproxy: WARN — sources.lock pins gvproxy v${lock_version_bare}, anylinuxfs's download-dependencies.sh pins v${upstream_version}. Drift detected, not blocking (we build from source)." >&2
  else
    echo "build-gvproxy: tag matches anylinuxfs's own pin (v${upstream_version}) — no drift"
  fi
}

main() {
  local version commit
  version="$(lock_get GVPROXY_VERSION)" || { echo "build-gvproxy: HARD-STOP — GVPROXY_VERSION missing from sources.lock" >&2; exit 1; }
  commit="$(lock_get GVPROXY_COMMIT)" || { echo "build-gvproxy: HARD-STOP — GVPROXY_COMMIT missing from sources.lock" >&2; exit 1; }
  if [[ "$version" == "TODO-KAVEEN" || "$commit" == "TODO-KAVEEN" ]]; then
    echo "build-gvproxy: HARD-STOP — GVPROXY_VERSION/COMMIT unresolved (TODO-KAVEEN)" >&2
    exit 1
  fi

  warn_on_tag_drift "$version" "$REPO_ROOT/vendor/src/anylinuxfs/download-dependencies.sh"

  mkdir -p "$BIN_DIR" "$(dirname "$CACHE_DIR")"
  if [[ -d "$CACHE_DIR/.git" ]]; then
    git -C "$CACHE_DIR" fetch --quiet --tags origin
  else
    rm -rf "$CACHE_DIR"
    git clone --quiet "$UPSTREAM_URL" "$CACHE_DIR"
  fi
  git -C "$CACHE_DIR" checkout --quiet "$commit"

  local head
  head="$(git -C "$CACHE_DIR" rev-parse HEAD)"
  if [[ "$head" != "$commit" ]]; then
    echo "build-gvproxy: HARD-STOP — checked-out HEAD ($head) != locked commit ($commit)" >&2
    exit 1
  fi

  echo "build-gvproxy: building gvproxy @ $commit"
  (cd "$CACHE_DIR" && go build -o "$BIN_DIR/gvproxy" ./cmd/gvproxy)
  chmod +x "$BIN_DIR/gvproxy"
  echo "build-gvproxy: done — $BIN_DIR/gvproxy"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
