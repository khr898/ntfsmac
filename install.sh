#!/bin/bash
# install.sh — 2-install-sh (PLAN.md §6, L4, L7, L10).
#
# Installs the CLI + vendored binaries from this repo tree into a stable prefix.
# Refuses non-arm64 (L7). Runtime files are staged to a fresh inode, checked when Mach-O, and
# atomically renamed into place. This avoids executing a partially overwritten binary and avoids
# macOS retaining stale code-signature state on an in-place update. It does not change Gatekeeper,
# SIP, provenance, or any system-wide policy. Verifies anylinuxfs's ad-hoc signature before
# enabling it (build-all.sh already `codesign -s -`
# signs anylinuxfs; gvproxy/vmnet-helper/vmproxy get formally signed by 2-signing, the
# next unit — not duplicated here). NTFSMAC_REPO defaults to khr898/ntfsmac (L10 — the
# repo owner placeholder must never appear literally in this file).
set -uo pipefail

NTFSMAC_REPO="${NTFSMAC_REPO:-khr898/ntfsmac}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PREFIX="${NTFSMAC_PREFIX:-/usr/local/ntfsmac}"
# Already-on-PATH convenience symlink (`ntfsmac` works with zero manual PATH setup) — a plain
# dir, never a shell-rc edit, so it works in every new shell immediately, unlike appending to
# .zshrc/.bash_profile which only takes effect after a reload and guesses at the user's shell.
PATH_SYMLINK="${NTFSMAC_PATH_SYMLINK:-/usr/local/bin/ntfsmac}"

refuse_non_arm64() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    echo "install.sh: HARD-STOP — ntfsmac requires Apple Silicon (arm64), detected '$arch' (L7)" >&2
    return 1
  fi
}

verify_signature() {
  local bin="$1"
  if ! codesign -v "$bin" >/dev/null 2>&1; then
    echo "install.sh: HARD-STOP — $bin failed signature verification, refusing to enable" >&2
    return 1
  fi
}

strip_quarantine() {
  xattr -d com.apple.quarantine "$1" >/dev/null 2>&1 || true
}

# Never overwrite a running/signed executable in place. On macOS 26.6.1 that left the old vnode's
# signature state attached to new bytes: `codesign --verify` passed, but the kernel logged
# `load code signature error 2` and killed the process. A same-directory rename is atomic and
# gives the installed payload a fresh inode. Mach-O payloads are verified before publication;
# the guest-only Linux vmproxy is copied through the same atomic path but is not code-signed.
install_runtime_file() {
  local source="$1" destination="$2" staged
  staged="$(mktemp "${destination}.new.XXXXXX")" || return 1
  if ! /bin/cp -X "$source" "$staged"; then
    rm -f "$staged"
    return 1
  fi
  chmod 755 "$staged" || { rm -f "$staged"; return 1; }
  strip_quarantine "$staged"
  if /usr/bin/file "$staged" | grep -q 'Mach-O'; then
    verify_signature "$staged" || { rm -f "$staged"; return 1; }
  fi
  /bin/mv -f "$staged" "$destination" || { rm -f "$staged"; return 1; }
}

install_binaries() {
  mkdir -p "$PREFIX/bin" "$PREFIX/libexec"

  install_runtime_file "$REPO_ROOT/vendor/bin/anylinuxfs" "$PREFIX/bin/anylinuxfs" || return 1

  local bin
  for bin in gvproxy vmnet-helper vmproxy init-rootfs; do
    [[ -f "$REPO_ROOT/vendor/bin/$bin" ]] || continue
    install_runtime_file "$REPO_ROOT/vendor/bin/$bin" "$PREFIX/libexec/$bin" || return 1
  done

  local kf
  for kf in Image Image-4K; do
    if [[ -f "$REPO_ROOT/vendor/kernel/$kf" ]]; then
      cp "$REPO_ROOT/vendor/kernel/$kf" "$PREFIX/libexec/$kf" || return 1
    fi
  done

  # modules.squashfs goes in $PREFIX/lib, not $PREFIX/libexec: init-rootfs's own
  # copyLinuxModules() reads it from prefixDir/lib/modules.squashfs (real path, read
  # from vendor/src/anylinuxfs/init-rootfs/main.go — confirmed the only consumer).
  if [[ -f "$REPO_ROOT/vendor/kernel/modules.squashfs" ]]; then
    mkdir -p "$PREFIX/lib"
    cp "$REPO_ROOT/vendor/kernel/modules.squashfs" "$PREFIX/lib/modules.squashfs" || return 1
  fi
}

install_cli() {
  mkdir -p "$PREFIX/libexec/ntfsmac/commands" "$PREFIX/libexec/ntfsmac/lib" "$PREFIX/libexec/ntfsmac/pf"
  cp "$REPO_ROOT"/cli/commands/*.sh "$PREFIX/libexec/ntfsmac/commands/" || return 1
  cp "$REPO_ROOT"/cli/lib/*.sh "$PREFIX/libexec/ntfsmac/lib/" || return 1
  cp "$REPO_ROOT"/cli/pf/*.tmpl "$PREFIX/libexec/ntfsmac/pf/" || return 1

  # gui/Info.plist is the single product-version source. Keep an exact snapshot beside the
  # installed resolver so CLI-only/Homebrew installs do not depend on an app bundle or duplicate
  # release/build constants in shell code.
  if [[ ! -r "$REPO_ROOT/gui/Info.plist" ]]; then
    echo "install.sh: HARD-STOP — canonical product metadata missing: $REPO_ROOT/gui/Info.plist" >&2
    return 1
  fi
  cp "$REPO_ROOT/gui/Info.plist" "$PREFIX/libexec/ntfsmac/lib/product-info.plist" || return 1

  # Copy lock.sh and sources.lock so ntfsmac diagnose can verify the kernel pin on installed
  # systems — best-effort only: these are diagnostic-only and their absence must never prevent
  # the core CLI (mount/unmount) from installing. The files may be absent from older app bundles
  # that were packaged before build/package-app.sh staged them into cli-src/.
  if [[ -f "$REPO_ROOT/build/lib/lock.sh" ]]; then
    cp "$REPO_ROOT/build/lib/lock.sh" "$PREFIX/libexec/ntfsmac/lib/lock.sh" 2>/dev/null || \
      echo "install.sh: WARN — could not copy build/lib/lock.sh (diagnose kernel-pin check will be unavailable)" >&2
  fi
  if [[ -f "$REPO_ROOT/build/sources.lock" ]]; then
    cp "$REPO_ROOT/build/sources.lock" "$PREFIX/libexec/ntfsmac/sources.lock" 2>/dev/null || \
      echo "install.sh: WARN — could not copy build/sources.lock (diagnose kernel-pin check will be unavailable)" >&2
  fi

  chmod +x "$PREFIX"/libexec/ntfsmac/commands/*.sh || return 1
  [[ -f "$PREFIX/libexec/ntfsmac/lib/lock.sh" ]] && chmod +x "$PREFIX/libexec/ntfsmac/lib/lock.sh"

  local f
  for f in "$PREFIX"/libexec/ntfsmac/commands/*.sh "$PREFIX"/libexec/ntfsmac/lib/*.sh; do
    strip_quarantine "$f"
  done

  cat > "$PREFIX/bin/ntfsmac" <<DISPATCH
#!/bin/bash
# Generated by install.sh — dispatches to \$PREFIX/libexec/ntfsmac/commands/*.sh.
set -u
LIBEXEC="$PREFIX/libexec/ntfsmac"

print_help() {
  cat <<'HELP'
usage: ntfsmac <command> [args...]

commands:
  mount [device] [mount_point]       Mount an NTFS / ext drive (omit device to pick from a list).
                                      Flags: --preserve-private-relay, --fs-driver ntfs-3g|ntfs3, --read-only
  unmount [device|mount_point]       Unmount a drive (omit to pick from active mounts)
  diagnose [--json]                  Read-only health check
  uninstall [--force] [--keep-cache] Remove the CLI, vendored deps, and the GUI helper
  help                               Show this message

'ntfsmac uninstall --help' shows uninstall's flags in detail.
HELP
}

sub="\${1:-}"
[[ \$# -gt 0 ]] && shift
case "\$sub" in
  mount) exec "\$LIBEXEC/commands/mount.sh" "\$@" ;;
  unmount) exec "\$LIBEXEC/commands/unmount.sh" "\$@" ;;
  diagnose) exec "\$LIBEXEC/commands/diagnose.sh" "\$@" ;;
  uninstall) exec "\$LIBEXEC/commands/uninstall.sh" "\$@" ;;
  help | --help | -h | "") print_help; exit 0 ;;
  *) echo "ntfsmac: unknown command '\$sub'" >&2; print_help >&2; exit 1 ;;
esac
DISPATCH
  chmod +x "$PREFIX/bin/ntfsmac" || return 1
  strip_quarantine "$PREFIX/bin/ntfsmac"
}

link_into_path() {
  local symlink_dir
  symlink_dir="$(dirname "$PATH_SYMLINK")"
  mkdir -p "$symlink_dir" 2>/dev/null
  if ln -sf "$PREFIX/bin/ntfsmac" "$PATH_SYMLINK" 2>/dev/null; then
    echo "install.sh: linked $PATH_SYMLINK -> $PREFIX/bin/ntfsmac (already on PATH)"
  else
    echo "install.sh: WARN — could not create $PATH_SYMLINK, add $PREFIX/bin to PATH manually" >&2
  fi
}

resolve_target_user() {
  if [[ -n "${NTFSMAC_TARGET_USER:-}" ]]; then
    printf '%s\n' "$NTFSMAC_TARGET_USER"
    return 0
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  local console_user
  console_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [[ -n "$console_user" && "$console_user" != "root" ]]; then
    printf '%s\n' "$console_user"
    return 0
  fi
  id -un 2>/dev/null || whoami 2>/dev/null || echo "root"
}

resolve_target_home() {
  local target_user="${1:-}"
  if [[ -n "${NTFSMAC_TARGET_HOME:-}" ]]; then
    printf '%s\n' "$NTFSMAC_TARGET_HOME"
    return 0
  fi
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    local home_dir
    home_dir="$(dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory:[[:space:]]*//p' || true)"
    if [[ -n "$home_dir" && -d "$home_dir" ]]; then
      printf '%s\n' "$home_dir"
      return 0
    fi
    if [[ -d "/Users/$target_user" ]]; then
      printf '/Users/%s\n' "$target_user"
      return 0
    fi
  fi
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  cd ~ 2>/dev/null && pwd || echo "/var/root"
}

wipe_anylinuxfs_store() {
  local target_home="${1:-}"
  if mount -t nfs 2>/dev/null | grep -q .; then
    echo "install.sh: WARN — active NFS mount detected; refusing to wipe anylinuxfs store to prevent corruption" >&2
    return 0
  fi

  if [[ -n "$target_home" && -d "$target_home/.anylinuxfs" ]]; then
    rm -rf "$target_home"/.anylinuxfs/alpine-* "$target_home"/.anylinuxfs/*.preserved-* 2>/dev/null || true
  fi

  if [[ -d "/var/root/.anylinuxfs" ]]; then
    rm -rf "/var/root/.anylinuxfs" 2>/dev/null || true
  fi
  return 0
}

save_proxy_to_config() {
  local target_home="${1:-}"
  local proxy_url="${2:-}"
  [[ -z "$target_home" || -z "$proxy_url" ]] && return 0

  local conf_dir="$target_home/.anylinuxfs"
  local conf_file="$conf_dir/config.toml"
  mkdir -p "$conf_dir"

  if [[ ! -f "$conf_file" ]]; then
    printf '[network]\nproxy = "%s"\n' "$proxy_url" > "$conf_file"
  else
    if grep -q '^[[:space:]]*\[network\]' "$conf_file"; then
      if grep -q '^[[:space:]]*proxy[[:space:]]*=' "$conf_file"; then
        sed -i '' -e "s|^[[:space:]]*proxy[[:space:]]*=.*|proxy = \"$proxy_url\"|" "$conf_file" 2>/dev/null || \
        sed -i -e "s|^[[:space:]]*proxy[[:space:]]*=.*|proxy = \"$proxy_url\"|" "$conf_file"
      else
        awk -v p="$proxy_url" '
          /^[[:space:]]*\[network\]/ { print; print "proxy = \"" p "\""; next }
          { print }
        ' "$conf_file" > "$conf_file.tmp" && mv "$conf_file.tmp" "$conf_file"
      fi
    else
      printf '\n[network]\nproxy = "%s"\n' "$proxy_url" >> "$conf_file"
    fi
  fi
}

setup_alpine_environment() {
  if [[ "${NTFSMAC_SKIP_RUNTIME_INIT:-}" == "1" ]]; then
    return 0
  fi

  local target_user="${1:-}"
  local target_home="${2:-}"
  local target_proxy="${3:-}"

  echo "install.sh: setting up microVM environment and installing Alpine runtime (takes ~1-2 min)..."

  local target_uid target_gid
  target_uid="$(id -u "$target_user" 2>/dev/null || echo "501")"
  target_gid="$(id -g "$target_user" 2>/dev/null || echo "20")"

  if [[ -z "$target_proxy" ]]; then
    if [[ -f "$target_home/.anylinuxfs/config.toml" ]]; then
      target_proxy="$(awk -F'=' '
        /^\[network\]/ { in_net=1; in_alp=0; next }
        /^\[alpine\]/ { in_alp=1; in_net=0; next }
        /^\[/ { in_net=0; in_alp=0; next }
        (in_net || in_alp) && /^[[:space:]]*proxy[[:space:]]*=/ {
          val = $2
          gsub(/^[[:space:]]*["\047]|["\047][[:space:]]*$/, "", val)
          print val
          exit
        }
      ' "$target_home/.anylinuxfs/config.toml" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$target_proxy" ]]; then
    target_proxy="${NTFSMAC_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
  fi

  local anylinuxfs_bin="${NTFSMAC_ANYLINUXFS_BIN:-$PREFIX/bin/anylinuxfs}"
  if [[ -x "$anylinuxfs_bin" ]]; then
    SUDO_USER="$target_user" \
    SUDO_UID="$target_uid" \
    SUDO_GID="$target_gid" \
    HOME="$target_home" \
    HTTP_PROXY="${target_proxy:-${HTTP_PROXY:-}}" \
    HTTPS_PROXY="${target_proxy:-${HTTPS_PROXY:-}}" \
    http_proxy="${target_proxy:-${http_proxy:-}}" \
    https_proxy="${target_proxy:-${https_proxy:-}}" \
    NTFSMAC_PROXY="${target_proxy:-${NTFSMAC_PROXY:-}}" \
    "$anylinuxfs_bin" init || {
      echo "install.sh: WARN — anylinuxfs init encountered an issue (runtime will initialize on first mount)" >&2
      return 0
    }
  fi

  if [[ -n "$target_home" && -d "$target_home/.anylinuxfs" ]]; then
    chown -R "$target_user" "$target_home/.anylinuxfs" 2>/dev/null || true
  fi

  echo "install.sh: environment setup complete — Alpine Linux runtime is ready."
}

main() {
  # Self-elevate only if actually needed — mirrors mount.sh/uninstall.sh's own pattern, but
  # gated on real writability so a machine where $PREFIX/$PATH_SYMLINK's parent is already
  # user-writable (common: a prior Homebrew install commonly chowns /usr/local) never gets a
  # needless password prompt, and so the test suite (which always points both at a scratch
  # dir) never triggers it either.
  if [[ "${NTFSMAC_SKIP_ROOT_CHECK:-}" != "1" && $EUID -ne 0 ]]; then
    local prefix_parent symlink_parent needs_root=""
    prefix_parent="$(dirname "$PREFIX")"
    [[ -w "$PREFIX" || ( ! -e "$PREFIX" && -w "$prefix_parent" ) ]] || needs_root=1
    symlink_parent="$(dirname "$PATH_SYMLINK")"
    [[ -w "$symlink_parent" || ! -e "$symlink_parent" ]] || needs_root=1
    [[ -n "$needs_root" ]] && exec sudo \
      HTTP_PROXY="${HTTP_PROXY:-}" \
      HTTPS_PROXY="${HTTPS_PROXY:-}" \
      ALL_PROXY="${ALL_PROXY:-}" \
      http_proxy="${http_proxy:-}" \
      https_proxy="${https_proxy:-}" \
      all_proxy="${all_proxy:-}" \
      NTFSMAC_PROXY="${NTFSMAC_PROXY:-}" \
      "$0" "$@"
  fi

  # `--no-path-link`: the GUI's privileged helper runs this same script (already root, via
  # `HelperService.stageCLI`) to stage the CLI in the background on first helper install — per
  # explicit product decision, a GUI-only install must not expose `ntfsmac` on a Terminal PATH
  # the user never asked for. Standalone/tap installs (no flag) keep the symlink unchanged.
  local skip_link=""
  local cli_proxy=""
  local i=1
  while [[ $i -le $# ]]; do
    local arg="${!i}"
    case "$arg" in
      --no-path-link)
        skip_link=1
        ;;
      --proxy)
        i=$((i + 1))
        cli_proxy="${!i:-}"
        ;;
      --proxy=*)
        cli_proxy="${arg#--proxy=}"
        ;;
    esac
    i=$((i + 1))
  done

  refuse_non_arm64 || exit 1
  install_binaries || exit 1
  install_cli || exit 1
  [[ -z "$skip_link" ]] && link_into_path

  local target_user target_home
  target_user="$(resolve_target_user)"
  target_home="$(resolve_target_home "$target_user")"

  if [[ -n "$cli_proxy" ]]; then
    save_proxy_to_config "$target_home" "$cli_proxy"
    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
      chown -R "$target_user" "$target_home/.anylinuxfs" 2>/dev/null || true
    fi
  fi

  wipe_anylinuxfs_store "$target_home"
  setup_alpine_environment "$target_user" "$target_home" "$cli_proxy"

  echo "install.sh: installed to $PREFIX (NTFSMAC_REPO=$NTFSMAC_REPO)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
