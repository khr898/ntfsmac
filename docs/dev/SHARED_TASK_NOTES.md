# SHARED_TASK_NOTES

Cross-iteration memory for the autonomous ntfsmac build (PLAN.md §7.5). Read this file first,
every session. Updated at the end of every unit.

## GATES

- **GATE-CLI-BEFORE-GUI**: **still not fired.** Kaveen's decision (2026-07-10, this
  session): option (a) from below — build+vendor the real `init-rootfs` Go helper.
  Done: `build/init-rootfs.sh` already built this binary (vmrunner-sys + `go build`)
  into an ephemeral `$CACHE_DIR`, just never copied it anywhere durable — added
  `vendor_init_rootfs_bin()`, called from `main()`, which copies it to
  `vendor/bin/init-rootfs` (same convention as gvproxy/vmproxy/vmnet-helper: vendored
  flat in `vendor/bin/`, then `install.sh`/`Formula/ntfsmac.rb` sort it into
  `$PREFIX/libexec/init-rootfs`, matching anylinuxfs's own `main.rs`
  `libexec_path.join("init-rootfs")` expectation). Wired into `build/sign.sh` +
  `build/verify-signature.sh` (init-rootfs gets the **same hypervisor entitlement** as
  anylinuxfs — it calls `Hypervisor.framework` directly via `vmrunner-sys`/cgo, real
  requirement confirmed by reading `vmrunner.go`'s `#cgo darwin LDFLAGS: -framework
  Hypervisor`, and matches upstream's own `build-app.sh` which signs it identically) and
  `build/verify-vendor.sh`. Real build ran clean: `vmrunner-sys` compiles without
  `-F freebsd` (19.6s release build), real Alpine pull+unpack+setup-script-write+
  vmproxy-embed all succeeded, binary vendored, signed, entitlement verified present.
  **Found + root-caused a real, pre-existing bug along the way** (unrelated to this
  unit's own diff, surfaced by running the full test suite): `verify-vendor.sh`'s
  `check_anylinuxfs_runs()` unconditionally executed `$BIN_DIR/anylinuxfs --version`
  even when that binary carried `com.apple.quarantine` — the quarantine-fixture test
  deliberately sets that xattr, and executing a quarantined ad-hoc/entitled Mach-O
  triggers a Gatekeeper assessment that hangs indefinitely in this environment (real
  hang, `sample`-profiled: stuck in `_dyld_start` for 11+ minutes). `install.sh` was
  never affected (always strips quarantine before any exec); fixed by making
  `check_anylinuxfs_runs()` refuse to exec a quarantined binary instead of trying.
  Also fixed a rubocop `Line is too long` real `brew audit --strict` failure in
  `Formula/ntfsmac.rb`'s `post_install` after adding init-rootfs to its quarantine-strip
  list. All touched suites green for real: `rootfs.bats` 4/4, `signing.bats` 9/9,
  `install.bats` 6/6, `verify-vendor.bats` 5/5, `formula.bats` 7/7.
  **Ran the actual GATE check this session — `install.sh` to a clean prefix, then the
  installed `anylinuxfs list`.** Found + fixed one more real bug on the way: `install.sh`
  and `Formula/ntfsmac.rb` were putting `modules.squashfs` in `$PREFIX/libexec/`, but
  init-rootfs's own `copyLinuxModules()` (main.go) reads it from `$PREFIX/lib/` — a
  different directory (real path, confirmed by reading the vendored source; grepped for
  every reference to `modules.squashfs` in the Rust/Go tree first — it's the only
  consumer). Fixed: `install.sh` now stages it at `$PREFIX/lib/modules.squashfs`;
  `Formula/ntfsmac.rb` uses `lib.install` instead of bundling it into the `libexec.install
  Dir[...]` glob. `install.bats`/`formula.bats` updated and green (13/13) for real. After
  that fix, `anylinuxfs list` gets all the way through image pull/unpack/setup-script/
  vmproxy-embed/modules-embed and reaches the **real VM boot call** —
  `vmrunner.Run()` → `hv_vm_create` — which fails: `start vm error: Invalid argument
  (errno 22)`.
  **Root-caused, not a code bug: `sysctl kern.hv_support` returns `0` in this Claude
  Code exec sandbox** — Hypervisor.framework has zero hardware virtualization support
  available in this execution context, independent of code signing, entitlements, or
  anything in this repo. Confirmed the entitlement itself is genuinely present and intact
  on the installed binary at the moment of failure (`codesign -d --entitlements` on
  `$PREFIX/libexec/init-rootfs` shows `com.apple.security.hypervisor`, verified right
  before the failing run). This means **the actual live VM boot cannot be verified from
  inside this agent's sandboxed Bash tool, on this real M3 Pro Mac or otherwise** — it
  needs to be run in Kaveen's own real Terminal, outside the coding-agent sandbox, where
  `kern.hv_support` should read `1`. Repro for that real run:
  `NTFSMAC_PREFIX=$(mktemp -d); export NTFSMAC_PREFIX; ./install.sh &&
  $NTFSMAC_PREFIX/bin/anylinuxfs list`. **GATE-CLI-BEFORE-GUI still has
  not fired** — everything up to the real VM boot is now verified working; the VM boot
  step itself is the one remaining unknown, and it's a Kaveen-in-Terminal task, not
  further autonomous work here. Do not start Phase 3 until Kaveen confirms that repro
  either succeeds or reports a *different* real error from inside a real Terminal.
  **2026-07-10, later same day — real repro attempt, found a bug in the repro line itself
  (not a code bug):** the originally-documented one-liner
  (`NTFSMAC_PREFIX=$(mktemp -d) ./install.sh && $NTFSMAC_PREFIX/bin/anylinuxfs list`)
  is broken shell usage — `VAR=val cmd1 && cmd2` scopes `VAR` to `cmd1`'s environment
  only in bash/zsh; it is never exported to the shell, so `cmd2` sees `$NTFSMAC_PREFIX`
  as empty. Kaveen hit exactly this: `zsh: no such file or directory: /bin/anylinuxfs`.
  Also tried `$NTFSMAC_PREFIX/bin/ntfsmac list` — not a real bug either, `ntfsmac` is the
  thin dispatcher and only wires `mount`/`unmount`/`diagnose` (per `2-install-sh`); `list`
  was never in its scope, the repro must call `anylinuxfs list` directly. Repro line above
  corrected to `export` the var first. **GATE-CLI-BEFORE-GUI: real VM boot still
  unverified** — this attempt never reached `hv_vm_create`. **2026-07-10, Kaveen decision:
  proceeding into Phase 3 (GUI) anyway, gate deliberately overridden — not resolved, a
  conscious deviation from PLAN.md §4's build-order rule.** Re-run the corrected repro
  when convenient; if it still fails with `Invalid argument (errno 22)` /
  `kern.hv_support=0`, that's environment-specific (sandbox), not this repo's code.
- **Phase 1 (pf/route hardening)**: deferrable, non-blocking. Currently deferred — will be
  called out explicitly in release notes if CLI ships without it.

## PROGRESS

### Phase 0 — Scaffolding
- [x] `p0-repo-layout` — dirs + README/.gitignore/LICENSE created.
- [x] `p0-sources-lock` — all pins resolved from real upstream (GitHub/Docker Hub APIs); `lock.bats` green.
- [x] `p0-toolchain-preflight` — `build/preflight.sh` + `preflight.bats` green (3/3).
- [x] `p0-submodule-anylinuxfs` — added at `vendor/src/anylinuxfs`, pinned to ANYLINUXFS_COMMIT; `submodule.bats` green.
- [x] `p0-ci` — `.github/workflows/ci.yml` (macos-14/arm64, shellcheck+bats active, cargo/swift
      jobs gated `if: false` until Phase V/3 land) + `tests/run-all.sh`; 11/11 bats green,
      shellcheck clean.

**Phase 0 complete.** `NTFSMAC_PHASE_COMPLETE:phase-0`

### Phase V — Vendor
- [x] `v-audit` — `build/AUDIT.md` + `alpine-packages.trimmed.txt` (13→7 packages), evidence-cited
      from real submodule source (file:line). `audit.bats` 6/6 green. See DECISIONS below for the
      cryptsetup/BitLocker feature cut and the libkrun pin-method correction.
- [x] `v-fetch-prebuilt` — `build/fetch-prebuilt.sh` downloads libkrunfw Images+modules.squashfs
      (nohajc fork) and vmnet-helper (nirs), verifies sha256 before unpack, aborts+deletes on
      mismatch. Ran for real against live releases — all 3 sha256 pins in `sources.lock` verified
      correct, idempotent re-run confirmed. `vendor/bin/vmnet-helper` is a universal binary
      (x86_64+arm64) — fine, arm64 slice present. `fetch-prebuilt.bats` 5/5 green (no network in
      tests — exercises `verify_or_abort`/`require_pin` with local fixtures per PLAN.md's
      wrong-checksum acceptance line).
- [x] `v-gvproxy` — `build/build-gvproxy.sh` clones `containers/gvisor-tap-vsock` to
      gitignored `build/.cache/`, checks out `GVPROXY_COMMIT`, verifies HEAD matches the pin,
      builds `./cmd/gvproxy` → `vendor/bin/gvproxy`. Cross-checks tag against anylinuxfs's own
      `download-dependencies.sh` GVPROXY_VERSION, warns (non-fatal) on drift — none found, both
      pin v0.8.9. Ran for real: commit `9cfc86f66679ef0feed0f20ba1df558fe2bef5c6` confirmed,
      binary built and verified arm64 + executable. `gvproxy.bats` 3/3 green.
- [x] `v-alpine-rootfs` — `build/init-rootfs.sh`. Real, verified: Alpine
      `library/alpine:3.23.5` linux/arm64 manifest digest independently checked
      against `ALPINE_DIGEST` via Docker Hub registry API before pulling (real
      network call, matches). Pulled + unpacked for real. Generated `vm-setup.sh`
      confirmed byte-for-byte: `apk --update --no-cache add bash blkid cryptsetup
      lsblk mount nfs-utils ntfs-3g squashfs-tools` — exactly our trimmed list, not
      upstream's un-trimmed 13. `rootfs.bats` 3/3 green (real run).
      **Two real environment bugs found + fixed, full detail in `build/AUDIT.md`:**
      (1) this repo's path contains spaces, which breaks `krun-init-blob`'s build
      script (whitespace-splits `CC_LINUX`) — any Cargo build touching `libkrun`
      from this repo must build from a space-free cache dir outside the repo;
      **`v-anylinuxfs-build` will hit this too, build from `$TMPDIR` not
      `$REPO_ROOT`.** (2) this repo's volume ("Windows Shared Folder", network-mounted)
      doesn't support the fsync/ioctl calls `go.podman.io/image`'s blob-copy needs —
      same class of issue as the earlier `graphify-out/graph.json` git-add failure.
      Real output therefore lands outside the repo (`$TMPDIR/ntfsmac-build/...`),
      not literally at `vendor/rootfs/` as PLAN.md's Do clause says — **flagging for
      Kaveen**, this volume constraint may need a project-wide decision (e.g. a
      documented dev-build-cache-dir convention) rather than a per-unit workaround.
      New toolchain dep `lld` (separate Homebrew formula from `llvm`) installed and
      added to `preflight.sh`. **Real DAG gap found:** the vendored tool's full flow
      needs `vendor/bin/vmproxy` (a `v-anylinuxfs-build` artifact) to embed into the
      rootfs and boot a VM to actually run `apk add` — PLAN.md's V-1 layer doesn't
      have that dependency. `build/init-rootfs.sh` stages `vmproxy`/`modules.squashfs`
      if present and degrades gracefully (documented, non-fatal) if not; **re-run
      after `v-anylinuxfs-build` lands** to complete and verify the real VM-boot +
      package-install step, which is genuinely unverified so far.
- [x] `v-anylinuxfs-build` — `build/build-all.sh` builds `anylinuxfs` (macOS host, arm64) +
      `vmproxy` (Linux guest, aarch64-unknown-linux-musl) from a space-free cache dir outside
      the repo (same fix as `init-rootfs.sh`); orchestrates fetch-prebuilt/build-gvproxy/
      init-rootfs first, then re-runs init-rootfs after vmproxy exists to complete rootfs
      assembly. `-F freebsd` kept for `anylinuxfs` (real compile failure without it —
      `Preferences::default_image()/images()` gated behind the feature; logged per PLAN.md's
      own fallback, not a blind drop); `vmrunner-sys` still builds clean without it (unaffected,
      see `init-rootfs.sh`). `vmproxy-bsd`/`freebsd-bootstrap` never built.
      Real run: exit 0, `cargo test` green for all three crates (common-utils, anylinuxfs,
      vmproxy-on-host-target). Fixed a real bug found along the way: `build/lib/lock.sh` was
      `set -euo pipefail` and used `SCRIPT_DIR` — sourcing it from `build-all.sh` clobbered
      `build-all.sh`'s own `SCRIPT_DIR` and (being sourced, not executed) leaked `-e` into the
      caller's shell options. Fixed: `lock.sh` now uses a private `_LOCK_SH_DIR` var and only
      `set -u`. `build-all.bats` 6/6 green (real build, not mocked — matches
      gvproxy.bats/rootfs.bats convention).
- [x] `v-integration` — `build/verify-vendor.sh`. Real checks (no live VM boot): all 4
      binaries present + correct arch (anylinuxfs/gvproxy/vmnet-helper arm64 host,
      vmproxy aarch64-linux guest), no `freebsd-bootstrap`/`vmproxy-bsd` artifacts, no
      `com.apple.quarantine` xattr, `vendor/kernel/modules.squashfs` sha256 matches
      `LIBKRUNFW_MODULES_SHA256` pin exactly, `anylinuxfs --version` runs (real
      dyld/libkrun link check). `verify-vendor.bats` 5/5 green (real run, not mocked).
      **Real finding, deliberately NOT resolved here (Kaveen confirmed, 2026-07-10):**
      `vendor/bin/anylinuxfs list` genuinely cannot succeed yet — `run_list()`
      (`main.rs:918-922`) unconditionally calls `vm_image::init()`, which requires the
      guest rootfs's real Alpine packages (`bash`, `blkid`, `cryptsetup`, `nfs-utils`,
      `ntfs-3g`, `squashfs-tools`, etc.) to already be installed. Confirmed by inspection:
      the OCI-pulled Alpine base rootfs at `$TMPDIR/ntfsmac-build/rootfs-home/...` has
      only busybox + skeleton dirs — real `apk add` only happens via `vm-setup.sh` at
      **first VM boot** (upstream anylinuxfs's own design), not at host build time. VM
      boot on an ad-hoc-signed binary needs the `com.apple.security.hypervisor`
      entitlement — a signing/entitlements change, which is `2-signing`'s scope and a
      HARD-STOP for any earlier unit per PLAN.md §0.3. **`2-signing` must add this
      entitlement before `anylinuxfs list`/`mount` can work for real** — flagging now so
      it isn't missed when that unit is reached. GATE-CLI-BEFORE-GUI's "list works from a
      clean install.sh" wording (§6) is the right place for the full live check, not here.

**Phase V complete** (with the above documented, non-blocking exception carried to
`2-signing`). `NTFSMAC_PHASE_COMPLETE:phase-v`

### Phase 1 — pf/route (deferrable)
- [x] `1-pf-rules` — `cli/lib/pf-anchor.sh` + `cli/pf/ntfsmac.anchor.tmpl`. Deny-by-default
      (`block in all` / `block out all`), then `pass` only NFS (2049) + mountd (32767)
      to/from the templated `{{SUBNET}}` — never hardcoded, caller always supplies it.
      `pf-rules.bats` 6/6 green.
- [x] `1-vpn-bypass` — `cli/lib/route-guard.sh`. Detects a VPN-style default route
      (`utun`/`ppp`/`tun` prefix via `netstat -rn`) and adds a host route for the bridge
      subnet directly on the bridge interface; never touches the VPN's own default route
      (test asserts no `default` token ever appears in a `route` invocation).
      `route-guard.bats` 5/5 green.
- [x] `1-teardown` — `cli/lib/pf-teardown.sh`. `pfctl -a ntfsmac -F rules` only (anchor-
      scoped, never a bare `pfctl -F`), optional bridge-subnet route delete, always
      exits 0 (idempotent — swallows pfctl/route failures). **Closes a loop from
      `2-unmount`:** `cli/commands/unmount.sh` already had a soft-optional call to this
      exact path; re-ran `unmount.bats` after adding this file to confirm no regression
      (7/7 still green — the real, unprivileged, now-live `pfctl` call is a harmless no-op
      under test, caught by pf-teardown's own `|| true`). `teardown.bats` 5/5 green.

**Phase 1 (pf/route hardening) complete**, though it remained non-blocking throughout —
built once Phase 2 was done and the entitlement HARD-STOP left no other unblocked CLI
work. `NTFSMAC_PHASE_COMPLETE:phase-1`

### Phase 2 — CLI
- [x] `2-device-validation` — `cli/lib/validate-device.sh`: `validate_device()`, one
      regex (`^disk[0-9]+s[0-9]+$`), stderr + non-zero on reject. `validate-device.bats`
      8/8 green (accepts disk2s1/disk10s3; rejects disk2, injection payload, `/dev/`
      prefix, empty string, disk2s, trailing garbage).
- [x] `2-mount` + `2-fs-driver-flag` (built together, same file per PLAN.md's own
      "schedule sequentially" note) — `cli/commands/mount.sh` + `cli/lib/nfs-mount.sh`.
      **Real architecture finding:** anylinuxfs's own `mount` subcommand already brings
      up the microVM, exports NFS from the guest, *and* performs the host-side NFS mount
      itself — confirmed in source (`fsutil.rs` `NfsOptions::default()`), which already
      defaults to `soft` on macOS **for exactly L3's hot-unplug-panic reason**, comment
      verbatim in the vendored source. `cli/lib/nfs-mount.sh` is the single place that
      ever sets `--nfs-options` (always `soft`, explicit, never trusts upstream default
      alone) so `hard` can never leak in from a caller. `mount.sh` never calls a separate
      `mount_nfs` binary directly — proven by test, not assumed. `--fs-driver ntfs3` maps
      to anylinuxfs's own `-t ntfs3` flag (never an `-o` token, L1). `mount.bats` 5/5,
      `fs-driver.bats` 4/4 green.
- [x] `2-unmount` — `cli/commands/unmount.sh`. Wraps `anylinuxfs unmount` (which already
      tears down the host NFS mount + microVM session; handles "no longer
      mounted"/"not mounted yet" as non-fatal per `cmd_mount.rs` `run_unmount`). Never
      passes `--wait-for-vm` — avoids blocking on a wedged VM. Calls
      `cli/lib/pf-teardown.sh` if present (Phase 1 soft-optional, not built yet).
      `unmount.bats` 7/7 green.
- [x] `2-diagnose` — `cli/commands/diagnose.sh`. Read-only: vendor binaries
      present+arch, quarantine xattr, kernel pin match (reuses `build/lib/lock.sh`'s
      `lock_get`), vmnet bridge process check, current NFS mounts, `--json` output.
      **Real bug found + fixed:** first draft used `declare -gA` (associative array) and
      `${!indirect}` expansion under `set -u` — both broke on macOS's system `/bin/bash`
      (3.2, no associative-array support; indirect-expansion + `set -u` + `:-` default is
      unreliable pre-4.4). Rewritten with plain scalar globals and an explicit
      `case`-based env-var lookup — bash-3.2-safe, matches this repo's actual runtime
      (`#!/bin/bash` resolves to system bash everywhere else in the repo too, so this
      class of bug can recur — worth remembering for any future script using arrays/
      indirection). `diagnose.bats` 6/6 green (healthy + 3 degraded branches + JSON shape
      + read-only-only assertion).
- [x] `2-install-sh` — `install.sh`. Copies `vendor/bin/anylinuxfs` to `$PREFIX/bin`,
      `gvproxy`/`vmnet-helper`/`vmproxy`/kernel Image+modules to `$PREFIX/libexec`, and
      the `cli/{commands,lib}` tree to `$PREFIX/libexec/ntfsmac/`. Generates a thin
      `$PREFIX/bin/ntfsmac` dispatcher (mount/unmount/diagnose) — PLAN.md's Files list for
      this unit is just `install.sh` itself, so the dispatcher is written inline by the
      script rather than as a separate committed source file. Refuses non-arm64 (L7),
      strips quarantine on every copied file, verifies anylinuxfs's signature before
      enabling it (gvproxy/vmnet-helper/vmproxy get formal signing in `2-signing`, right
      after — not duplicated here). `NTFSMAC_PREFIX` (default `/usr/local/ntfsmac`) and
      `NTFSMAC_REPO` (default `khr898/ntfsmac`, overridable) both testable via env.
      `install.bats` 6/6 green (real install against a temp prefix using this repo's
      actual built vendor/bin artifacts).
- [x] `2-signing` — `build/sign.sh` + `build/verify-signature.sh`. Ad-hoc signs
      (`codesign -s -`) only `anylinuxfs` + `gvproxy` — the two macOS Mach-O binaries we
      build ourselves. Deliberately excludes `vmnet-helper` (Apple-signed prebuilt;
      re-signing would strip its real entitlements) and `vmproxy` (Linux ELF guest
      binary, codesign doesn't apply). `verify-signature.sh` checks `codesign -v` passes,
      the signature is literally `Signature=adhoc` (not a real Developer ID — L4), and no
      quarantine xattr.
      **Updated 2026-07-10 — entitlement added, Kaveen approved:** `anylinuxfs` now also
      gets `build/entitlements/anylinuxfs.entitlements` embedded
      (`com.apple.security.hypervisor` + `cs.disable-library-validation`) via
      `--entitlements`, still ad-hoc identity (`-s -`, L4-compliant). Real, corrected
      finding along the way: **upstream's own
      `vendor/src/anylinuxfs/anylinuxfs.entitlements` has a typo** —
      `com.apple.security.cs.disable-library-validationr` (trailing "r") — which silently
      no-ops that key. Our copy fixes the spelling; not a byte-for-byte vendor of theirs.
      `gvproxy` gets no entitlements (doesn't need them). Real signing run + real
      `codesign -d --entitlements` verification both confirm it's embedded correctly.
      **Adding the entitlement did NOT make `anylinuxfs list` succeed** — see the GATES
      section above: the real remaining blocker is a separate, already-documented gap
      (missing `libexec/init-rootfs` helper), not entitlements. `signing.bats` 9/9 green
      (fixture sign/verify/tamper tests plus 2 new: entitlement present on anylinuxfs only,
      verify-signature.sh's entitlement check).
- [x] `2-brew-formula` — `Formula/ntfsmac.rb`. `head`-only (tap has no tagged release yet
      — a stable `url`+`sha256` block needs a real cut GitHub release, not fabricated
      here). `install` shells out to `build/build-all.sh` + `build/sign.sh`, then lays out
      `bin/anylinuxfs`, `libexec/{gvproxy,vmnet-helper,vmproxy,kernel files}`, and
      `libexec/ntfsmac/{commands,lib}`, generating the same `bin/ntfsmac` dispatcher
      `install.sh` writes. `post_install` strips quarantine. `depends_on arch: :arm64` +
      `depends_on macos: :ventura` (L7). Real `brew audit --strict` run (not skipped) —
      required registering the formula in a real local tap first (`brew audit` rejects a
      bare path with "Homebrew requires formulae to be in a tap"; scratch-tapped
      `khr898/ntfsmac` via `brew tap-new`, copied the formula in, audited, `brew untap`'d
      immediately after — verified no leftover tap). One real rubocop finding fixed:
      `EmptyLineAfterGuardClause` in `post_install`. Clean on the second run.
      `formula.bats` 7/7 green (audit test itself does the same scratch-tap dance so it's
      reproducible in CI, not just this session).

**Phase 2 (CLI) all 8 units complete.** `NTFSMAC_PHASE_COMPLETE:phase-2` — but
**GATE-CLI-BEFORE-GUI has NOT fired** (see GATES section above): live `anylinuxfs list`
is still blocked on the Hypervisor entitlement question. Do not start Phase 3 until that's
resolved.

### Phase 3 — GUI (gated, override recorded above)
- [x] `3-xpc-helper` — `Package.swift` (new, SPM — no Xcode project; matches this repo's
      scripted-build convention, real `swift build`/`swift test` both run clean), `helper/{main,
      HelperProtocol}.swift`, `helper/{Info,launchd}.plist`, `gui/Helper/HelperClient.swift`,
      `helper/Tests/HelperTests.swift` (21/21 real, `swift test`, not mocked framework internals).
      **Real contracts checked before coding, not invented (0.2):** `anylinuxfs`'s real `ListCmd`/
      `MountCmd` structs (`cli.rs`) have **no `--json` flag on either** — only `2-diagnose`'s own
      `diagnose.sh` wrapper has one (fields: `healthy,missing_binaries,quarantined_binaries,
      kernel_pin,bridge`). `mount.sh`'s real `--fs-driver` values are `ntfs-3g`/`ntfs3` (hyphen in
      the default). `unmount.sh` accepts a bare device **or** a `/Volumes/` path, unvalidated at
      that layer — helper adds `isValidUnmountTarget()` (device regex OR `/Volumes/` prefix, no
      `..`) since L6 duplication only makes sense for device-shaped input.
      **XPC surface scoped to exactly `mount`/`unmount`/`applyPfRules`/`teardown`** — this unit's
      own Do clause, not §3's full future table. `listDrives`/`status`/`diagnose` are deliberately
      absent: each is read-only and explicitly Don't-listed as privileged in its own later unit
      (`3-drive-detect`, `3-status-speed`, `3-diagnose-ui` call the CLI directly, unprivileged).
      **`CommandResult{output,exitCode}`** is the one payload shape used everywhere — none of the
      underlying scripts emit structured JSON (confirmed by reading them), so nothing richer
      (`MountResult`/`Drive`/`StatusSnapshot`) is fabricated in this unit.
      **`applyPfRules` is a new integration point:** `pf-anchor.sh` only *renders* the anchor
      text (confirmed — no existing caller pipes it into `pfctl`); `HelperService.applyPfRules`
      is the first real caller, piping render output into `pfctl -a ntfsmac -f -` itself.
      **Ad-hoc identity check (`verifyClientIdentity`) is real code, not a stub** — but documented
      as best-effort in both `main.swift`/`HelperProtocol.swift` comments and `helper/Info.plist`:
      ad-hoc signing (L4) has no trusted cert chain, so this only pins the caller's own claimed
      identifier, not a strong guarantee. The load-bearing control is per-call `validateDevice`/
      `isValidUnmountTarget`, always exercised regardless. Not unit-tested (can't fake a real XPC
      connection's SecCode in XCTest) — same class of sandbox-unverifiable gap as the VM boot
      check, flagged rather than silently skipped.
      **Kaveen decision (2026-07-10):** GUI bundles its own copies of vendor binaries into
      `ntfsmac.app/Contents/Resources` (self-contained DMG, no Homebrew/CLI dependency) —
      but the privileged helper itself always resolves binaries at the fixed `installPrefix =
      "/usr/local/ntfsmac"` (same path `install.sh` already uses), because the helper runs
      standalone under launchd after SMJobBless with no `Bundle.main` back to the original .app.
      **New follow-on item for `3-first-run-install`:** that unit must add a step staging the
      GUI's bundled `Resources/{bin,libexec,lib}` into `/usr/local/ntfsmac` alongside driving
      `SMJobBless` — not built here, flagging so it isn't missed.
      **Follow-up fix, same session:** `.claude/rules/swift/testing.md` (repo convention, not
      surfaced until working on this unit) mandates Swift Testing (`@Test`/`#expect`), not
      XCTest — `HelperTests.swift` was written XCTest-first before that rule was seen; converted
      to Swift Testing, bumped `swift-tools-version` to 6.0 (toolchain-bundled Testing module,
      no external package dep). That bump turned on Swift 6 strict concurrency by default, which
      correctly flagged `CommandResult`/`FsDriver` crossing the XPC reply-closure boundary
      without `Sendable` — added real conformance, not a suppression. 21/21 still green after.
- [x] `3-menubar-shell` — `gui/App/NtfsmacApp.swift`, `gui/Info.plist`,
      `gui/Status/StatusIcon.swift`, `gui/State/AppState.swift`, `gui/Tests/StatusIconTests.swift`
      (5/5 real, Swift Testing). Native `MenuBarExtra` (macOS 13+, real API, no version bump
      needed) for the icon+popover shell — popover content is a placeholder `Text("ntfsmac")`;
      actual drive rows/buttons are later units' files, not invented here (this unit's file list
      is shell-only). **Pulsing avoids `.symbolEffect(.pulse)`** (SF Symbols 5, macOS 14+/Sonoma
      — would silently force the L7/macOS-13.0+ floor up, HARD-STOP territory per this unit's own
      Don't clause) — plain `.opacity` + `withAnimation(...repeatForever)` gets the same visual
      result and stays 13.0-compatible. Colors are semantic SwiftUI (`.gray/.blue/.green/.yellow/
      .red`) per GUI-PLAN's table; `3-liquid-glass` (styling pass, last, solo) is where literal
      hex values from `ui/prototype.html` land, not here. `gui/Info.plist` reuses the
      `com.khr898.ntfsmac` identifier the helper's `verifyClientIdentity` already expects.
      `Package.swift` grew a `ntfsmac-gui` executable target + `NtfsmacGUITests` test target —
      still SPM only, no Xcode project; actual `.app` bundle assembly (embedding this Info.plist,
      icon, code signing) is packaging work for a later script, not part of this unit's
      acceptance (compiles + tests pass).
- [x] `3-drive-detect` — `gui/Drives/DriveScanner.swift`, `gui/Views/DriveRow.swift`,
      `gui/Tests/DriveScannerTests.swift`. **Real contract checked before coding:** `ListCmd`
      (`cli.rs`) has no `--json` flag (same finding `3-xpc-helper` already made) — output is
      `diskutil list`, augmented in place by `darwin::augment_line` (TYPE column → real fs_type,
      NAME column → real label, at fixed widths; confirmed by reading `diskutil/{mod,darwin}.rs`
      end to end, not guessed from a sample). `DriveListParser` anchors on the trailing token
      matching `deviceNamePattern` (reused from `HelperShared`, not re-declared — L6) to exclude
      the header row and whole-disk/scheme rows (`diskN` with no `sN` suffix) without any
      fs-type-specific special-casing. `DriveScanner` calls `\(installPrefix)/bin/anylinuxfs list
      --microsoft` (WINDOWS_LABELS filter: ntfs/exfat/BitLocker only — matches this project's
      NTFS focus) unprivileged, per this unit's Don't clause (listing never touches the XPC
      helper). Reuses `HelperShared`'s `PrivilegedCommandRunning`/`RealCommandRunner` seam
      (already used by `HelperService`) instead of a second process-spawn helper — deliberately
      typed as plain `any PrivilegedCommandRunning` (not `& Sendable`) to match `HelperService`'s
      existing typing rather than adding a `Sendable` conformance to `3-xpc-helper`'s shared
      protocol file, which is out of this unit's scope; documented trade-off is `refresh()`
      blocks the `@MainActor` for the subprocess's duration (acceptable for a background popover
      poll, revisit with a detached hop if ever felt in the UI). Poll interval hardcoded 5s,
      `ponytail:` comment marks it as a `3-preferences` knob candidate, not built now (YAGNI).
      `DriveListView` (same file as `DriveRow`, per this unit's Files list — no new file
      invented) satisfies the "render idle cleanly when empty" acceptance clause with a plain
      placeholder `Text`. Did **not** touch `NtfsmacApp.swift` — wiring the live scanner into the
      actual popover is `3-mount-unmount`'s Files list (`DriveRow.swift (button)`), which also
      owns adding the `[Mount]` button on top of this unit's read-only row.
      Real `swift build`/`swift test` both run clean: 6/6 new `DriveScannerTests` (Swift Testing,
      not XCTest, per repo convention), 32/32 total across `HelperTests`+`StatusIconTests`+
      `DriveScannerTests`, zero warnings. `Package.swift`'s `NtfsmacGUI` target sources list
      grew `Drives/DriveScanner.swift` + `Views/DriveRow.swift` (explicit sources list, not a
      glob — new files don't get picked up silently).
- [x] `3-mount-unmount` — `gui/Actions/MountController.swift`, `gui/Views/DriveRow.swift`
      (button), `gui/Tests/MountControllerTests.swift`. `[Mount]`/`Unmount` route through a new
      `HelperMounting` protocol (declared in `MountController.swift`, `extension HelperClient:
      HelperMounting {}` — same-module retroactive conformance, `HelperClient.swift` itself
      untouched) instead of `HelperClient` directly, since `HelperClient` is a concrete class
      wrapping a real `NSXPCConnection` with no seam for tests; `FakeHelper` in the test file
      subs in for it. `MountController.mount()` re-validates the device regex itself (defense in
      depth beyond `HelperClient`'s own internal check — the mocked `HelperMounting` in tests
      bypasses that internal check, so this unit's own guard is what the acceptance criteria
      "rejection of invalid device names" actually exercises) and drives the shared
      `AppState.state` transition idle→mounting→mounted/error. `DriveRow`/`DriveListView` grew
      `isMounted`/`onMount`/`onUnmount` (default-valued, so the existing `3-drive-detect` test
      calling `DriveListView(drives:)` needed no changes).
      **Real review pass run (medium tier, reviewer ≠ author per §7.2):** `ecc:swift-reviewer`
      agent read all changed files + dependencies, ran `swift build`/`swift test` independently.
      Found one real HIGH: nothing stopped mounting a second drive while one was already
      mounted/mounting — `mountedDrive`/`appState.state` would silently get overwritten,
      orphaning the first drive (still mounted through the helper with no button left to unmount
      it). Fixed with a single-mount-at-a-time guard at the top of `mount()`; **found and fixed a
      second, self-introduced bug while adding that guard's regression test**: the guard's reject
      path initially called the shared `fail()` helper, which stomps `appState.state` to `.error`
      — meaning rejecting a redundant mount tap would have wrongly kicked a happily-mounted drive
      into the error state. Fixed to set `errorMessage` only, no state transition, on that reject
      path. Also fixed from the review: `NtfsmacGUITests` was importing `HelperShared` without
      declaring the dependency in `Package.swift` (worked only by accident of SwiftPM's shared
      build graph); `ntfsmac-gui`'s executable target was missing `Drives`/`Views`/`Actions` from
      its `exclude` list (spurious "found N unhandled files" build warnings, growing by one each
      unit); `describe(_:)`'s catch-all leaked a raw Swift error dump instead of
      `error.localizedDescription` (currently dead code — `HelperClient` only throws
      `HelperClientError` — but a real latent leak for any future `HelperMounting` conformance).
      Real `swift build`/`swift test`: clean, zero warnings, 39/39 (7 new, incl. the
      double-mount regression test).
- [x] `3-status-speed` — `gui/Views/SpeedBar.swift`, `gui/Drives/ThroughputMonitor.swift`,
      `gui/Tests/ThroughputTests.swift`. **Real gap confirmed before coding, not guessed:**
      checked `RuntimeInfo` (`vendor/.../api.rs`) and `cli/commands/diagnose.sh` for any exposed
      per-mount interface name or byte counters — neither exists, so there is no clean unprivileged
      source of real NFS throughput today. `RealInterfaceByteCounter` reads `getifaddrs`, sums
      `ifi_ibytes`/`ifi_obytes` for every interface named with a `bridge` prefix, documented in
      the file itself as a heuristic proxy for vmnet.framework's host-side bridge interface (real,
      documented macOS/vmnet.framework behavior — not this repo's own naming convention), flagged
      here for verification against a real mount once `GATE-CLI-BEFORE-GUI`'s VM-boot blocker
      clears. `ThroughputMonitor.computeRate` is a pure, `nonisolated static func` extracted
      specifically so tests exercise the rate math without depending on real `Task.sleep` timing.
      `SpeedBar` hides during idle/error (exhaustive `switch` over `MountState`, not a boolean OR
      chain — a future new "mounted-ish" case must force a decision here). Same deferred-
      integration precedent as `3-drive-detect`/`3-mount-unmount`: does not touch `NtfsmacApp.swift`.
      **Real review pass (small tier, reviewer ≠ author):** `ecc:swift-reviewer` verified
      `getifaddrs` pointer lifetime/rebind safety against the Darwin SDK headers (no
      use-after-free, no unsafe cast) and the `start()`/`stop()`/`lastSample` interaction (no
      stale-baseline bug across repeated `start()` calls). Approved, no CRITICAL/HIGH. Fixed both
      MEDIUM findings: `ifi_ibytes`/`ifi_obytes` are 32-bit on Darwin (`if_data`, not the 64-bit
      `if_data64`) and wrap past 4GB cumulative traffic — `computeRate`'s existing reset guard
      already drops that one sample rather than reporting a wrong/negative rate (self-heals next
      tick), now documented inline with a `ponytail:` comment instead of being a silent ceiling;
      `SpeedBar`'s three-way `||` chain converted to the exhaustive `switch` described above. Also
      addressed the LOW finding: renamed/annotated the one monitor lifecycle test to state plainly
      it only proves 0→0 idle handling (no seam exists to drive a real nonzero value without
      reintroducing real-clock timing, which the rate-math tests deliberately avoid).
      Real `swift build`/`swift test`: clean, zero warnings, 45/45 (6 new).
- [x] `3-dirty-ro-warning` — `gui/Views/DirtyBanner.swift`, `gui/Actions/RemountController.swift`,
      `gui/Tests/DirtyStateTests.swift`, plus a one-line widening in `gui/Actions/
      MountController.swift` (`describe(_:)` `private static` → `static`, reused by
      `RemountController` instead of re-duplicating the `HelperClientError` mapping — same-module
      reuse, no new public API). **Real signal traced through vendored source before coding, not
      guessed:** `cmd_mount.rs:521`'s `media_writable()` check is ntfs-3g's real dirty-journal
      read-only fallback; confirmed there is **no CLI override** for it — `cli.rs`'s `MountCmd`
      has no `force` field (only `StopCmd` does, for force-unmount), and the fallback is silent
      on the CLI's own stdout (no human-readable message tied to the internal
      `<anylinuxfs-mount:changed-to-ro>` pty tag reaches `CommandResult.output` — traced the full
      `PtyReader`/`NfsReadyState` path in `cmd_mount.rs` to confirm this, not assumed).
      `DirtyBanner`/`DirtyBannerView` mirror the existing `StatusIcon`/`StatusIconView` pure-logic-
      plus-view split (`gui/Status/StatusIcon.swift`) so `DirtyStateTests` asserts visibility
      without a SwiftUI view-inspection dependency.
      **Real review pass (medium tier) found two real HIGH issues, both fixed, not just noted:**
      (1) `confirmRemount()` had no re-entrancy guard — a double-tap on "Mount read/write anyway"
      while the first attempt was still awaiting the helper could fire two concurrent privileged
      mount RPCs for the same device, the same class of bug `MountController.mount()` was already
      hardened against in `3-mount-unmount`. Fixed with an `isRemounting` flag guarding both
      `requestRemount()` and `confirmRemount()`, plus transitioning `appState.state = .mounting`
      during the attempt (which also naturally hides the banner, since `DirtyBanner.isVisible`
      only fires for `.mountedReadOnlyDirty`). Regression test uses a `BlockingHelper` +
      `CheckedContinuation` to hold a mount call open and assert the second attempt is rejected
      before resuming — 3 real, deterministic runs, not flaky. (2) `confirmRemount()` was
      optimistically reporting `.mountedReadWrite` on `exitCode == 0` alone — since a remount of a
      still-dirty volume can silently re-land read-only with the same exit code (per the confirmed
      no-force-flag gap above), this would have told the user their explicit corruption-risk
      confirmation "worked" when it silently hadn't. Fixed with a real, unprivileged post-remount
      check (`RealMountOptionsChecker`, `mount -t nfs`, same source `diagnose.sh`'s
      `current_mounts()` already reads) rather than deferring the fix — only flips to
      `.mountedReadWrite` if no active NFS mount reports `read-only`; otherwise stays
      `.mountedReadOnlyDirty` with an explicit "still read-only" message. (Heuristic scope note,
      same class as `3-status-speed`'s bridge-interface matching: "any NFS mount is read-only" is
      unambiguous only because of this app's own single-mount-at-a-time invariant — flagging if
      that invariant is ever relaxed for v2 multi-drive support.)
      Real `swift build`/`swift test`: clean, zero warnings, 53/53 (9 new, incl. the concurrency
      regression test).
- [x] `3-security-indicators` — `gui/Views/SecurityIndicators.swift`,
      `gui/Tests/SecurityIndicatorsTests.swift`. Mirrors `StatusIcon`/`StatusIconView`'s pure-
      logic-plus-view split: `SecurityIndicator.style(for:label:)` pure mapping +
      `SecurityIndicatorsView`. Three states (`enforced`/`notEnforced`/`unknown`), not two — Phase
      1 pf/route hardening is documented deferrable/non-blocking (GATES section above), so a real
      install can legitimately have no hardening data at all; `.unknown` exists so "no data"
      never renders as `.enforced`, satisfying this unit's Do clause verbatim ("never a false
      ✓"). Confirmed `diagnose.sh` doesn't currently surface Phase 1 pf-anchor/route-guard state
      at all (its own header comment says diagnose never touches pf/route) — live wiring is
      deferred to whichever later unit adds that CLI-side capability, flagged here so it isn't
      missed; this unit's Files list is display-only by design.
      **Real review pass (small tier) found two MEDIUM issues, both fixed:** (1) the safety
      guarantee was convention-only — `SecurityIndicatorStyle`'s default memberwise init let any
      code elsewhere in the module hand-construct a green-checkmark style for a `.notEnforced`
      status, bypassing `SecurityIndicator.style` entirely. Fixed by giving the struct an
      explicit `fileprivate init` — the guarantee is now compiler-enforced (only `style(for:
      label:)`, same file, can construct a value), not just true because nothing else happens to
      call it today. (2) VoiceOver asymmetry — `.notEnforced`/`.unknown` self-describe via text
      ("X: not enforced"/"X: unknown"), but `.enforced` was a bare label relying on the system's
      default accessibility description of the SF Symbol glyph. Fixed: `.enforced` now reads
      "X: enforced" too, all three states self-describing by text alone.
      Real `swift build`/`swift test`: clean, zero warnings, 63/63 (5 new).
- [x] `3-open-finder` — `gui/Actions/FinderOpener.swift`, `gui/Tests/FinderOpenerTests.swift`.
      `FinderOpener.open(_:state:)` calls `NSWorkspace.activateFileViewerSelecting(_:)` (real
      Apple "reveal in Finder" API — never a shell-out/`open` subprocess, per Don't clause) via a
      `WorkspaceOpening` seam (`extension NSWorkspace: WorkspaceOpening {}`, same retroactive-
      conformance-in-a-new-file pattern as `HelperClient: HelperMounting`). **Real gap, flagged
      not silently worked around:** neither `Drive` (`3-drive-detect`) nor
      `MountController.mountedDrive` (`3-mount-unmount`) carry an actual mount point — nothing in
      those units' Files lists threaded the real path through, even though the CLI's own mount
      output text has it. `FinderOpener.mountPoint(for:)` falls back to GUI-PLAN.md's own
      documented default convention (`/Volumes/<label>`, from the Preferences table) — the only
      convention available at this layer today; flagged for a real fix if `3-preferences`/
      `3-mount-unmount` ever thread an actual caller-chosen mount point through.
      `isEnabled(for:)` is true for both `.mountedReadWrite` and `.mountedReadOnlyDirty` (a
      dirty-RO volume is still browsable, just not writable) — matches GUI-PLAN's "Mounted" gate,
      not literally "read-write only". Trivial tier (implement→test only, per §7.2's tier table —
      no dedicated review pass). Real `swift build`/`swift test`: clean, zero warnings, 58/58
      (5 new).
- [x] `3-diagnose-ui` — `gui/Actions/DiagnoseRunner.swift`, `gui/Views/DiagnosePanel.swift`,
      `gui/Tests/DiagnoseRunnerTests.swift`. `DiagnoseReport` fields verified byte-for-byte
      against `cli/commands/diagnose.sh`'s actual JSON emit line
      (`healthy,missing_binaries,quarantined_binaries,kernel_pin,bridge`), not guessed.
      `DiagnoseRunner` calls `\(installPrefix)/bin/ntfsmac diagnose --json` unprivileged, reusing
      `HelperShared`'s `PrivilegedCommandRunning`/`RealCommandRunner` seam (same pattern as
      `DriveScanner`); `install.sh`'s generated dispatcher (`diagnose) exec ".../diagnose.sh"
      "$@"`) confirmed to forward `--json` through before coding, not assumed. `DiagnoseSummary`
      mirrors `StatusIcon`/`SecurityIndicator`'s pure-logic-plus-view split.
      **Real review pass (small tier):** approved, no CRITICAL/HIGH. Confirmed (not just assumed)
      that the `try?` decode-failure→raw-output-as-error-message collapse is correct given
      `diagnose.sh` always emits well-formed JSON on success (health only affects exit code, not
      whether stdout parses) — a decode failure only happens on genuine command failure, where
      the raw output *is* the useful error text. Confirmed the `isRunning` reentrancy guard is
      currently dead code (no `await` suspension point exists inside `run()`, so the MainActor's
      serial executor can't interleave a second call anyway) — correctly left untested rather
      than writing a misleading concurrency test, kept as cheap forward-defense. Fixed one real
      minor UX gap the review surfaced: `report`/`errorMessage` weren't cleared at the start of a
      re-diagnose run, so a stale prior result stayed on screen for the whole run and
      `DiagnosePanel`'s `ProgressView` branch was unreachable past the first run — now cleared
      up front.
      Real `swift build`/`swift test`: clean, zero warnings, 67/67 (5 new).
- [x] `3-first-run-install` — `gui/FirstRun/HelperInstaller.swift`, `gui/Views/FirstRunView.swift`,
      `gui/Tests/HelperInstallerTests.swift`, plus a necessary (not optional) `SMPrivilegedExecutables`
      addition to `gui/Info.plist` pairing `helper/Info.plist`'s already-committed
      `SMAuthorizedClients` — without both halves, `SMJobBless` rejects the bless request outright;
      that file's own comment (from `3-xpc-helper`) explicitly forward-referenced this unit as the
      one that would add it. Real `SMJobBless`/`AuthorizationCreate`/`SMJobCopyDictionary` calls,
      not stubbed — deliberately not `SMAppService` (L4/L5 HARD-STOP: PLAN.md locks the mechanism).
      **Real review pass (large tier — both `ecc:swift-reviewer` and `ecc:security-reviewer` ran in
      parallel, per the security-trigger rule for authorization code):**
      Security review: no CRITICAL/HIGH. Confirmed the identifier-only trust pairing (no cert
      chain — ad-hoc signing) is a pre-existing, already-documented consequence of L4, not
      introduced or worsened here; confirmed `AuthorizationFlags`
      (`.interactionAllowed/.extendRights/.preAuthorize`) match Apple's canonical one-shot
      `SMJobBless` flag set exactly, no broader-than-needed right requested; confirmed no
      stale/cached `AuthorizationRef` reuse (fresh per call, freed via `defer`).
      Swift review found two real, fixed issues (verdict: Block until fixed): (1)
      `AuthorizationItem.name`'s pointer was taken from `(kSMRightBlessPrivilegedHelper as
      NSString).utf8String` — relies on an undocumented bridging-temporary-lifetime detail rather
      than the actual API contract (reviewer ASan-tested the pattern: doesn't crash today because
      the literal happens to bridge to immortal storage, but that's implementation detail, not
      guarantee) — fixed with `withCString`, keeping `AuthorizationCreate` inside the closure. (2)
      `Task.detached` for the `SMJobBless`/`SMJobCopyDictionary` calls occupies a slot on Swift
      Concurrency's small, shared cooperative thread pool for the *entire* indefinite, user-driven
      auth-prompt wait — real anti-pattern (Apple's own guidance: don't block the cooperative pool
      indefinitely), fixed by dispatching to `DispatchQueue.global(qos: .userInitiated)` via
      `withCheckedContinuation` instead, a separate thread pool from Swift's own. Also fixed two
      MEDIUM findings: `errAuthorizationDenied` now gets its own plain-language message (was
      falling into the generic "status \(status)" branch, not actually plain-language per the Do
      clause's own wording); the `installIfNeededSkipsWhenAlreadyInstalled` test was strengthened
      to prove the skip path is actually taken (originally used `outcome: .installed` on the
      bless-path too, so it couldn't distinguish "skipped" from "called bless anyway and it
      happened to succeed" — now uses `outcome: .failed(...)` so a regression would surface as a
      wrong final state, not a false pass). Applied both security-reviewer LOW items too: a
      trust-limitation comment on `isInstalled()` (checks launchd-job presence only, no binary
      integrity re-check — inherent to `SMJobCopyDictionary`, not a gap introduced here), and a
      re-entrancy guard on both `installIfNeeded()`/`install()` against a rapid double-tap firing
      two concurrent `SMJobBless` calls (each would show its own OS auth prompt). Added a real
      concurrency regression test (`secondInstallWhileFirstInFlightIsRejected`, semaphore-based
      `BlockingInstallService` genuinely blocking on the `DispatchQueue.global` thread the
      production code now dispatches to) — verified stable across 5 repeated runs, not flaky.
      Swift-reviewer's remaining finding (item 5, non-blocking): this unit's flow isn't wired into
      `NtfsmacApp.swift` — **confirmed deliberate**, same deferred-integration precedent as every
      other Phase 3 feature unit so far (`3-drive-detect` through `3-diagnose-ui`), not a gap
      specific to this unit.
      Two expected `#DeprecatedDeclaration` warnings on `SMJobCopyDictionary`/`SMJobBless`
      (deprecated in favor of `SMAppService`) left visible rather than suppressed — they document
      the real, intentional L4/L5 architecture lock, not an oversight.
      Real `swift build`/`swift test`: clean (only the two expected deprecation warnings), 73/73
      (6 new, incl. the concurrency regression test, stable across 5 repeated runs).
- [x] `3-preferences` — `gui/Preferences/Settings.swift`, `gui/Preferences/PreferencesView.swift`,
      `gui/Tests/SettingsTests.swift`. `Settings` (`@MainActor ObservableObject`) persists exactly
      the 5 GUI-PLAN.md "Preferences window" controls to `UserDefaults` (ctor-injected, so tests use
      isolated suites, never `.standard`). `defaultMountMode`'s stored-raw-value fallback
      (`String?.flatMap(DefaultMountMode.init(rawValue:)) ?? Defaults.defaultMountMode`) collapses
      both "key absent" and "key present but garbage" to the documented default — verified by a
      dedicated test (`unsetDefaultMountModeFallsBackToReadWrite`), not just claimed in a comment.
      `LaunchAtLoginService` seam wraps `SMAppService.mainApp.register()/unregister()` (macOS 13+,
      not the deprecated `SMLoginItemSetEnabled`) so the toggle actually registers the login item,
      not just a dead bool. `PreferencesView`'s "Reinstall privileged helper" button reuses
      `HelperInstaller.install()` directly (`3-first-run-install`'s class, confirmed against its
      real public API before wiring, not assumed) rather than inventing a parallel reinstall path.
      **Real review pass (small tier):** approved, one real MEDIUM fixed: `launchAtLogin`'s `didSet`
      called `loginService.setEnabled` synchronously on the `@MainActor` — same class of blocking
      `SM*`/IPC call that `HelperInstaller.runOffCooperativePool` (from `3-first-run-install`) already
      exists specifically to avoid running on the main actor or the cooperative thread pool. Fixed by
      dispatching via `Task.detached(priority: .userInitiated)` instead, mirroring that precedent
      (`ponytail:` comment marks the reasoning inline). Confirmed no scope creep beyond GUI-PLAN.md's
      exact 5-control table. Not wired into `NtfsmacApp.swift` — same deferred-integration pattern as
      every other Phase 3 unit so far, confirmed deliberate, not a gap.
      Real `swift build`/`swift test`: clean, zero warnings beyond the two pre-existing
      `SMJobCopyDictionary`/`SMJobBless` deprecation warnings, 77/77 (4 new).
- [x] `3-liquid-glass` — `gui/Style/Colors.swift`, `gui/Style/GlassTheme.swift`, plus color/wiring
      edits across `gui/Status/StatusIcon.swift`, `gui/Views/SecurityIndicators.swift`,
      `gui/Views/FirstRunView.swift`, `gui/App/NtfsmacApp.swift`, `gui/Preferences/
      PreferencesView.swift`. Literal hex/rgba values read directly from `ui/prototype.html`'s dark+
      light comps (green `#34c759`/`#30d158`, blue `#007aff`/`#2d9cff`, yellow `#ffd60a`, red
      `#ff453a`; popover 13pt radius + gradient tint + border; prefs-window `rgba(18,18,24,0.72)`
      content tint; row cards `rgba(255,255,255,0.05)` fill/`0.08` border/10pt radius) — verified
      against the file's own CSS, not eyeballed. **Real API decision, checked before coding:** used
      `NSVisualEffectView` (via a small `NSViewRepresentable`), not SwiftUI's real `.glassEffect()`
      modifier — that API is macOS 26+ only and would silently force L7's macOS 13.0+ floor up,
      same HARD-STOP class `3-menubar-shell` already avoided for `.symbolEffect(.pulse)`.
      `Package.swift`'s `platforms: [.macOS(.v13)]` confirmed unchanged. Idle state stays
      `.secondary` (system-adaptive) rather than a new brand hex — the comp itself only uses
      translucent white/black for idle, not a custom color, so `.secondary` *is* the literal
      translation, not an invented shortcut.
      `PreferencesView` restructured from a plain SwiftUI `Form` to a custom `VStack` of glass-card
      rows matching the comp's actual layout (native `Form` doesn't look like the comp at all) —
      same `$settings.*`/`installer.*` bindings as `3-preferences` left them, no behavior change,
      confirmed by review.
      **Real review pass (medium tier):** approved, three real findings fixed: (1) `notEnforced`/
      `unknownNeverShowsCheckmarkOrGreen` tests compared against stock `Color.green` instead of the
      new `.ntfsGreen` the "enforced" state actually renders — vacuous assertion that could never
      fail even if a future change wrongly returned `.ntfsGreen` for a non-enforced status, silently
      defeating the exact "never a false ✓" guarantee those tests exist to enforce (per
      `SecurityIndicators.swift`'s own doc comment). Fixed to compare against `.ntfsGreen`. (2)
      Popover border alpha was `0.13`, comp's literal dark value is `0.14` — fixed. (3) Doc comment
      claimed "matching drop shadow" when the comp actually layers two box-shadows + an inset
      rim-light per mode and SwiftUI's `.shadow()` only supports one outer shadow — comment now
      documents this as an approximation instead of overstating fidelity.
      **Real, flagged-not-fabricated gap:** PLAN.md's acceptance clause for this unit accepts either
      a screenshot diff or a committed manual sign-off checklist — this environment has no
      screenshot/rendering pipeline for a real running macOS app (same class of sandbox-unverifiable
      gap as the earlier VM-boot check), so no automated visual-parity proof is committed here.
      **Kaveen: please eyeball the built app against `ui/prototype.html`'s dark+light comps
      (mounted/idle/dirty/error states, Preferences window) and confirm parity** — nothing else
      blocks this, it's purely a "can't screenshot from inside this sandbox" gap, not an unfinished
      feature.
      Real `swift build`/`swift test`: clean, 77/77 (2 pre-existing tests updated for the new
      literal palette, no new tests needed — this is a styling-only pass over already-tested pure
      logic, consistent with this repo's established "views aren't directly unit-tested" convention).

**Phase 3 (GUI) all units complete.** `NTFSMAC_PHASE_COMPLETE:phase-3` — GATE-CLI-BEFORE-GUI was
deliberately overridden by Kaveen (2026-07-10, see GATES section above), so this doesn't reopen
that question; the one remaining real gap for Kaveen is the visual sign-off just above, plus the
still-unverified real VM boot (`kern.hv_support` sandbox limitation, also above). No further §6
units remain in PLAN.md's task list for Phase 3.

### Post-Phase-3 work (not §6 units, found/requested after "Phase 3 complete" above)

- **App-shell integration ("Gap 0")** — `gui/Views/PopoverContentView.swift`, plus wiring changes
  to `gui/App/NtfsmacApp.swift` and `gui/Helper/HelperClient.swift` (added `@MainActor` +
  `nonisolated(unsafe)` on the `NSXPCConnection` property, both real Swift 6 concurrency fixes,
  not suppressions). **Real, previously-undiscovered gap:** every Phase 3 feature unit
  (`3-drive-detect` through `3-liquid-glass`) built its view and deferred wiring it into the
  actual popover on the stated assumption a later unit would — no unit in PLAN.md's §6 list ever
  did, so the running app's popover was still literally `Text("ntfsmac")` even after "Phase 3
  complete" above. Found while writing `TESTING.md`. Now closed: the popover gates on
  `HelperInstaller.state` (first-run prompt vs. main content), assembles the real drive list,
  mount/unmount, speed bar, dirty-RO banner, security indicators (`.unknown`/`.unknown` — Phase 1
  hardening state still isn't surfaced by `diagnose.sh`, a separate pre-existing gap, not newly
  introduced), Open in Finder, Diagnose panel, and a `Settings` scene for Preferences.
  **Real review pass (`ecc:swift-reviewer`, approve):** fixed one real MEDIUM — a redundant
  `installIfNeeded()` call at the popover-content level would have raced `FirstRunView`'s own
  identical call on every popover open once already installed, flashing the first-run screen;
  removed (`FirstRunView` already self-installs when shown). Real `swift build`/`swift test`:
  clean, 77/77, no regressions.
  **Known, deliberately out-of-scope limitations left as-is:** `Settings.defaultMountMode`/
  `defaultMountPoint` are stored but not threaded into `MountController.mount()` (no v1
  auto-mount-on-detect, only the manual button, which always mounts read-write via ntfs-3g) —
  pre-existing gap in `MountController`'s own public API from `3-mount-unmount`, not this
  changeset's job to fix; flagging again so it isn't lost.
- **App icon** — `gui/Resources/AppIcon.icns` (+ `AppIcon-source.png`, `gen_icon.py`), wired via
  `Info.plist`'s `CFBundleIconFile`. White external-drive + connect-arrow glyph (reuses this
  project's own already-established icon language — same motif as `ui/prototype.html`'s SVGs and
  `StatusIcon.swift`'s SF Symbol choice, not invented fresh) on a diagonal gradient between the
  two brand blues in `Colors.swift` (`ntfsGreen`/`ntfsBlue` etc.). No SVG rasterizer was available
  in this environment — drawn directly with Python/PIL, then `sips`/`iconutil` built the real
  `.iconset`/`.icns`. **Real, flagged limitation:** no `.app` bundle assembly script exists yet
  (packaging is separate, unbuilt work — not in PLAN.md's §6 list either), so this icon isn't
  visible anywhere yet; whichever future script assembles the `.app` needs to copy
  `AppIcon.icns` into `Contents/Resources/` to match the `Info.plist` key already in place.

`TESTING.md` (repo root) now has a full manual test guide covering both of the above plus the
still-open VM-boot gate and an end-to-end "connect a real NTFS drive" walkthrough (CLI, then GUI)
— read it before the next real-hardware test session.

- **`Settings.defaultMountMode`/`defaultMountPoint` wired for real** — `MountController.mount()`
  now takes real `mountPoint`/`readOnly` params. Real finding: neither anylinuxfs nor ntfs-3g have
  a flag to *request* read-only; the only lever is the NFS client-side `ro` mount option
  (`--nfs-options`), added end-to-end (CLI flag → XPC → GUI). Real review-caught HIGH, fixed:
  `AppState.MountState` gained `.mountedReadOnly` (distinct from `.mountedReadOnlyDirty`, which is
  specifically the *unintentional* dirty-journal fallback and drives the remount-anyway banner —
  must never fire for a deliberate read-only mount).
- **CLI uninstall + help** — `ntfsmac uninstall` (self-contained, real runtime state removed:
  `$PREFIX` tree, `~/.anylinuxfs`, `~/Library/Logs/anylinuxfs*.log`; `sudo` also removes the GUI's
  privileged helper), `ntfsmac help` lists all commands.
- **GUI privileged self-uninstall** — Preferences → "Uninstall ntfsmac" routes through the
  already-authorized helper (`removeDependencies` then `uninstallHelper`, ordering enforced in
  code) so dragging the `.app` to Trash afterward leaves nothing. Security-reviewed (approve).
  **Real, un-resolved policy flag for Kaveen, not decided here:** these 2 new actions are
  irreversible and system-wide, and sit behind the same best-effort, ad-hoc-signing-only identity
  check (`verifyClientIdentity`) that was previously only gating reversible actions
  (mount/unmount/pf toggle). That check's weakness was already accepted for L4 (ad-hoc signing, no
  cert chain) — this raises what it now guards. Worth a conscious go/no-go, not a silent ship.
- **`ui/prototype.html` deleted (Kaveen, 2026-07-13).** The original static HTML/SVG design comp
  is gone — `CLAUDE.md`, `PLAN.md` (§0 header, §4 Phase 3, §6 `3-xpc-helper`/`3-liquid-glass`, R10)
  updated to point at the already-built SwiftUI screens as the visual source of truth instead.
  Anything not yet built that still needed a literal-CSS lookup from the prototype (remaining
  `3-liquid-glass` polish, any un-walked states in `docs/dev/UITest.md`) now has to go off the
  running app + Kaveen's direction — flag if a specific value can't be recovered that way.

## DECISIONS

- License: MIT chosen for `p0-repo-layout` (not specified in PLAN.md/CLAUDE.md — no lock
  rule governs it; cheap to change later, flag if Kaveen wants otherwise).
- Toolchain: `rust`, `go`, `umoci`, `gh`, `shellcheck`, `bats-core` installed via
  `brew install` on the dev machine to support Phase V/CI work (build-toolchain taps only,
  per Phase V exit criteria "zero brew taps beyond build-toolchain ones").
- `v-audit`: Alpine packages trimmed 13→8 (kept: bash blkid cryptsetup lsblk mount nfs-utils
  ntfs-3g squashfs-tools; cut: btrfs-progs lvm2 mdadm ntfs-3g-progs zfs). Full evidence in
  `build/AUDIT.md`. **Reversed 2026-07-10:** Kaveen wants `cryptsetup` (LUKS/BitLocker
  encrypted-volume mount support) kept — don't cut features that help the experience. Re-added
  to the trimmed list. Wiring a passphrase param through the XPC mount surface is now an open
  item for Phase 2 (`2-mount`) / Phase 3 — PLAN.md's `mount(device, driver, tuning)` signature
  doesn't have one yet; flag when those units are reached.
- `v-audit` also found: `anylinuxfs/Cargo.toml` pins `libkrun` as a normal crates.io version
  (`1.19.3`), not a git dependency — `CLAUDE.md`'s "Cargo.lock exact commit" note assumed a git
  source. Cargo.lock is still the source of truth either way; just flagging the mechanism
  differs from what CLAUDE.md's table implies. Not blocking.

## OPEN PINS

All resolved as of `p0-sources-lock`, see `build/sources.lock`:
- `ANYLINUXFS_COMMIT=8aa9ccd6504e64ca26ce769c1623ed1741c6b7d3` (HEAD of default branch — no
  release tags exist upstream).
- `LIBKRUNFW_VERSION=v6.12.62-rev1` (nohajc fork) — images+modules sha256 pinned; verified
  against anylinuxfs's real `download-dependencies.sh`, which on macOS only needs the guest
  kernel Image archive + `modules.squashfs`, not the host-arch `libkrunfw-*.tgz` asset (that's
  a Cargo dependency instead).
- `VMNET_HELPER_VERSION=v0.12.0` (nirs) — sha256 pinned.
- `GVPROXY_VERSION=v0.8.9`, commit `9cfc86f66679ef0feed0f20ba1df558fe2bef5c6` — matches
  anylinuxfs's own `download-dependencies.sh` GVPROXY_VERSION, no drift.
- `ALPINE_TAG=3.23.5`, arm64 digest pinned (Docker Hub `library/alpine`).
- `LIBKRUN_COMMIT` deliberately **not** hand-pinned — PLAN.md says this comes from `Cargo.lock`
  at build time (`LIBKRUN_BRANCH=stable-1.19.x` constrains it). Not a HARD-STOP.

Note for `v-audit`: anylinuxfs's `download-dependencies.sh` fetches `init-freebsd` from
`nohajc/libkrun` releases and a prebuilt `gvproxy-darwin` binary — both confirm real behavior
of the settled PLAN.md cuts (never fetch init-freebsd; build gvproxy from source instead of
using the prebuilt). Not deviations, just upstream's own default differs from our trimmed build.

## FIXTURES

(none yet — will hold reusable bats mocks for anylinuxfs/mount and the Swift HelperClient mock)

## BLOCKED

(none yet)
