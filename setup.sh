#!/usr/bin/env bash
# setup.sh — one-command bootstrap for ntfsmac dev/build environment.
# Apple Silicon (arm64) macOS only. Wires up the real build/dev steps already in this
# repo: build/preflight.sh (toolchain check) -> submodule init -> build/build-all.sh
# (vendored binaries) -> install.sh (CLI install). GUI build and tests are left as
# manual next steps since they need Xcode / bats-core respectively.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$REPO_ROOT"

echo "=== ntfsmac setup ==="

echo ""
echo "--- Checking toolchain (build/preflight.sh) ---"
"$REPO_ROOT/build/preflight.sh"

echo ""
echo "--- Fetching vendor/src/anylinuxfs submodule ---"
git submodule update --init --recursive

echo ""
echo "--- Building vendored binaries (build/build-all.sh) ---"
echo "This fetches libkrunfw/vmnet-helper, builds gvproxy, anylinuxfs, and vmproxy from"
echo "source (cargo + go), and can take a while on first run."
"$REPO_ROOT/build/build-all.sh"

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Install the CLI:      ./install.sh"
echo "  2. Try it:               ntfsmac diagnose"
echo "  3. Build the GUI (opt.): swift build            (or open Package.swift in Xcode)"
echo "  4. Run tests (opt.):     brew install bats-core && ./tests/run-all.sh"
echo "  5. Using Claude Code?    CLAUDE.md has full architecture + non-negotiables."
