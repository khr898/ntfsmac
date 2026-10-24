#!/usr/bin/env bats
# tests/cli/resolve-vendor-bin.bats — tests for vendor binary resolution security hardening.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/cli/lib/resolve-vendor-bin.sh"
}

@test "resolve_vendor_bin skips PATH when EUID is 0" {
  local temp_dir
  temp_dir="$(mktemp -d)"

  mkdir -p "$temp_dir/fake-bin" "$temp_dir/secure-prefix/bin"
  cat <<'EOF' > "$temp_dir/fake-bin/anylinuxfs"
#!/bin/sh
echo "untrusted-path"
EOF
  chmod +x "$temp_dir/fake-bin/anylinuxfs"

  cat <<'EOF' > "$temp_dir/secure-prefix/bin/anylinuxfs"
#!/bin/sh
echo "secure-prefix"
EOF
  chmod +x "$temp_dir/secure-prefix/bin/anylinuxfs"

  # Under simulated EUID=0, even when fake-bin is first on PATH, PATH lookup is skipped
  run bash -c "
    export PATH=\"$temp_dir/fake-bin:\$PATH\"
    export NTFSMAC_PREFIX=\"$temp_dir/secure-prefix\"
    export NTFSMAC_EFFECTIVE_UID=0
    source \"$SCRIPT\"
    resolve_vendor_bin anylinuxfs
  "
  rm -rf "$temp_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$temp_dir/secure-prefix/bin/anylinuxfs" ]
}

@test "resolve_vendor_bin uses PATH when EUID is non-zero" {
  local temp_dir
  temp_dir="$(mktemp -d)"

  mkdir -p "$temp_dir/fake-bin" "$temp_dir/secure-prefix/bin"
  cat <<'EOF' > "$temp_dir/fake-bin/anylinuxfs"
#!/bin/sh
echo "untrusted-path"
EOF
  chmod +x "$temp_dir/fake-bin/anylinuxfs"

  cat <<'EOF' > "$temp_dir/secure-prefix/bin/anylinuxfs"
#!/bin/sh
echo "secure-prefix"
EOF
  chmod +x "$temp_dir/secure-prefix/bin/anylinuxfs"

  # Under simulated EUID=1000, PATH is used
  run bash -c "
    export PATH=\"$temp_dir/fake-bin:\$PATH\"
    export NTFSMAC_PREFIX=\"$temp_dir/secure-prefix\"
    export NTFSMAC_EFFECTIVE_UID=1000
    source \"$SCRIPT\"
    resolve_vendor_bin anylinuxfs
  "
  rm -rf "$temp_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$temp_dir/fake-bin/anylinuxfs" ]
}

@test "resolve_vendor_bin honors NTFSMAC_ALLOW_UNSAFE_PATH=1 for test harnesses even when EUID is 0" {
  local temp_dir
  temp_dir="$(mktemp -d)"

  mkdir -p "$temp_dir/fake-bin" "$temp_dir/secure-prefix/bin"
  cat <<'EOF' > "$temp_dir/fake-bin/anylinuxfs"
#!/bin/sh
echo "untrusted-path"
EOF
  chmod +x "$temp_dir/fake-bin/anylinuxfs"

  cat <<'EOF' > "$temp_dir/secure-prefix/bin/anylinuxfs"
#!/bin/sh
echo "secure-prefix"
EOF
  chmod +x "$temp_dir/secure-prefix/bin/anylinuxfs"

  run bash -c "
    export PATH=\"$temp_dir/fake-bin:\$PATH\"
    export NTFSMAC_PREFIX=\"$temp_dir/secure-prefix\"
    export NTFSMAC_ALLOW_UNSAFE_PATH=1
    export NTFSMAC_EFFECTIVE_UID=0
    source \"$SCRIPT\"
    resolve_vendor_bin anylinuxfs
  "
  rm -rf "$temp_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$temp_dir/fake-bin/anylinuxfs" ]
}

@test "resolve_vendor_bin ignores homebrew candidate when EUID is 0" {
  local temp_dir
  temp_dir="$(mktemp -d)"

  # Only homebrew prefix has the binary, NTFSMAC_PREFIX does not
  mkdir -p "$temp_dir/homebrew/opt/ntfsmac/bin" "$temp_dir/empty-prefix"
  cat <<'EOF' > "$temp_dir/homebrew/opt/ntfsmac/bin/anylinuxfs"
#!/bin/sh
echo "homebrew"
EOF
  chmod +x "$temp_dir/homebrew/opt/ntfsmac/bin/anylinuxfs"

  run bash -c "
    export PATH=\"/usr/bin:/bin\"
    export NTFSMAC_PREFIX=\"$temp_dir/empty-prefix\"
    export NTFSMAC_EFFECTIVE_UID=0
    source \"$SCRIPT\"
    RESOLVE_VENDOR_BIN_HOMEBREW_OPT_PREFIX=\"$temp_dir/homebrew/opt/ntfsmac\"
    resolve_vendor_bin anylinuxfs
  "
  rm -rf "$temp_dir"
  # Should fail to resolve because Homebrew prefix is ignored under EUID=0
  [ "$status" -ne 0 ]
}
