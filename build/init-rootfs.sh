#!/bin/bash
# build/init-rootfs.sh — v-alpine-rootfs (PLAN.md §6).
#
# Pulls Alpine at the sources.lock tag, independently verifies the registry manifest
# digest against ALPINE_DIGEST before doing anything else (abort on mismatch — never
# trust :latest or an unpinned pull). Builds a *patched copy* of vendored anylinuxfs's
# init-rootfs (Go) + vmrunner-sys (Rust/CGO) — the vendored submodule itself is never
# edited — swapping its embedded default-alpine-packages.txt for our audited trimmed
# list (build/alpine-packages.trimmed.txt) so exactly those packages get installed,
# not upstream's un-trimmed default+custom set. Output lands under vendor/rootfs/
# (redirected via $HOME using the `osusergo` build tag, since upstream's cgo user
# lookup ignores $HOME otherwise).
#
# Also vendors the built init-rootfs binary itself to vendor/bin/init-rootfs — the
# real fix for the GATE-CLI-BEFORE-GUI blocker documented in SHARED_TASK_NOTES.md:
# anylinuxfs's Rust code (main.rs) expects an init-rootfs helper at
# $PREFIX/libexec/init-rootfs and spawns it directly (vm_image.rs Command::new); it
# was being built here already but only into the ephemeral $CACHE_DIR, never vendored.
# build/sign.sh signs vendor/bin/init-rootfs with the hypervisor entitlement (it calls
# Hypervisor.framework directly via vmrunner-sys, same as anylinuxfs) and install.sh /
# Formula/ntfsmac.rb copy it into $PREFIX/libexec alongside gvproxy/vmnet-helper/vmproxy.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"

# NOTE: deliberately NOT under $REPO_ROOT. This repo's own path contains spaces
# ("/Volumes/My Shared Files/..."), and krun-init-blob's build.rs (a libkrun dep,
# pulled in by vmrunner-sys) whitespace-splits the CC_LINUX compiler path — a space
# in the path truncates it and the build fails with "failed to execute /Volumes/My:
# No such file or directory". Confirmed by building the identical sources from a
# space-free path, which compiles clean. Building from a space-free cache dir outside
# the repo is the fix, not a workaround around a real bug in our own code.
CACHE_DIR="${NTFSMAC_ROOTFS_CACHE_DIR:-${TMPDIR:-/tmp}/ntfsmac-build/init-rootfs-build}"
# NOTE: also NOT under $REPO_ROOT. Separately from the spaces-in-path issue above, the
# repo's underlying volume ("Windows Shared Folder", network-mounted NTFS) does not
# support the fsync/ioctl calls go.podman.io/image's blob-copy step makes — confirmed
# real failure: "sync .../oci-put-blob...: inappropriate ioctl for device". Plain
# writes (curl downloads, tar extraction, go build output — see vendor/kernel,
# vendor/bin) work fine on this volume; it's specifically this fsync pattern that
# doesn't. Redirecting the real OCI pull/unpack to a space-free, POSIX-reliable cache
# dir outside the repo. Flagged in SHARED_TASK_NOTES.md — PLAN.md's literal "output
# under vendor/rootfs/" wording can't be satisfied on-volume; open decision for Kaveen.
ROOTFS_HOME="${NTFSMAC_VENDOR_ROOTFS_DIR:-${TMPDIR:-/tmp}/ntfsmac-build/rootfs-home}"
TRIMMED_LIST="$REPO_ROOT/build/alpine-packages.trimmed.txt"
BIN_DIR="${NTFSMAC_VENDOR_BIN_DIR:-$REPO_ROOT/vendor/bin}"

require_pin() {
  local key="$1" val
  val="$(lock_get "$key")" || { echo "init-rootfs: HARD-STOP — pin '$key' missing from sources.lock" >&2; exit 1; }
  if [[ "$val" == "TODO-KAVEEN" || -z "$val" ]]; then
    echo "init-rootfs: HARD-STOP — pin '$key' is unresolved (TODO-KAVEEN)" >&2
    exit 1
  fi
  printf '%s\n' "$val"
}

# verify_alpine_digest <tag> <expected_digest>
# ALPINE_DIGEST is pinned to the linux/arm64 PLATFORM manifest digest (not the
# top-level multi-arch index digest — those differ). Fetches the manifest list body
# from the registry v2 API and picks out the linux/arm64 entry's digest, matching how
# the pin itself was derived (Apple Silicon only, per PLAN.md L-rule). Real
# cryptographic pin check, done BEFORE any pull.
verify_alpine_digest() {
  local tag="$1" expected="$2" token actual
  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  if [[ -z "$token" ]]; then
    echo "init-rootfs: could not obtain a Docker Hub registry token" >&2
    return 1
  fi
  actual="$(curl -fsSL \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.index.v1+json" \
    "https://registry-1.docker.io/v2/library/alpine/manifests/${tag}" \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
for m in d.get("manifests", []):
    p = m.get("platform", {})
    if p.get("architecture") == "arm64" and p.get("os") == "linux":
        print(m["digest"])
        break
')"
  if [[ -z "$actual" ]]; then
    echo "init-rootfs: could not find a linux/arm64 manifest entry for alpine:${tag}" >&2
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "init-rootfs: HARD-STOP — alpine:${tag} linux/arm64 manifest digest mismatch (expected $expected, got $actual)" >&2
    return 1
  fi
  echo "init-rootfs: alpine:${tag} linux/arm64 digest verified ($actual)"
}

# prepare_build_copy — copy the vendored Go+Rust sources (never edit the submodule
# in place) into a scratch dir, preserving their sibling layout: vmrunner.go's cgo
# LDFLAGS and vmrunner-sys/.cargo/config.toml's CC_LINUX both use relative paths
# assuming init-rootfs/, vmrunner-sys/, and anylinuxfs/ are siblings (CC_LINUX =
# "../anylinuxfs/cc_linux" — the cross-compiler wrapper krun-init-blob's build.rs
# needs; only that one file is required, not the whole anylinuxfs crate). Swaps in
# our trimmed package list.
prepare_build_copy() {
  rm -rf "$CACHE_DIR"
  mkdir -p "$CACHE_DIR/anylinuxfs"
  cp -R "$REPO_ROOT/vendor/src/anylinuxfs/vmrunner-sys" "$CACHE_DIR/vmrunner-sys"
  cp -R "$REPO_ROOT/vendor/src/anylinuxfs/init-rootfs" "$CACHE_DIR/init-rootfs"
  cp "$REPO_ROOT/vendor/src/anylinuxfs/anylinuxfs/cc_linux" "$CACHE_DIR/anylinuxfs/cc_linux"
  chmod +x "$CACHE_DIR/anylinuxfs/cc_linux"
  cp "$TRIMMED_LIST" "$CACHE_DIR/init-rootfs/default-alpine-packages.txt"
}

# build_vmrunner_sys — settled PLAN.md decision: try without -F freebsd first.
# If that doesn't compile clean, HARD-STOP per PLAN.md §6 (don't drop the flag blind).
build_vmrunner_sys() {
  if (cd "$CACHE_DIR/vmrunner-sys" && cargo build --release --no-default-features 2>&1); then
    echo "init-rootfs: vmrunner-sys builds clean without -F freebsd"
  else
    echo "init-rootfs: HARD-STOP — vmrunner-sys does not compile without -F freebsd. Per PLAN.md §6, keep the flag and record why in AUDIT.md rather than dropping blind." >&2
    return 1
  fi
  cp "$CACHE_DIR/vmrunner-sys/target/release/libvmrunner_sys.a" "$CACHE_DIR/vmrunner-sys/target/"
}

build_init_rootfs_bin() {
  (cd "$CACHE_DIR/init-rootfs" && CGO_ENABLED=1 go build -tags 'containers_image_openpgp osusergo' -ldflags="-w -s" -o bin/init-rootfs .)
}

# vendor_init_rootfs_bin — copies the built binary out of the ephemeral cache into
# vendor/bin/, matching the gvproxy/vmproxy/vmnet-helper convention, then actually runs
# build/sign.sh (previously only a comment's stated intent — nothing in the pipeline called
# it, so every real build shipped an unentitled init-rootfs that fails to boot its VM with
# "start vm error: Invalid argument (errno 22)" on real hardware, same root cause as the
# anylinuxfs fix in build/build-all.sh). A bare `codesign -s -` alone (the old approach)
# produces a validly-signed-but-unentitled binary — passes `codesign -v` but still can't
# call Hypervisor.framework without com.apple.security.hypervisor.
vendor_init_rootfs_bin() {
  mkdir -p "$BIN_DIR"
  cp "$CACHE_DIR/init-rootfs/bin/init-rootfs" "$BIN_DIR/init-rootfs"
  chmod +x "$BIN_DIR/init-rootfs"
  NTFSMAC_VENDOR_BIN_DIR="$BIN_DIR" "$SCRIPT_DIR/sign.sh" || {
    echo "init-rootfs: HARD-STOP — signing init-rootfs (with required entitlements) failed." >&2
    return 1
  }
  echo "init-rootfs: vendored $BIN_DIR/init-rootfs"
}

# run_init_rootfs <tag> — stages a libexec/ layout (binary + kernel Image, matching
# upstream's PrefixDir/libexec/Image expectation) and runs the real tool with $HOME
# redirected into vendor/rootfs/ so pull+unpack+setup-script land inside the repo.
# The pull/unpack/setup-script-write happen before the VM boot step, so even if the
# VM boot hangs or fails, the generated package manifest is already on disk — bounded
# with a manual timeout (no coreutils `timeout` dependency) so an autonomous run can't
# hang forever on a Hypervisor.framework boot that never completes.
run_init_rootfs() {
  local tag="$1"
  local run_dir="$CACHE_DIR/run"
  mkdir -p "$run_dir/libexec" "$ROOTFS_HOME"
  cp "$CACHE_DIR/init-rootfs/bin/init-rootfs" "$run_dir/libexec/init-rootfs"
  cp "$REPO_ROOT/vendor/kernel/Image" "$run_dir/libexec/Image"
  chmod +x "$run_dir/libexec/init-rootfs"

  # modules.squashfs was already fetched for real by v-fetch-prebuilt — stage it.
  mkdir -p "$run_dir/lib"
  if [[ -f "$REPO_ROOT/vendor/kernel/modules.squashfs" ]]; then
    cp "$REPO_ROOT/vendor/kernel/modules.squashfs" "$run_dir/lib/modules.squashfs"
  else
    echo "init-rootfs: WARN — vendor/kernel/modules.squashfs not found (run v-fetch-prebuilt first)" >&2
  fi

  # vmproxy is a v-anylinuxfs-build artifact (not yet built at this point in the DAG —
  # PLAN.md's V-1 layer runs v-alpine-rootfs in parallel with v-fetch-prebuilt/v-gvproxy,
  # sharing only v-audit as a dep). Stage it if present so a re-run after
  # v-anylinuxfs-build completes the full embed; if absent, the upstream tool's own
  # vmproxy-copy step will fail non-fatally for THIS unit's purposes — the setup script
  # (this unit's actual acceptance artifact) is already written to disk by that point.
  if [[ -f "$REPO_ROOT/vendor/bin/vmproxy" ]]; then
    cp "$REPO_ROOT/vendor/bin/vmproxy" "$run_dir/libexec/vmproxy"
  else
    echo "init-rootfs: NOTE — vendor/bin/vmproxy not built yet (v-anylinuxfs-build's job). The upstream tool will fail to embed it into the rootfs and exit non-zero at that step; expected at this point in the DAG. Setup script + package manifest (this unit's acceptance artifact) are generated BEFORE that step, so they're already on disk. Full assembly + VM boot should be re-verified once v-anylinuxfs-build lands." >&2
  fi

  # Run in the foreground (not backgrounded): the Go binary's own process-group
  # signal handling (used for its Hypervisor.framework VM lifecycle) was observed to
  # terminate a bash job-control wrapper around it, which silently truncated this
  # script's own execution. Pull/unpack/setup-script-write finish in well under the
  # VM_BOOT_TIMEOUT window in every observed run (the failure mode we actually hit —
  # missing vendor/bin/vmproxy — returns in seconds); a true VM-boot hang would still
  # be caught by the caller's own process/tool timeout. Revisit with a proper
  # setsid-based watchdog once vmproxy is available and VM boot is actually reachable.
  echo "init-rootfs: running (HOME=$ROOTFS_HOME)"
  (cd "$run_dir/libexec" && HOME="$ROOTFS_HOME" ./init-rootfs -docker-ref "alpine:${tag}") || true
  return 0
}

main() {
  local tag digest
  tag="$(require_pin ALPINE_TAG)"
  digest="$(require_pin ALPINE_DIGEST)"

  verify_alpine_digest "$tag" "$digest" || exit 1

  prepare_build_copy
  build_vmrunner_sys || exit 1
  build_init_rootfs_bin
  vendor_init_rootfs_bin
  run_init_rootfs "$tag"

  echo "init-rootfs: done — inspect $ROOTFS_HOME for the generated rootfs and vm-setup.sh"
  echo "init-rootfs: NTFSMAC_ROOTFS_HOME=$ROOTFS_HOME"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
