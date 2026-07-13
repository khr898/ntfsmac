#!/usr/bin/env bats
# tests/build/preflight.bats — p0-toolchain-preflight acceptance checks (PLAN.md §6).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PREFLIGHT="$REPO_ROOT/build/preflight.sh"
  STUB_DIR="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$STUB_DIR"
}

# A minimal PATH with only the tools listed in $1 (space-separated), each stubbed to succeed.
stub_path_with() {
  for tool in $1; do
    cat > "$STUB_DIR/$tool" <<'EOF'
#!/bin/bash
echo "stub $0 1.0.0"
exit 0
EOF
    chmod +x "$STUB_DIR/$tool"
  done
  echo "$STUB_DIR"
}

@test "passes when all required tools are present (real PATH)" {
  run "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight: PASS"* ]]
}

@test "fails when a required tool is missing from PATH" {
  local minimal_path
  minimal_path=$(stub_path_with "git cargo rustc go umoci codesign curl shasum")
  rm -f "$STUB_DIR/umoci"
  PATH="$minimal_path" run "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"umoci"*"FAIL"* ]]
  [[ "$output" == *"preflight: FAILED"* ]]
}

@test "refuses non-arm64 hosts" {
  local fake_uname="$STUB_DIR/uname"
  cat > "$fake_uname" <<'EOF'
#!/bin/bash
if [[ "$1" == "-m" ]]; then echo "x86_64"; else /usr/bin/uname "$@"; fi
EOF
  chmod +x "$fake_uname"
  PATH="$STUB_DIR:$PATH" run "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"arm64"*"required"* ]]
}
