#!/bin/bash
# Interactive source-build assistant for ntfsmac.
# Double-click this file in Finder, or run it as ./build.command [cli|gui|both].
# Missing build tools are installed only after explicit user consent.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DIST_DIR="$REPO_ROOT/dist"
INTERACTIVE=0
TARGET=""

if [[ -t 1 && -n "${TERM:-}" ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold 2>/dev/null || true)"
  DIM="$(tput dim 2>/dev/null || true)"
  GREEN="$(tput setaf 2 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"
  BLUE="$(tput setaf 4 2>/dev/null || true)"
  RESET="$(tput sgr0 2>/dev/null || true)"
else
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  RED=""
  BLUE=""
  RESET=""
fi

banner() {
  printf '%s\n' "+------------------------------------------------------------+"
  printf '|%s%-60s%s|\n' "$BOLD$BLUE" "             NTFSMAC SOURCE BUILD ASSISTANT" "$RESET"
  printf '|%-60s|\n' " Apple Silicon CLI + self-contained macOS menu-bar app"
  printf '%s\n' "+------------------------------------------------------------+"
}

section() {
  echo ""
  printf '%s==> %s%s\n' "$BOLD$BLUE" "$1" "$RESET"
  printf '%s\n' "--------------------------------------------------------------"
}

ok() {
  printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
  printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"
}

info() {
  printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"
}

pause_if_interactive() {
  if [[ "$INTERACTIVE" -eq 1 && -t 0 ]]; then
    echo ""
    read -r -p "Press Return to close this window..." _unused
  fi
}

fail() {
  echo ""
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$1" >&2
  pause_if_interactive
  exit 1
}

confirm() {
  local prompt="$1" answer
  if [[ ! -t 0 ]]; then
    warn "Automatic installation needs an interactive Terminal."
    return 1
  fi
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: ./build.command [cli|gui|both]

  cli   Build and verify the CLI runtime, then create
        dist/ntfsmac-cli.tar.gz
  gui   Build the shared CLI runtime, run the Swift tests, then create and
        verify dist/ntfsmac.app and dist/ntfsmac.dmg
  both  Create and verify both distributions in one run

With no argument, an interactive menu is shown. Missing command-line build
dependencies can be installed only after an explicit confirmation. Full Xcode
must be installed through Apple; the helper can open its App Store page.
Nothing is installed into /usr/local by this build helper.
EOF
}

choose_target() {
  banner
  echo ""
  printf '  %s1%s  Build CLI software\n' "$BOLD" "$RESET"
  printf '  %s2%s  Build GUI app and DMG\n' "$BOLD" "$RESET"
  printf '  %s3%s  Build both distributions\n' "$BOLD" "$RESET"
  echo ""
  read -r -p "Select 1, 2, or 3: " choice

  case "$choice" in
    1) TARGET="cli" ;;
    2) TARGET="gui" ;;
    3) TARGET="both" ;;
    *) fail "Invalid selection '$choice'." ;;
  esac
}

set_homebrew_path() {
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
  fi
  if command -v brew >/dev/null 2>&1; then
    local llvm_prefix
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    if [[ -n "$llvm_prefix" && -d "$llvm_prefix/bin" ]]; then
      export PATH="$llvm_prefix/bin:$PATH"
    fi
  fi
}

check_platform() {
  section "Platform checks"

  local arch macos_version macos_major
  arch="$(uname -m)"
  [[ "$arch" == "arm64" ]] || fail "ntfsmac supports Apple Silicon only; detected $arch."
  ok "Architecture: $arch"

  macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
  macos_major="${macos_version%%.*}"
  if [[ ! "$macos_major" =~ ^[0-9]+$ || "$macos_major" -lt 13 ]]; then
    fail "macOS 13.0 or newer is required; detected ${macos_version:-unknown}."
  fi
  ok "macOS: $macos_version"
}

ensure_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1 && command -v codesign >/dev/null 2>&1; then
    ok "Apple command-line tools are available"
    return
  fi

  warn "Apple command-line tools are missing."
  if confirm "Open Apple's Command Line Tools installer now?"; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "Complete the Apple installer, then run build.command again."
  fi
  fail "Apple command-line tools are required."
}

ensure_full_xcode() {
  [[ "$TARGET" == "gui" || "$TARGET" == "both" ]] || return

  section "GUI toolchain checks"

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  case "$developer_dir" in
    *Xcode*.app/Contents/Developer)
      ;;
    *)
      if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        warn "Full Xcode is installed but is not the selected developer toolchain."
        if confirm "Select /Applications/Xcode.app for this Mac now?"; then
          sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer || \
            fail "xcode-select could not select the full Xcode toolchain."
          developer_dir="$(xcode-select -p 2>/dev/null || true)"
        else
          fail "The GUI build requires the full Xcode toolchain."
        fi
      else
        warn "Full Xcode is not installed. Command Line Tools alone are not enough for the GUI build."
        if confirm "Open the official Xcode page in the Mac App Store?"; then
          open "macappstore://itunes.apple.com/app/id497799835" || \
            fail "The Mac App Store could not be opened."
          fail "Install Xcode, open it once, then run build.command again."
        fi
        fail "Install full Xcode before building the GUI."
      fi
      ;;
  esac

  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    warn "Xcode still needs to install or approve its first-launch components."
    if confirm "Run Xcode's official first-launch setup now?"; then
      sudo xcodebuild -runFirstLaunch || fail "Xcode first-launch setup did not complete."
    else
      fail "Open Xcode once and complete its first-launch setup before continuing."
    fi
  fi

  xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild is not ready. Open Xcode once and accept Apple's license."
  xcrun --find swift >/dev/null 2>&1 || fail "Swift was not found in the selected Xcode toolchain."
  xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || fail "The macOS SDK is missing from Xcode."
  command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is missing from macOS."

  ok "Selected Xcode: $developer_dir"
  ok "Swift: $(xcrun swift --version 2>&1 | head -1)"
  ok "macOS SDK: $(xcrun --sdk macosx --show-sdk-path)"
  ok "DMG tooling: hdiutil"
}

HOMEBREW_INSTALLER_COMMIT="85d1a3fc80d8a63932f632aca8f787de11d14a64"
HOMEBREW_INSTALLER_SHA256="5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148"
RUSTUP_INSTALLER_SHA256="9502b514362a21096210d498f143b8cdacda365d3dfcf45e8f5541e089ccafc0"

install_homebrew() {
  local installer actual_hash
  installer="$(mktemp)" || fail "Could not create a temporary Homebrew installer file."
  info "Downloading Homebrew's official installer (commit: $HOMEBREW_INSTALLER_COMMIT) over HTTPS"
  if ! curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALLER_COMMIT}/install.sh" \
    --output "$installer"; then
    rm -f "$installer"
    fail "Homebrew's installer could not be downloaded."
  fi
  [[ -s "$installer" ]] || {
    rm -f "$installer"
    fail "Homebrew's downloaded installer is empty."
  }
  actual_hash="$(shasum -a 256 "$installer" | awk '{print $1}')"
  info "Homebrew installer SHA-256: $actual_hash"
  if [[ "${NTFSMAC_ALLOW_UNPINNED_BOOTSTRAP:-0}" != "1" && "$actual_hash" != "$HOMEBREW_INSTALLER_SHA256" ]]; then
    rm -f "$installer"
    fail "Homebrew installer SHA-256 mismatch! Expected $HOMEBREW_INSTALLER_SHA256, got $actual_hash"
  fi

  # Homebrew needs administrator access to create its Apple Silicon prefix. Its
  # NONINTERACTIVE mode deliberately refuses to open a sudo password prompt, so
  # authorize sudo first while this parent Terminal is still interactive. The
  # installer can then reuse the short-lived credential cache without silently
  # treating an administrator as an unprivileged user.
  info "Homebrew needs administrator authorization to create /opt/homebrew"
  sudo -v || {
    rm -f "$installer"
    fail "Administrator authorization was denied or is unavailable."
  }

  NONINTERACTIVE=1 /bin/bash "$installer" || {
    rm -f "$installer"
    fail "Homebrew installation failed."
  }
  rm -f "$installer"
  set_homebrew_path
  command -v brew >/dev/null 2>&1 || fail "Homebrew installed, but brew is still not available on PATH."
}

ensure_homebrew() {
  set_homebrew_path
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew: $(brew --version | head -1)"
    return
  fi

  warn "Homebrew is required by the pinned build toolchain and was not found."
  info "Installer source: https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  if confirm "Download and run the official Homebrew installer?"; then
    install_homebrew
    ok "Homebrew installed"
  else
    fail "Homebrew is required to continue."
  fi
}

ensure_brew_packages() {
  local package missing_packages
  local missing=()
  local required=(llvm lld umoci xz util-linux gettext pkg-config go)

  for package in "${required[@]}"; do
    if ! brew list --versions "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    ok "Homebrew build packages are installed"
    set_homebrew_path
    return
  fi

  missing_packages="${missing[*]}"
  warn "Missing Homebrew packages: $missing_packages"
  if confirm "Install these build packages automatically?"; then
    brew install "${missing[@]}" || fail "Homebrew could not install all required packages."
    set_homebrew_path
    ok "Homebrew build packages installed"
  else
    fail "Install the missing Homebrew packages before continuing."
  fi
}

load_cargo_path() {
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  else
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
}

install_rustup() {
  local installer actual_hash
  installer="$(mktemp)" || fail "Could not create a temporary Rust installer file."
  info "Downloading rustup's official installer over HTTPS"
  if ! curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    "https://sh.rustup.rs" --output "$installer"; then
    rm -f "$installer"
    fail "rustup's installer could not be downloaded."
  fi
  [[ -s "$installer" ]] || {
    rm -f "$installer"
    fail "rustup's downloaded installer is empty."
  }
  actual_hash="$(shasum -a 256 "$installer" | awk '{print $1}')"
  info "rustup installer SHA-256: $actual_hash"
  if [[ "${NTFSMAC_ALLOW_UNPINNED_BOOTSTRAP:-0}" != "1" && "$actual_hash" != "$RUSTUP_INSTALLER_SHA256" ]]; then
    rm -f "$installer"
    fail "rustup installer SHA-256 mismatch! Expected $RUSTUP_INSTALLER_SHA256, got $actual_hash"
  fi
  /bin/sh "$installer" -y --profile minimal || {
    rm -f "$installer"
    fail "Rust installation failed."
  }
  rm -f "$installer"
  load_cargo_path
}

ensure_rust_toolchain() {
  load_cargo_path
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
    warn "The rustup-managed Rust toolchain was not found."
    info "Installer source: https://sh.rustup.rs"
    if confirm "Download and install the official minimal Rust toolchain?"; then
      install_rustup
    else
      fail "Rust, Cargo, and rustup are required to continue."
    fi
  fi

  command -v cargo >/dev/null 2>&1 || fail "cargo is still missing after Rust setup."
  command -v rustc >/dev/null 2>&1 || fail "rustc is still missing after Rust setup."
  command -v rustup >/dev/null 2>&1 || fail "rustup is required to manage the Linux ARM64 target."

  if ! rustup target list --installed | grep -qx 'aarch64-unknown-linux-musl'; then
    warn "Rust target aarch64-unknown-linux-musl is missing."
    if confirm "Install the required Rust target automatically?"; then
      rustup target add aarch64-unknown-linux-musl || fail "The Rust Linux ARM64 target could not be installed."
    else
      fail "The Rust Linux ARM64 target is required to build vmproxy."
    fi
  fi

  ok "Rust: $(rustc --version)"
  ok "Cargo: $(cargo --version)"
  ok "Rust target: aarch64-unknown-linux-musl"
}

prepare_toolchain() {
  section "Build dependency audit"
  ensure_command_line_tools
  ensure_full_xcode
  ensure_homebrew
  ensure_brew_packages
  ensure_rust_toolchain

  section "Project preflight"
  "$REPO_ROOT/build/preflight.sh" || fail "Project preflight failed. Review the FAIL rows above."
  ok "Project preflight passed"
}

build_runtime() {
  section "Shared CLI runtime build"
  info "Initializing the pinned anylinuxfs submodule and building the vendored runtime"
  "$REPO_ROOT/setup.sh" || fail "The shared CLI runtime build did not complete."

  section "Runtime verification"
  "$REPO_ROOT/build/verify-vendor.sh" || fail "Vendored runtime verification failed."
  ok "Vendored binaries, signatures, architecture, quarantine state, and kernel pin verified"
}

package_cli() {
  section "CLI distribution"
  mkdir -p "$DIST_DIR" || fail "Could not create $DIST_DIR."
  tar -czf "$DIST_DIR/ntfsmac-cli.tar.gz" \
    -C "$REPO_ROOT" \
    install.sh vendor cli gui/Info.plist build/sources.lock build/lib/lock.sh || \
    fail "The CLI archive could not be created."
  tar -tzf "$DIST_DIR/ntfsmac-cli.tar.gz" >/dev/null || fail "The CLI archive failed its integrity check."
  ok "CLI archive created and readable"
  shasum -a 256 "$DIST_DIR/ntfsmac-cli.tar.gz"
}

package_gui() {
  section "Swift GUI tests"
  swift test --package-path "$REPO_ROOT" || fail "The Swift test suite failed."
  ok "Swift tests passed"

  section "App bundle packaging"
  "$REPO_ROOT/build/package-app.sh" || fail "The app bundle could not be created."

  local app="$DIST_DIR/ntfsmac.app"
  [[ -d "$app" ]] || fail "The expected app bundle is missing: $app"
  codesign --verify --deep --strict --verbose=2 "$app" || fail "The app bundle signature verification failed."
  file "$app/Contents/MacOS/ntfsmac-gui" | grep -q 'arm64' || fail "The GUI executable is not an arm64 Mach-O binary."
  ok "App bundle structure, architecture, and ad-hoc signature verified"

  section "DMG packaging"
  "$REPO_ROOT/build/make-dmg.sh" || fail "The DMG could not be created."

  local dmg="$DIST_DIR/ntfsmac.dmg"
  [[ -f "$dmg" ]] || fail "The expected DMG is missing: $dmg"
  hdiutil verify "$dmg" || fail "The DMG failed hdiutil verification."
  ok "DMG created and verified"
  shasum -a 256 "$dmg"
}

print_summary() {
  section "Build complete"
  case "$TARGET" in
    cli)
      ok "$DIST_DIR/ntfsmac-cli.tar.gz"
      ;;
    gui)
      ok "$DIST_DIR/ntfsmac.app"
      ok "$DIST_DIR/ntfsmac.dmg"
      ;;
    both)
      ok "$DIST_DIR/ntfsmac-cli.tar.gz"
      ok "$DIST_DIR/ntfsmac.app"
      ok "$DIST_DIR/ntfsmac.dmg"
      ;;
  esac
  echo ""
  printf '%sNothing was installed into /usr/local.%s\n' "$DIM" "$RESET"
  printf '%sOpen the DMG and drag ntfsmac.app to Applications when ready.%s\n' "$DIM" "$RESET"
}

main() {
  cd "$REPO_ROOT" || fail "Could not enter the repository directory."

  case "${1:-}" in
    "")
      INTERACTIVE=1
      choose_target
      ;;
    cli | gui | both)
      TARGET="$1"
      banner
      info "Selected target: $TARGET"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown target '$1'."
      ;;
  esac

  check_platform
  prepare_toolchain
  build_runtime

  case "$TARGET" in
    cli) package_cli ;;
    gui) package_gui ;;
    both)
      package_cli
      package_gui
      ;;
  esac

  print_summary
  pause_if_interactive
}

main "$@"
