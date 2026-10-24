#!/bin/bash
# build/build-all.sh — v-anylinuxfs-build (PLAN.md §6). Phase V's main assembly unit.
#
# Orchestrates the other build scripts, then builds anylinuxfs (macOS host CLI) and
# vmproxy (Linux guest agent, aarch64-unknown-linux-musl) WITHOUT -F freebsd, per
# PLAN.md's settled decision. Builds from a space-free cache dir outside the repo —
# same fix as build/init-rootfs.sh: this repo's path-with-spaces breaks
# krun-init-blob's build script (a libkrun dependency, pulled in by anylinuxfs
# directly). Runs cargo test for common-utils/anylinuxfs/vmproxy (vmproxy tests run
# on the HOST target, not the musl cross target — matches anylinuxfs's own
# run-rust-tests.sh: unit tests verify shared logic, not Linux-specific syscalls).
#
# If the freebsd-dropped build does NOT compile clean, PLAN.md says: keep the flag,
# record why in AUDIT.md, and HARD-STOP — never drop it blind.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck source=../cli/lib/runtime-alpine.sh
source "$REPO_ROOT/cli/lib/runtime-alpine.sh"
# shellcheck source=lib/patch-runtime-alpine.sh
source "$SCRIPT_DIR/lib/patch-runtime-alpine.sh"

# Same space-free-outside-repo fix as init-rootfs.sh — see build/AUDIT.md.
CACHE_DIR="${NTFSMAC_ANYLINUXFS_CACHE_DIR:-${TMPDIR:-/tmp}/ntfsmac-build/anylinuxfs-build}"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"

# rustup + the aarch64-unknown-linux-musl target are required for vmproxy's cross
# build; homebrew's plain rustc/cargo can't add cross targets. lld/util-linux are
# preflight-checked; add rustup's shims to PATH for this script's cargo invocations.
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"

prepare_build_copy() {
  mkdir -p "$CACHE_DIR"
  # Clear every copied source subtree, including share/etc. Leaving those two in place caused a
  # second build to reuse the prior run's already-patched Alpine config and nest a fresh copy under
  # it, making the deterministic marker check fail (and risking stale embedded defaults).
  for subtree in common-utils anylinuxfs vmproxy share etc init-rootfs; do
    rm -rf "${CACHE_DIR:?}/$subtree"
  done
  for crate in common-utils anylinuxfs vmproxy; do
    cp -R "$REPO_ROOT/vendor/src/anylinuxfs/$crate" "$CACHE_DIR/$crate"
  done

  # anylinuxfs/src/{cmd_mount,vm_image,main}.rs embed several sibling files via
  # include_str!("../../...") — real, found by a failed build attempt, not guessed.
  # share/ and etc/ start as exact submodule copies, then the runtime Alpine patch below replaces
  # only the audited default image/cache/version fields.
  # init-rootfs/default-alpine-packages.txt is anylinuxfs's OWN embedded copy of the
  # default package list (independent of the Go init-rootfs tool's embed) — swapped
  # for our trimmed list too, for consistency with build/init-rootfs.sh's audit.
  cp -R "$REPO_ROOT/vendor/src/anylinuxfs/share" "$CACHE_DIR/share"
  cp -R "$REPO_ROOT/vendor/src/anylinuxfs/etc" "$CACHE_DIR/etc"
  mkdir -p "$CACHE_DIR/init-rootfs"
  cp "$REPO_ROOT/build/alpine-packages.trimmed.txt" "$CACHE_DIR/init-rootfs/default-alpine-packages.txt"

  runtime_alpine_load || return 1
  patch_anylinuxfs_runtime_alpine "$CACHE_DIR" || return 1
  patch_vmproxy_mount_tmpfs
}

# patch_vmproxy_mount_tmpfs — real bug, reproduced on real hardware (not guessed):
# mount_tmpfs() in vmproxy/src/main.rs mounts tmpfs directly onto each path in
# tmpfs_dirs (which includes /etc/lvm/archive and /etc/lvm/backup) without ever
# creating the mount-point directory first. Alpine's lvm2 package does not ship
# those two subdirectories (lvm tools create them lazily on first use), so
# `mount -t tmpfs tmpfs /etc/lvm/archive` fails with "mount point does not exist",
# vmproxy bails, the guest VM exits 1, gvproxy tears down, and the host reports
# "NFS server not ready" / "anylinuxfs reported success but no NFS mount is
# present" — every mount attempt fails. Root-cause fix in the one shared function
# every tmpfs target already routes through (not a special case for lvm's two
# paths): mkdir -p the target before mounting. Patches the CACHE_DIR copy only —
# vendor/src/anylinuxfs (the submodule) is never edited, same rule init-rootfs.sh
# already follows for its packages-list swap. This is the single vmproxy binary
# both the CLI and the GUI (via the SMJobBless helper) invoke, so the fix covers
# both without separate GUI-side code.
patch_vmproxy_mount_tmpfs() {
  local target="$CACHE_DIR/vmproxy/src/main.rs"
  local marker='fn mount_tmpfs(paths: &[&str]) -> anyhow::Result<()> {
    for path in paths {'
  local replacement='fn mount_tmpfs(paths: &[&str]) -> anyhow::Result<()> {
    for path in paths {
        fs::create_dir_all(path)
            .with_context(|| format!("Failed to create mount point directory {path}"))?;
'

  python3 - "$target" "$marker" "$replacement" <<'PYEOF'
import sys
target, marker, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
with open(target, "r") as f:
    content = f.read()
if "fs::create_dir_all(path)" in content:
    print("build-all: vmproxy mount_tmpfs already patched, skipping")
    sys.exit(0)
if marker not in content:
    print(f"build-all: HARD-STOP — mount_tmpfs patch marker not found in {target} (upstream shape changed, update patch_vmproxy_mount_tmpfs)", file=sys.stderr)
    sys.exit(1)
content = content.replace(marker, replacement, 1)
with open(target, "w") as f:
    f.write(content)
print("build-all: patched vmproxy mount_tmpfs to mkdir -p each tmpfs target before mounting")
PYEOF
}

# PLAN.md §6's "-F freebsd is test-drop" decision, tested for real (not guessed) on
# every crate that has the flag:
#   - vmrunner-sys (no common_utils dep): compiles clean WITHOUT freebsd. Dropped —
#     see build/init-rootfs.sh, unaffected by this file.
#   - anylinuxfs: does NOT compile without it. Real errors —
#     Preferences::default_image()/images() and a mutable-borrow requirement are all
#     gated behind the feature and used unconditionally elsewhere. Per PLAN.md's own
#     pre-specified fallback for exactly this case: keep the flag, record why (done,
#     here and in AUDIT.md), don't force it off.
#   - vmproxy: its Cargo.toml doesn't set `default-features = false` on its
#     common_utils path dependency, so common_utils (which also defaults the flag on)
#     builds with freebsd enabled regardless of what flag vmproxy's own build uses —
#     forcing vmproxy's own flag off doesn't cleanly disable freebsd project-wide, it
#     just adds an inconsistency. Built WITH default features for consistency.
# None of this affects the REAL settled cuts, which stay cut regardless of this Cargo
# feature flag's on/off state: freebsd-bootstrap (Go tool) and vmproxy-bsd
# (aarch64-unknown-freebsd cross target) are never built; init-freebsd is never
# fetched. The feature flag only toggles some inactive (for our target) code paths
# compiling in, not any extra built artifact.
build_anylinuxfs() {
  # Static-link libblkid into anylinuxfs (tosbaha #1 fix). Without this, libblkid-rs-sys
  # resolves libblkid via the submodule's .cargo/config.toml, which hardcodes
  # PKG_CONFIG_PATH=/opt/homebrew/opt/util-linux/lib/pkgconfig → anylinuxfs dynamically
  # links /opt/homebrew/*/libblkid.1.dylib and aborts at launch on machines without
  # `brew install util-linux`. build-libblkid-static.sh produced a static libblkid.a +
  # libuuid.a + .pc files in $LIBBLKID_STAGE; point pkg-config at that stage and force
  # static archives. Two belt-and-suspenders measures, both required:
  #   1. Export PKG_CONFIG_PATH + PKG_CONFIG_ALL_STATIC=1 in the shell env. Cargo's
  #      .cargo/config.toml [env] defaults to force=false, so a shell-exported var wins
  #      over the submodule's hardcoded homebrew path.
  #   2. Neutralize the homebrew PKG_CONFIG_PATH line in the CACHE_DIR copy of
  #      .cargo/config.toml (the submodule itself is never edited — same rule as
  #      patch_vmproxy_mount_tmpfs). If the env override ever stopped winning, the build
  #      would silently fall back to the homebrew dylib; this removes that fallback path.
  local libblkid_stage="${NTFSMAC_LIBBLKID_STAGE:-${TMPDIR:-/tmp}/ntfsmac-build/libblkid-static}"
  if [[ ! -f "$libblkid_stage/lib/libblkid.a" ]]; then
    echo "build-all: HARD-STOP — static libblkid.a not found at $libblkid_stage (build-libblkid-static.sh should have run first in main(); check brew install util-linux + gettext)" >&2
    return 1
  fi
  local cargo_config="$CACHE_DIR/anylinuxfs/.cargo/config.toml"
  if [[ -f "$cargo_config" ]] && grep -q '/opt/homebrew/opt/util-linux' "$cargo_config"; then
    python3 - "$cargo_config" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, "r") as f:
    lines = f.readlines()
out = []
for line in lines:
    # Comment out the homebrew util-linux PKG_CONFIG_PATH so the build can't fall back to
    # the shared dylib if the shell-env override ever stops winning. Preserve the line
    # (commented) so the rationale stays readable in the patched copy.
    if "PKG_CONFIG_PATH" in line and "/opt/homebrew/opt/util-linux" in line and not line.lstrip().startswith("#"):
        out.append("# " + line.rstrip() + "  # neutralized by build-all.sh: static libblkid is used instead (tosbaha #1 fix)\n")
    else:
        out.append(line)
with open(path, "w") as f:
    f.writelines(out)
print("build-all: neutralized homebrew PKG_CONFIG_PATH in anylinuxfs .cargo/config.toml (static libblkid)")
PYEOF
  fi

  if ! (cd "$CACHE_DIR/anylinuxfs" && \
        PKG_CONFIG_PATH="$libblkid_stage/lib/pkgconfig" \
        PKG_CONFIG_ALL_STATIC=1 \
        cargo build --release 2>&1); then
    echo "build-all: HARD-STOP — anylinuxfs fails to compile even with default features (a real build error). See output above." >&2
    return 1
  fi
  mkdir -p "$BIN_DIR"
  cp "$CACHE_DIR/anylinuxfs/target/release/anylinuxfs" "$BIN_DIR/anylinuxfs"

  # Real bug, found against real hardware (not a build-all.bats gap): this used to be a bare
  # `codesign -s - --force` here, which produces a validly-signed-but-unentitled binary —
  # `install.sh`'s verify_signature() (`codesign -v`) passes on that just fine, since it only
  # checks signature validity, not which entitlements are embedded. Without
  # com.apple.security.hypervisor, Hypervisor.framework's vm_create fails with exactly
  # "start vm error: Invalid argument (errno 22)" on real Apple Silicon hardware — no VM/
  # nested-virtualization involved, confirmed on a bare Apple Silicon Mac. `build/sign.sh` is the
  # one script that actually embeds the required entitlements (build/entitlements/
  # anylinuxfs.entitlements); it existed but nothing in the build pipeline ever called it, so
  # every real build silently shipped an unbootable anylinuxfs. Calling it here — the one
  # script anyone actually runs — closes that gap instead of relying on a separate manual step.
  NTFSMAC_VENDOR_BIN_DIR="$BIN_DIR" "$SCRIPT_DIR/sign.sh" || {
    echo "build-all: HARD-STOP — signing anylinuxfs (with required entitlements) failed. See output above." >&2
    return 1
  }
}

build_vmproxy() {
  if ! (cd "$CACHE_DIR/vmproxy" && cargo build --release --target aarch64-unknown-linux-musl 2>&1); then
    echo "build-all: HARD-STOP — vmproxy fails to compile. See output above." >&2
    return 1
  fi
  mkdir -p "$BIN_DIR"
  cp "$CACHE_DIR/vmproxy/target/aarch64-unknown-linux-musl/release/vmproxy" "$BIN_DIR/vmproxy"
}

# run_tests — unit tests run on the HOST target for all three crates (matches
# anylinuxfs's own run-rust-tests.sh: cross-target unit tests would need a Linux
# runtime we don't have; shared logic is verified on host instead).
run_tests() {
  local host_target
  host_target="$(rustc -vV | sed -n 's/^host: //p')"

  echo "build-all: cargo test — common-utils"
  (cd "$CACHE_DIR/common-utils" && cargo test) || return 1

  # anylinuxfs's debug test build re-runs libblkid-rs-sys's build script, which needs
  # the SAME static-libblkid env as build_anylinuxfs (PKG_CONFIG_PATH at the staged .pc
  # + PKG_CONFIG_ALL_STATIC=1). Without this the test build fails with "Package blkid not
  # found" — the neutralized .cargo/config.toml removed the homebrew fallback deliberately,
  # so the only valid pkg-config path is our stage. vmproxy doesn't link libblkid, so it
  # needs no special env.
  local libblkid_stage="${NTFSMAC_LIBBLKID_STAGE:-${TMPDIR:-/tmp}/ntfsmac-build/libblkid-static}"
  echo "build-all: cargo test — anylinuxfs"
  (cd "$CACHE_DIR/anylinuxfs" && \
    PKG_CONFIG_PATH="$libblkid_stage/lib/pkgconfig" \
    PKG_CONFIG_ALL_STATIC=1 \
    cargo test) || return 1

  echo "build-all: cargo test — vmproxy (host target: $host_target)"
  (cd "$CACHE_DIR/vmproxy" && cargo test --target "$host_target") || return 1
}

main() {
  echo "build-all: orchestrating fetch-prebuilt, build-gvproxy, init-rootfs first"
  "$REPO_ROOT/build/fetch-prebuilt.sh" || { echo "build-all: HARD-STOP — fetch-prebuilt.sh failed" >&2; exit 1; }
  "$REPO_ROOT/build/build-gvproxy.sh" || { echo "build-all: HARD-STOP — build-gvproxy.sh failed" >&2; exit 1; }
  "$REPO_ROOT/build/init-rootfs.sh" || true  # non-fatal: see build/AUDIT.md — vmproxy-embed gap resolves after this unit builds vmproxy

  prepare_build_copy || exit 1

  # Stage Homebrew's static libblkid.a anylinuxfs links against (tosbaha #1 fix). Must run
  # before build_anylinuxfs — it produces the dylib-free stage (libblkid.a + libuuid.a +
  # .pc) that build_anylinuxfs points PKG_CONFIG_PATH at. Idempotent (rm -rf stage on every
  # run). No source build, no fetch — consumes Homebrew's already-built static archives.
  "$REPO_ROOT/build/build-libblkid-static.sh" || { echo "build-all: HARD-STOP — build-libblkid-static.sh failed" >&2; exit 1; }

  build_anylinuxfs || exit 1
  build_vmproxy || exit 1
  run_tests || exit 1

  echo "build-all: re-running init-rootfs.sh now that vendor/bin/vmproxy exists, to complete rootfs assembly"
  "$REPO_ROOT/build/init-rootfs.sh" || echo "build-all: WARN — init-rootfs.sh re-run (with vmproxy staged) did not complete cleanly; inspect its output" >&2

  echo "build-all: done — $BIN_DIR/anylinuxfs, $BIN_DIR/vmproxy"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
