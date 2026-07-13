#!/bin/bash
# tests/run-all.sh — discovers and runs all *.bats files (p0-ci, PLAN.md §6).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "run-all.sh: bats-core not found on PATH (brew install bats-core)" >&2
  exit 1
fi

BATS_FILES=()
while IFS= read -r f; do
  BATS_FILES+=("$f")
done < <(find "$REPO_ROOT/tests" -name '*.bats' | sort)

if [[ ${#BATS_FILES[@]} -eq 0 ]]; then
  echo "run-all.sh: no *.bats files found under tests/"
  exit 0
fi

echo "run-all.sh: running ${#BATS_FILES[@]} bats file(s)"
bats "${BATS_FILES[@]}"
