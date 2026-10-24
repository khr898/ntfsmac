#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIXTURE_DIR="$(mktemp -d)"
  export NTFSMAC_RUNTIME_HOME_OVERRIDE="$FIXTURE_DIR/userhome"
  export NTFSMAC_TARGET_HOME="$FIXTURE_DIR/userhome"
  export NTFSMAC_SKIP_ROOT_CHECK=1
  export NTFSMAC_SKIP_RUNTIME_INIT=1
  export PREFIX="$FIXTURE_DIR/prefix"
  export PATH_SYMLINK="$FIXTURE_DIR/symlink/ntfsmac"
  export NTFSMAC_DISABLE_SYSTEM_PROXY=1

  mkdir -p "$FIXTURE_DIR/userhome/.anylinuxfs" "$FIXTURE_DIR/prefix/bin" "$FIXTURE_DIR/prefix/libexec" "$FIXTURE_DIR/symlink"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "runtime_alpine_read_config_proxy parses proxy under [network]" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[network]
helper = "vmnet"
proxy = "http://127.0.0.1:7890"

[alpine]
custom_packages = ["git"]
EOF

  run runtime_alpine_read_config_proxy "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:7890" ]
}

@test "runtime_alpine_read_config_proxy parses proxy under [alpine]" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[alpine]
custom_packages = ["git"]
proxy = "http://10.0.0.5:8080"
EOF

  run runtime_alpine_read_config_proxy "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "http://10.0.0.5:8080" ]
}

@test "runtime_alpine_sanitize_proxy masks passwords" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  run runtime_alpine_sanitize_proxy "http://alice:supersecret@127.0.0.1:7890"
  [ "$status" -eq 0 ]
  [ "$output" = "http://alice:***@127.0.0.1:7890" ]

  run runtime_alpine_sanitize_proxy "http://127.0.0.1:7890"
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:7890" ]
}

@test "runtime_alpine_resolve_proxy prioritizes environment over config" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[network]
proxy = "http://config.proxy:7890"
EOF

  export NTFSMAC_PROXY="http://env.proxy:8080"
  run runtime_alpine_resolve_proxy "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "http://env.proxy:8080" ]

  run runtime_alpine_proxy_source "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "environment" ]

  unset NTFSMAC_PROXY
  run runtime_alpine_resolve_proxy "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "http://config.proxy:7890" ]

  run runtime_alpine_proxy_source "$FIXTURE_DIR/userhome"
  [ "$status" -eq 0 ]
  [ "$output" = "config" ]
}

@test "install.sh --proxy saves proxy to config.toml" {
  export NTFSMAC_PREFIX="$PREFIX"
  export NTFSMAC_PATH_SYMLINK="$PATH_SYMLINK"
  export NTFSMAC_TARGET_HOME="$FIXTURE_DIR/userhome"

  run bash "$REPO_ROOT/install.sh" --no-path-link --proxy http://127.0.0.1:8888
  [ "$status" -eq 0 ]

  [ -f "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml" ]
  run grep -E 'proxy[[:space:]]*=[[:space:]]*"http://127.0.0.1:8888"' "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
  [ "$status" -eq 0 ]
}

@test "diagnose reports network proxy state from config.toml" {
  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[network]
proxy = "http://testuser:password123@127.0.0.1:9090"
EOF

  run bash "$REPO_ROOT/cli/commands/diagnose.sh" --json
  [ "$status" -eq 1 ] # degraded because fake prefix lacks binaries, but json output is valid
  [[ "$output" == *'"network_proxy_configured":true'* ]]
  [[ "$output" == *'"network_proxy_source":"config"'* ]]
  [[ "$output" == *'"network_proxy_url":"http://testuser:***@127.0.0.1:9090"'* ]]
}

@test "runtime_alpine_sanitize_proxy handles complex passwords and empty strings" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  run runtime_alpine_sanitize_proxy ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  run runtime_alpine_sanitize_proxy "http://user:p@ss:w/ord@proxy.example.com:8080"
  [ "$status" -eq 0 ]
  [ "$output" = "http://user:***@proxy.example.com:8080" ]
}

@test "runtime_alpine_detect_system_proxy parses HTTP proxy from mock scutil" {
  # shellcheck source=../../cli/lib/runtime-alpine.sh
  source "$REPO_ROOT/cli/lib/runtime-alpine.sh"

  unset NTFSMAC_DISABLE_SYSTEM_PROXY
  mkdir -p "$FIXTURE_DIR/bin"
  cat <<'EOF' > "$FIXTURE_DIR/bin/scutil"
#!/bin/bash
cat <<'SCUTIL_OUT'
<dictionary> {
  HTTPEnable : 1
  HTTPPort : 7890
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 7890
  HTTPSProxy : 127.0.0.1
}
SCUTIL_OUT
EOF
  chmod +x "$FIXTURE_DIR/bin/scutil"
  PATH="$FIXTURE_DIR/bin:$PATH" run runtime_alpine_detect_system_proxy
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:7890" ]
}

@test "install.sh updates proxy in config.toml without overwriting existing settings" {
  export NTFSMAC_PREFIX="$PREFIX"
  export NTFSMAC_PATH_SYMLINK="$PATH_SYMLINK"
  export NTFSMAC_TARGET_HOME="$FIXTURE_DIR/userhome"

  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[network]
helper = "vmnet"
proxy = "http://old-proxy:8080"

[alpine]
custom_packages = ["htop", "curl"]
EOF

  run bash "$REPO_ROOT/install.sh" --no-path-link --proxy http://new-proxy:9090
  [ "$status" -eq 0 ]

  run cat "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
  [ "$status" -eq 0 ]
  [[ "$output" == *'proxy = "http://new-proxy:9090"'* ]]
  [[ "$output" != *"old-proxy"* ]]
  [[ "$output" == *'custom_packages = ["htop", "curl"]'* ]]
}

@test "diagnose terminal output reports proxy when configured" {
  cat <<'EOF' > "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"
[network]
proxy = "http://myproxy.local:7890"
EOF

  run bash "$REPO_ROOT/cli/commands/diagnose.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diagnose: network proxy: http://myproxy.local:7890 (source: config)"* ]]
}

@test "diagnose terminal output reports direct connection when no proxy configured" {
  rm -f "$FIXTURE_DIR/userhome/.anylinuxfs/config.toml"

  run bash "$REPO_ROOT/cli/commands/diagnose.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"diagnose: network proxy: direct (none configured)"* ]]
}
