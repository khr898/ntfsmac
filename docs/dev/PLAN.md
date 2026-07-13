# ntfsmac — Full Build Plan

> NTFS read/write on Apple Silicon macOS, no kernel extension, no SIP modification.
> Wraps `anylinuxfs` (libkrun microVM running ntfs-3g, exported to macOS over NFS on a
> host-only vmnet bridge). CLI first, GUI second.
>
> **Companion docs:** `CLAUDE.md` (rules + vendored-source table), `GUI-PLAN.md` (Phase 3
> button-level spec). `ui/prototype.html` (the original locked-UI design comp) was removed
> 2026-07-13 — remaining GUI work is locked to the already-built screens, not a separate file.
>
> This file is the single source of build truth. It is written to be executed by
> **autonomous Claude Code loops**, including lower-tier implementer models. Read §0 before
> touching anything.

---

## §0 — RULES FOR IMPLEMENTER AGENTS (READ FIRST, EVERY ITERATION)

You are one worker in an autonomous DAG. You have a fresh context window. You do **not** know
anything this file does not state. Follow these rules literally.

### 0.1 The five hard rules

1. **Do exactly one work unit per run** — the unit named in your prompt. Do not start, "improve,"
   or "while I'm here" edit any other unit. Out-of-scope edits are rejected at merge.
2. **Never invent facts.** If a value is not written in this file, in `build/sources.lock`, in
   `build/AUDIT.md`, or in the file you are editing — you do **not** know it. Do not guess a
   version, a sha256, a URL, a package name, a flag, a path, or an API. See §0.3 (HARD-STOP).
3. **Every unit ships its own test.** No unit is "done" until its acceptance checks (listed in the
   unit) pass. Code with no passing check is unfinished — do not emit a completion signal.
4. **Obey the locked non-negotiables in §1.** They are settled. Do not "optimize," swap, or
   question them. Violating one is an automatic merge rejection.
5. **When blocked or unsure, STOP and write to `SHARED_TASK_NOTES.md`** under `## BLOCKED`, then
   emit `NTFSMAC_UNIT_BLOCKED:<unit-id>`. Do **not** proceed on a guess. A blocked unit is a
   success; a hallucinated unit is a failure that corrupts the build.

### 0.2 Never do these (auto-reject list)

- ❌ Never write `hard` in any NFS mount command. It is always `soft`. (§1)
- ❌ Never pass `ntfs3` as an `-o` mount option token. ntfs3 is selected only via `--fs-driver ntfs3`. (§1)
- ❌ Never call `sudo`, `mount`, `pfctl`, `route`, or `diskutil` for a privileged op from Swift/GUI
  or from a place other than the CLI/helper paths this plan defines. Privileged ops go through the
  SMJobBless helper only. (§3)
- ❌ Never use a device string in a shell command before it passes `^disk[0-9]+s[0-9]+$`. (§1, §3)
- ❌ Never fetch `init-freebsd`. Never build `freebsd-bootstrap` or `vmproxy-bsd`. (§1)
- ❌ Never pin an Alpine image to `:latest` — always tag **plus** digest. (§1)
- ❌ Never leave a literal `YOURUSERNAME` in any generated file — the repo owner is `khr898`. (§1)
- ❌ Never add a new external dependency, Cargo feature, or Alpine package that is not already
  justified in `build/AUDIT.md`. Adding one is a HARD-STOP (§0.3).
- ❌ Never create a new top-level `*.md` planning document. The only markdown files this build
  creates are build artifacts explicitly named in a unit (`build/AUDIT.md`, `SHARED_TASK_NOTES.md`).

### 0.3 HARD-STOP triggers — stop and ask Kaveen, never auto-proceed

Emit `NTFSMAC_UNIT_BLOCKED:<unit-id>`, record the reason in `SHARED_TASK_NOTES.md`, and wait if:

- A `build/sources.lock` pin you need (version / commit / sha256 / digest) is empty or missing.
- Dropping the `-F freebsd` Cargo feature does **not** compile clean (keep the flag, log why — §V).
- The change touches signing, entitlements, or the XPC/privilege boundary in any way that differs
  from §3 of this file.
- You would need a package / feature / dependency not listed in `build/AUDIT.md`.
- A destructive git operation (force-push, history rewrite, branch delete) would be required.
- Any instruction you were given conflicts with §1 (locked non-negotiables). §1 wins; stop.

### 0.4 Orientation: use graphify, not blind reads

`graphify-out/graph.json` exists. To understand how something connects, run
`graphify query "<question>"` or `graphify explain "<concept>"` **before** reading source files.
Read a raw file only to edit it or to check a specific line. This applies to sub-agents too.

### 0.5 What "done" looks like for a unit

1. All acceptance checks in the unit pass locally / in CI.
2. `build/sources.lock`, `build/AUDIT.md`, and `SHARED_TASK_NOTES.md` updated if the unit says so.
3. A de-sloppify pass has removed slop (see §7.2).
4. Branch lands on `main`. Then, and only then, emit `NTFSMAC_UNIT_COMPLETE:<unit-id>`.

---

## §1 — Locked non-negotiables (settled; do not re-litigate)

Copied from `CLAUDE.md`. These bind every unit.

| # | Rule |
|---|------|
| L1 | **Driver:** `ntfs-3g` is the default. `ntfs3` is opt-in **only** via `--fs-driver ntfs3`, never as an `-o` token. |
| L2 | **Transport:** NFS only, over the vmnet-helper host-only `/30` bridge. No SMB. No loopback / `127.94.0.1`. |
| L3 | **NFS mount mode is always `soft`.** Never `hard`. This is what prevents a kernel panic on hot-unplug. |
| L4 | **Signing:** ad-hoc only (`codesign -s -`). No paid Apple Developer account, no notarization. GUI ships DMG-only (never a Homebrew cask); CLI is a formula in the tap `khr898/ntfsmac` (never homebrew-core). |
| L5 | **Every mount / unmount / pf / route action goes through the SMJobBless XPC helper.** Never a raw `sudo` shell-out from Swift/UI. |
| L6 | **Device names validated against `^disk[0-9]+s[0-9]+$`** before any shell invocation — in the CLI **and** the GUI/helper (both, independently). |
| L7 | **Platform:** Apple Silicon (arm64) only, macOS 13.0+. No Intel fallback paths. |
| L8 | **Security & connection stability outrank speed.** Speed tuning (rsize/wsize/async export) is opt-in, documented as risk, never silently defaulted on. |
| L9 | **Vendored sources are exactly those in the `CLAUDE.md` table.** No forks/mirrors without an explicit Kaveen sign-off. Drop `freebsd-bootstrap`, `vmproxy-bsd`, and never fetch `init-freebsd`. |
| L10 | **Repo owner is `khr898`.** Repo `github.com/khr898/ntfsmac`; tap `khr898/ntfsmac`. No `YOURUSERNAME` literals. |

> SMJobBless note (non-blocking): `SMJobBless` is legacy on macOS 13+; `SMAppService` is the modern
> equivalent. `CLAUDE.md` mandates SMJobBless, so it stays. If Kaveen later approves `SMAppService`,
> that is a §3 change and a HARD-STOP until approved — not an implementer's call.

---

## §2 — Architecture & data flow

### 2.1 The stack (top to bottom)

```
macOS host (Apple Silicon, arm64, macOS 13.0+)

  GUI (Phase 3)              CLI (Phase 2)
  SwiftUI menu-bar,          zsh wrapper +
  LSUIElement                vendored binaries
        │ XPC                       │ XPC
        └───────────┬───────────────┘
                    ▼
        SMJobBless privileged helper (root)
          - validate device ^disk[0-9]+s[0-9]+$
          - drive anylinuxfs mount/unmount
          - pf/route ops (Phase 1)
          - NFS mount into /Volumes (soft)
                    │ spawns/supervises
                    ▼
        vmnet-helper (Apple-signed)  ── host-only /30 bridge ──┐
                    │                                          │
        libkrun microVM                              macOS NFS client (kernel)
          Alpine guest: ntfs-3g (or ntfs3)                     │
          + rpc.nfsd export + gvproxy net    ── NFS/TCP ──►  mount_nfs -o soft
                    ▲                                          │
        physical NTFS /dev/diskNsM (passed into VM)      /Volumes/<label>
```

### 2.2 Mount flow

1. Resolve physical device (`diskNsM`) via `anylinuxfs list`.
2. Request → helper over XPC. Helper **re-validates** the device name against `^disk[0-9]+s[0-9]+$`
   (it never trusts the caller).
3. Helper starts vmnet-helper → host-only `/30` bridge (host IP + guest IP).
4. Helper launches the libkrun microVM (libkrunfw kernel + trimmed Alpine rootfs); passes the raw
   block device through.
5. In-guest: `ntfs-3g` (default) or `ntfs3` (opt-in) mounts the device at `/mnt`; `rpc.nfsd` exports
   it; `gvproxy` bridges guest networking to vmnet.
6. Helper runs `mount_nfs -o soft <guest-ip>:/mnt /Volumes/<label>` on the host.
7. Finder sees a normal NFS volume.

### 2.3 Unmount / hot-unplug

- Clean: helper unmounts `/Volumes/<label>` → stop nfsd → shut down VM → tear down bridge → stop
  vmnet-helper.
- Hot-unplug: `soft` NFS times out instead of blocking the kernel → **no panic**. Poll-based
  dead-mount detection forces teardown. This is why L3 is non-negotiable.

---

## §3 — Trust / privilege boundary (non-negotiable)

| Zone | Runs as | May do | Must never do |
|------|---------|--------|---------------|
| GUI (SwiftUI) | user | show state, validate input, call XPC | `sudo`, shell mount, pf edits |
| CLI (zsh) | user | orchestrate, validate input, call helper | `sudo` for privileged ops |
| XPC helper | root (SMJobBless) | mount/unmount/pf/route, after re-validating | eval caller strings; accept an unvalidated device name |
| vmnet-helper | root (Apple-signed) | own the bridge | — |
| microVM guest | isolated (libkrun) | touch the passed block device only | reach host FS beyond that device |

**The trust boundary is the XPC interface.** Everything above it is untrusted. The helper treats
callers as hostile and re-validates. Validation is duplicated on purpose (L6): CLI/GUI validate for
UX, the helper validates for security.

**XPC surface (minimal, typed — no string eval):**

- `listDrives() -> [Drive]`
- `mount(device: String, driver: {ntfs3g|ntfs3}, tuning: TuningOpts?) -> MountResult`
- `unmount(mountID: String) -> Result`
- `applyPfRules(bridge: BridgeInfo) -> Result` / `teardown(mountID: String) -> Result`
- `status(mountID: String) -> StatusSnapshot`
- `diagnose() -> DiagBundle`

Every method taking a device string runs the L6 regex first, rejects + logs on fail. `tuning`
defaults to off; enabling it is explicit and logged as risk-accepted (L8).

---

## §4 — Phases: scope & exit criteria

Build order is **fixed**: `0 → V → 1 → 2` (CLI) fully working and installable **before** any Phase 3
(GUI) code. Phase 1 (pf hardening) is defense-in-depth and **deferrable** — CLI may ship without it,
but a deferral must be stated in release notes, never skipped silently.

### Phase 0 — Scaffolding & prereqs
Repo skeleton, tooling, `sources.lock` schema, submodule wiring, CI. No product code.
**Exit:** fresh `git clone` + `build/preflight.sh` passes on a clean M-series machine; `sources.lock`
schema committed.

### Phase V — Vendor (audit → trim → fetch/build → pin → sign)
Produce vendored binaries from pinned sources, trimmed to NTFS/arm64 needs. Audit (`v-audit`) is
**mandatory and first**.
**Exit:** `vendor/bin/anylinuxfs list` runs with zero brew taps beyond build-toolchain ones; runtime
kernel image == `sources.lock` libkrunfw pin; freebsd-free build compiles clean; every artifact
justified in `build/AUDIT.md`.

### Phase 1 — pf / route hardening (deferrable, non-blocking)
Lock the vmnet `/30` bridge so only host↔guest NFS flows; VPN-bypass safety; teardown on unmount/quit.
**Exit:** with the anchor loaded, guest reachable only from host on NFS; anchor + routes cleanly
removed on teardown; no residue.

### Phase 2 — CLI deliverables
Installable CLI for mount/unmount wrapping vendored anylinuxfs + the helper.
**Exit:** a clean M-series machine can install (`install.sh` or `brew install khr898/ntfsmac/ntfsmac`),
mount a real NTFS drive r/w via ntfs-3g, write+read back, unmount cleanly, and survive hot-unplug
without panic; `--fs-driver ntfs3` works. **All boxes ticked before Phase 3.**

### Phase 3 — SwiftUI menu-bar GUI
Menu-bar agent (`LSUIElement`) over the same XPC helper. UI is **locked** to the already-built
screens — no separate prototype file exists.
**Exit:** GUI mounts/unmounts via helper (no raw sudo), reflects every prototype state faithfully,
first-run installs the helper, ships as an ad-hoc-signed DMG that runs on a fresh M-series machine.

---

## §5 — Dependency DAG & parallelization

```
Phase 0 ─► Phase V ─┬─► Phase 2 (CLI) ──[HARD GATE]──► Phase 3 (GUI)
                    └─► Phase 1 (pf) ⇢ folds into helper; non-blocking (dashed)
```

| Layer | Units (∥ = parallel within layer) | Blocking dep |
|-------|-----------------------------------|--------------|
| P0-a | `p0-repo-layout` ∥ `p0-sources-lock` ∥ `p0-toolchain-preflight` | — |
| P0-b | `p0-submodule-anylinuxfs` ∥ `p0-ci` | P0-a |
| V-0 | `v-audit` | `p0-submodule-anylinuxfs` |
| V-1 | `v-fetch-prebuilt` ∥ `v-gvproxy` ∥ `v-alpine-rootfs` | `v-audit` |
| V-2 | `v-anylinuxfs-build` | V-1 |
| V-3 | `v-integration` (gate) | `v-anylinuxfs-build`, `v-gvproxy` |
| P1 (deferrable) | `1-pf-rules` ∥ `1-vpn-bypass`; then `1-teardown` | `v-integration` |
| 2-0 | `2-device-validation` | `v-integration` |
| 2-1 | `2-mount` ∥ `2-unmount` ∥ `2-diagnose`; then `2-fs-driver-flag` (after `2-mount`) | `2-device-validation` |
| 2-2 | `2-install-sh` → `2-signing` → `2-brew-formula` (sequential) | 2-1 |
| **GATE** | **CLI-before-GUI** — all Phase 2 exit criteria ticked | all Phase 2 |
| 3-0 | `3-xpc-helper` ∥ `3-menubar-shell` | GATE |
| 3-1 | `3-drive-detect` ∥ `3-diagnose-ui` | 3-0 |
| 3-2 | `3-mount-unmount` → (`3-status-speed` ∥ `3-dirty-ro-warning` ∥ `3-security-indicators` ∥ `3-open-finder`); `3-first-run-install` ∥ | 3-0/3-1 |
| 3-3 | `3-preferences` | `3-first-run-install` |
| 3-4 | `3-liquid-glass` (styling, solo — after all features) | all Phase 3 features |

Same-file overlaps that must **not** run in parallel: `2-mount` ↔ `2-fs-driver-flag` (share
`mount.sh`); feature units ↔ `3-liquid-glass` (touches many views).

---

## §6 — Task list (self-contained work units)

Each unit is a thin vertical slice for one isolated worktree. Format per unit: **Deps · Tier · Files ·
Do · Don't · Acceptance**. Tests ship inside the unit. Tier legend: `trivial`=implement→test ·
`small`=+code-review · `medium`=research→plan→implement→test→review→fix · `large`=+final-review.
Coverage ≥80% where testable (shell → `bats-core`; Rust → `cargo test`; Swift → XCTest/swift-testing;
sha256-checked downloads verified by checksum assertions, not unit tests).

### Phase 0 — Scaffolding

#### `p0-repo-layout`
- **Deps:** none · **Tier:** trivial
- **Files:** `README.md`, `.gitignore`, `LICENSE`, `cli/`, `helper/`, `gui/`, `build/`, `vendor/` (gitkeep), `tests/`
- **Do:** create the directory tree and top-level docs only.
- **Don't:** add product code; touch `sources.lock` (that's `p0-sources-lock`).
- **Acceptance:**
  - Tree exists with the five areas: `cli/ helper/ gui/ build/ vendor/`.
  - `.gitignore` excludes `vendor/bin/`, `vendor/kernel/`, `vendor/rootfs/`, `*.dmg`, `.DS_Store`, build artifacts.
  - `README.md` states: Apple-Silicon-only, ad-hoc-signed, DMG/tap-only distribution.

#### `p0-sources-lock`
- **Deps:** none · **Tier:** small
- **Files:** `build/sources.lock`, `build/lib/lock.sh`, `tests/build/lock.bats`
- **Do:** define the pin table with keys: `anylinuxfs` (commit), `libkrun` (commit), `libkrunfw`
  (version+sha256, **nohajc fork**), `vmnet-helper` (version+sha256, **nirs**), `gvproxy` (`v0.8.9`
  commit), `alpine` (tag+digest). Write `lock.sh get <key>`.
- **Don't:** invent any pin value — leave unknown pins as an explicit `TODO-KAVEEN` placeholder and
  record them under `## OPEN PINS` in `SHARED_TASK_NOTES.md`. A `TODO-KAVEEN` pin is a HARD-STOP for
  any unit that consumes it (§0.3). Do **not** add an `init-freebsd` key.
- **Acceptance:**
  - `lock.sh get <key>` returns each pinned value.
  - `lock.bats` asserts every required key present; asserts `init-freebsd` **absent**; asserts no key
    holds the literal `:latest`.

#### `p0-submodule-anylinuxfs`
- **Deps:** `p0-sources-lock` · **Tier:** trivial
- **Files:** `.gitmodules`, `vendor/src/anylinuxfs` (submodule), `tests/build/submodule.bats`
- **Do:** add the submodule at URL **exactly** `https://github.com/nohajc/anylinuxfs`, checked out at
  the `sources.lock` `anylinuxfs` commit.
- **Don't:** use any fork/mirror; pick a commit not in `sources.lock`.
- **Acceptance:** `submodule.bats` asserts the URL string and that the checked-out commit == lock value.

#### `p0-toolchain-preflight`
- **Deps:** none · **Tier:** small
- **Files:** `build/preflight.sh`, `tests/build/preflight.bats`
- **Do:** check presence + min versions of `cargo`/`rustup`, `go`, `umoci`, required brew build deps;
  print a pass/fail table; refuse non-arm64 hosts with a clear message.
- **Don't:** install anything automatically; assume a tool exists.
- **Acceptance:** exits non-zero if any required tool is missing, 0 when all present; `preflight.bats`
  stubs `PATH` to simulate missing tools and asserts exit codes + the non-arm64 refusal.

#### `p0-ci`
- **Deps:** `p0-repo-layout` · **Tier:** small
- **Files:** `.github/workflows/ci.yml`, `tests/run-all.sh`
- **Do:** workflow on a `macos-14` (arm64) runner; jobs: shellcheck + bats, `cargo test` (active once
  Phase V lands), a placeholder Swift job behind a path filter. `run-all.sh` discovers and runs all
  `*.bats`.
- **Don't:** target a non-arm64 runner.
- **Acceptance:** `run-all.sh` is green on the Phase 0 tree; workflow parses.

### Phase V — Vendor

#### `v-audit`  ← blocks all of Phase V
- **Deps:** `p0-submodule-anylinuxfs` · **Tier:** medium
- **Files:** `build/AUDIT.md`, `build/alpine-packages.trimmed.txt`
- **Do:** read the **actual** files (never memory/snippets): `init-rootfs/default-alpine-packages.txt`,
  `anylinuxfs/Cargo.toml`, `vmproxy/Cargo.toml`, `vmrunner-sys/Cargo.toml`, `init-rootfs/main.go` + its
  `go.mod`, `download-dependencies.sh`. In `AUDIT.md`, list every default Alpine package with a
  keep/cut decision justified against {ntfs-3g mount, rpc.nfsd export, blkid device detection}. Record
  the real current Cargo feature flags. Keep `blkid` (disk ID). Write the kept set to
  `alpine-packages.trimmed.txt`.
- **Don't:** cut any package on name alone — verify it isn't a transitive dep first. Any cut **beyond**
  the settled list (`freebsd-bootstrap`, `vmproxy-bsd`, `-F freebsd`) is a HARD-STOP: flag it for
  Kaveen, do not auto-apply.
- **Acceptance:** `AUDIT.md` covers every package with a justification; `freebsd` feature marked
  test-drop; `blkid` explicitly kept; `alpine-packages.trimmed.txt` written.

#### `v-fetch-prebuilt`
- **Deps:** `v-audit` · **Tier:** small
- **Files:** `build/fetch-prebuilt.sh`, `tests/build/fetch-prebuilt.bats`
- **Do:** download libkrunfw from **nohajc's fork** releases and vmnet-helper from `nirs/vmnet-helper`,
  both at the `sources.lock` version; verify sha256 against the lock **before** unpacking; abort +
  delete on mismatch.
- **Don't:** fetch from `containers/libkrunfw`; fetch `init-freebsd`; proceed if the pin is
  `TODO-KAVEEN` (HARD-STOP).
- **Acceptance:** `fetch-prebuilt.bats` feeds a wrong-checksum fixture and asserts abort + non-zero
  exit + no artifact left behind.

#### `v-gvproxy`
- **Deps:** `v-audit` · **Tier:** small
- **Files:** `build/build-gvproxy.sh`, `tests/build/gvproxy.bats`
- **Do:** build from `containers/gvisor-tap-vsock` at the lock commit/tag (`v0.8.9`) → `vendor/bin/gvproxy`;
  cross-check the tag against anylinuxfs's `download-dependencies.sh` and warn on drift.
- **Don't:** substitute a different version without a Kaveen sign-off.
- **Acceptance:** `gvproxy.bats` asserts `file vendor/bin/gvproxy` reports `arm64` and it is executable.

#### `v-alpine-rootfs`
- **Deps:** `v-audit` · **Tier:** medium
- **Files:** `build/init-rootfs.sh`, `tests/build/rootfs.bats`
- **Do:** pull alpine at the `sources.lock` tag **+ digest**; install exactly the packages in
  `alpine-packages.trimmed.txt`; output under `vendor/rootfs/`.
- **Don't:** use `:latest`; add a package not in the trimmed list.
- **Acceptance:** `rootfs.bats` greps the built image's package manifest: `ntfs-3g` and `rpc.nfsd`
  **present**; any audited-cut package (e.g. `btrfs-progs`/`xfsprogs`) **absent**.

#### `v-anylinuxfs-build`
- **Deps:** `v-audit`, `v-alpine-rootfs`, `v-fetch-prebuilt` · **Tier:** large
- **Files:** `build/build-all.sh`, `tests/build/build-all.bats`
- **Do:** build `anylinuxfs` + `vmproxy` **without** `-F freebsd`; output `vendor/bin/anylinuxfs`; run
  `cargo test` for the built crates; orchestrate the other build scripts in order; idempotent re-run.
- **Don't:** build `freebsd-bootstrap` or `vmproxy-bsd`; use nightly `-Z build-std`. If the
  freebsd-dropped build does **not** compile clean → keep the flag, record why in `AUDIT.md`, and
  HARD-STOP (§0.3) — do not drop blind.
- **Acceptance:** `build-all.bats` asserts the freebsd targets are not built and `cargo test` passes;
  `vendor/bin/anylinuxfs` exists and is arm64.

#### `v-integration`  ← Phase V exit gate
- **Deps:** `v-anylinuxfs-build`, `v-gvproxy` · **Tier:** medium
- **Files:** `build/verify-vendor.sh`, `tests/build/verify-vendor.bats`
- **Do:** run `vendor/bin/anylinuxfs list` with zero brew taps beyond build-toolchain; compare the
  runtime kernel image version/sha to the `sources.lock` libkrunfw pin; check installed binaries carry
  no `com.apple.quarantine` xattr.
- **Don't:** pass the gate if the kernel pin mismatches (that means libkrun's build-time libkrunfw
  leaked in) — HARD-STOP.
- **Acceptance:** `verify-vendor.bats` asserts `list` succeeds, kernel pin matches, and no quarantine
  xattr present.

### Phase 1 — pf / route hardening (DEFERRABLE)

#### `1-pf-rules`
- **Deps:** `v-integration` · **Tier:** medium
- **Files:** `cli/lib/pf-anchor.sh`, `cli/pf/ntfsmac.anchor.tmpl`, `tests/cli/pf-rules.bats`
- **Do:** generate a pf anchor scoping NFS to the host-only `/30` subnet only (deny-by-default, allow
  bridge); template the subnet, don't hardcode it.
- **Don't:** widen scope beyond the `/30`; hardcode an IP.
- **Acceptance:** `pf-rules.bats` renders the template with a sample `/30` and asserts the emitted rules
  match expected deny-by-default + allow-bridge scoping.

#### `1-vpn-bypass`
- **Deps:** `v-integration` · **Tier:** medium
- **Files:** `cli/lib/route-guard.sh`, `tests/cli/route-guard.bats`
- **Do:** add a host route so bridge traffic bypasses an active VPN default route without leaking NFS
  onto the tunnel; log the applied bypass.
- **Don't:** modify the VPN's own routes.
- **Acceptance:** `route-guard.bats` mocks `route`/`netstat` output and asserts the correct route command.

#### `1-teardown`
- **Deps:** `1-pf-rules` · **Tier:** small
- **Files:** `cli/lib/pf-teardown.sh`, `tests/cli/teardown.bats`
- **Do:** remove the ntfsmac pf anchor + the VPN-bypass route; idempotent (safe if already gone).
- **Don't:** flush pf rules outside the `ntfsmac` anchor.
- **Acceptance:** `teardown.bats` asserts `pfctl -a ntfsmac -F` + route-delete calls and exit 0 even
  when nothing to remove.

### Phase 2 — CLI

#### `2-device-validation`  ← shared foundation
- **Deps:** `v-integration` · **Tier:** small
- **Files:** `cli/lib/validate-device.sh`, `tests/cli/validate-device.bats`
- **Do:** one function that accepts only `^disk[0-9]+s[0-9]+$`; used by every shell-out path.
- **Don't:** let any caller build its own regex; accept `/dev/` prefixes.
- **Acceptance:** `validate-device.bats` — accepts `disk2s1`, `disk10s3`; rejects `disk2`,
  `disk2s1; rm -rf /`, `/dev/disk2s1`, empty string; returns non-zero + stderr on reject (≥80%).

#### `2-mount`
- **Deps:** `2-device-validation` · **Tier:** large
- **Files:** `cli/commands/mount.sh`, `cli/lib/nfs-mount.sh`, `tests/cli/mount.bats`
- **Do:** validate device first; bring up the anylinuxfs microVM; export NFS over the bridge; mount with
  mode **`soft`**; default driver `ntfs-3g`; default mount point `/Volumes/<label>`; report actionable
  success/failure.
- **Don't:** ever emit `hard`; skip validation; hardcode a device.
- **Acceptance:** `mount.bats` mocks anylinuxfs + `mount_nfs` and asserts: `soft` present (and `hard`
  absent), device validated before any shell call, correct exit codes.

#### `2-fs-driver-flag`
- **Deps:** `2-mount` (same file — schedule **sequentially**, not parallel) · **Tier:** small
- **Files:** `cli/commands/mount.sh` (flag-parse block), `tests/cli/fs-driver.bats`
- **Do:** `--fs-driver ntfs3` selects ntfs3 via the driver-selection path; absent/`ntfs-3g` keeps
  default; reject invalid values.
- **Don't:** inject ntfs3 as an `-o` token (L1).
- **Acceptance:** `fs-driver.bats` asserts each branch and that no `-o ntfs3` token is ever emitted.

#### `2-unmount`
- **Deps:** `2-device-validation` · **Tier:** medium
- **Files:** `cli/commands/unmount.sh`, `tests/cli/unmount.bats`
- **Do:** safe-unmount the NFS mount + tear down the microVM; call Phase-1 teardown **if installed**
  (soft-optional); handle already-unmounted / busy without hanging (soft-mount semantics).
- **Don't:** block indefinitely on a dead mount.
- **Acceptance:** `unmount.bats` mocks `umount` + anylinuxfs stop; asserts graceful busy/absent handling.

#### `2-diagnose`
- **Deps:** `2-device-validation` · **Tier:** medium
- **Files:** `cli/commands/diagnose.sh`, `tests/cli/diagnose.bats`
- **Do:** report vendor binaries present, vmnet-helper reachable, bridge up, kernel pin match,
  quarantine xattr status, current mounts; provide `--json` output (consumed later by GUI feature 7);
  exit code reflects health.
- **Don't:** perform any privileged op (diagnose is read-only).
- **Acceptance:** `diagnose.bats` covers healthy + each degraded branch and the JSON shape.

#### `2-install-sh`
- **Deps:** `2-mount`, `2-unmount`, `2-diagnose` · **Tier:** medium
- **Files:** `install.sh`, `tests/cli/install.bats`
- **Do:** default `NTFSMAC_REPO` to `khr898/ntfsmac`; install CLI + vendored binaries to a stable
  prefix; strip quarantine xattr on install; refuse non-arm64; verify ad-hoc signature before enabling.
- **Don't:** leave any `YOURUSERNAME` literal (L10).
- **Acceptance:** `install.bats` runs against a temp prefix; asserts layout, no quarantine xattr,
  `NTFSMAC_REPO` default, and non-arm64 refusal.

#### `2-signing`  ← contributes to CLI exit gate
- **Deps:** `2-install-sh` · **Tier:** small
- **Files:** `build/sign.sh`, `build/verify-signature.sh`, `tests/cli/signing.bats`
- **Do:** sign all shipped binaries with `codesign -s -` (ad-hoc); `verify-signature.sh` asserts every
  binary is ad-hoc signed with no `com.apple.quarantine`.
- **Don't:** add any paid-cert / notarization path (L4). Signing changes are a §3-adjacent HARD-STOP if
  they deviate from ad-hoc.
- **Acceptance:** `signing.bats` signs a fixture, verifies it, and asserts a tampered binary fails.

#### `2-brew-formula`
- **Deps:** `2-install-sh`, `2-signing` · **Tier:** medium
- **Files:** `Formula/ntfsmac.rb`, `tests/formula.bats` — live in the separate
  `khr898/homebrew-ntfsmac` tap repo, not this one (see `docs/dev/TAP_SETUP.md`); this repo keeps
  `install.sh` as its own direct CLI install path.
- **Do:** formula lives in the **tap** `khr898/ntfsmac`; installs the ad-hoc-signed CLI; `brew audit
  --strict` clean; post-install verifies no quarantine xattr.
- **Don't:** target homebrew-core; produce a cask (L4).
- **Acceptance:** `formula.bats`/audit asserts tap namespace + source (bottle-less) arm64 install.

> **✅ GATE-CLI-BEFORE-GUI:** every Phase 2 box ticked **and** `vendor/bin/anylinuxfs list` works from
> a clean `install.sh`. No Phase 3 unit may be scheduled until this fires. This is a hard gate (§4).

### Phase 3 — GUI (gated behind the CLI gate above)

> UI is **locked** to the already-built screens — `ui/prototype.html` (the original design comp)
> was removed 2026-07-13; do not redesign, match existing SwiftUI colors/radii/spacing/blur.
> Button/state spec is in `GUI-PLAN.md`; do not invent controls beyond it.

#### `3-xpc-helper`
- **Deps:** GATE-CLI-BEFORE-GUI · **Tier:** large
- **Files:** `helper/main.swift`, `helper/HelperProtocol.swift`, `helper/Info.plist`,
  `helper/launchd.plist`, `gui/Helper/HelperClient.swift`, `helper/Tests/HelperTests.swift`
- **Do:** expose XPC methods (mount, unmount, applyPfRules, teardown) per §3; re-validate device with
  `^disk[0-9]+s[0-9]+$` **inside the helper**; pin the helper↔client relationship via code-sign
  requirement (ad-hoc); reject unsigned/mismatched callers.
- **Don't:** shell out with `sudo` from the UI; skip in-helper validation (L5, L6). Any deviation from
  §3 is a HARD-STOP.
- **Acceptance:** `HelperTests` cover protocol encoding + in-helper device rejection cases.

#### `3-menubar-shell`
- **Deps:** GATE-CLI-BEFORE-GUI · **Tier:** medium
- **Files:** `gui/App/NtfsmacApp.swift`, `gui/Info.plist`, `gui/Status/StatusIcon.swift`,
  `gui/State/AppState.swift`, `gui/Tests/StatusIconTests.swift`
- **Do:** `LSUIElement` = true (no Dock icon); menu-bar icon + popover; map state→color exactly:
  grey=idle, blue(pulsing)=mounting, green=rw, yellow=ro-dirty, red=error; target macOS 13.0+.
- **Don't:** add a Dock icon or a main window (only Preferences + first-run per GUI-PLAN). If an API
  forces >13.0, document it (don't silently bump) — HARD-STOP if it conflicts with L7.
- **Acceptance:** `StatusIconTests` assert the state→color mapping for all five states.

#### `3-drive-detect` (GUI feature 1)
- **Deps:** `3-menubar-shell` · **Tier:** medium
- **Files:** `gui/Drives/DriveScanner.swift`, `gui/Views/DriveRow.swift`, `gui/Tests/DriveScannerTests.swift`
- **Do:** poll `anylinuxfs list`, parse into drive models, refresh on interval + manual Refresh (↻);
  render idle cleanly when empty.
- **Don't:** call privileged ops (listing is read-only).
- **Acceptance:** `DriveScannerTests` parse sample `list` output (incl. empty + malformed) into models.

#### `3-mount-unmount` (GUI feature 2)
- **Deps:** `3-xpc-helper`, `3-drive-detect` · **Tier:** medium
- **Files:** `gui/Actions/MountController.swift`, `gui/Views/DriveRow.swift` (button), `gui/Tests/MountControllerTests.swift`
- **Do:** `[Mount]`/`Unmount` call the XPC helper only; validate device regex before the call;
  transition idle→mounting→mounted/error in icon + popover.
- **Don't:** shell out; bypass the helper (L5).
- **Acceptance:** `MountControllerTests` mock `HelperClient`; assert routing through XPC and rejection
  of invalid device names.

#### `3-status-speed` (GUI feature 3)
- **Deps:** `3-mount-unmount` · **Tier:** small
- **Files:** `gui/Views/SpeedBar.swift`, `gui/Drives/ThroughputMonitor.swift`, `gui/Tests/ThroughputTests.swift`
- **Do:** read-only live throughput while mounting/mounted; hidden when idle; sample without privileged
  calls.
- **Acceptance:** `ThroughputTests` assert formatting + zero/idle handling.

#### `3-dirty-ro-warning` (GUI feature 4)
- **Deps:** `3-mount-unmount` · **Tier:** medium
- **Files:** `gui/Views/DirtyBanner.swift`, `gui/Actions/RemountController.swift`, `gui/Tests/DirtyStateTests.swift`
- **Do:** detect RO-because-dirty → yellow icon + non-dismissable banner with the **exact** GUI-PLAN
  copy; `Mount read/write anyway` requires an explicit confirm dialog spelling out corruption risk
  before re-mount via helper.
- **Don't:** allow the RO banner to be dismissed while RO; auto-remount r/w.
- **Acceptance:** `DirtyStateTests` assert the banner shows only in RO-dirty state and remount is gated
  behind confirm.

#### `3-security-indicators` (GUI feature 5)
- **Deps:** `3-mount-unmount` · **Tier:** small
- **Files:** `gui/Views/SecurityIndicators.swift`, `gui/Tests/SecurityIndicatorsTests.swift`
- **Do:** show isolated-network + VPN-bypass status from helper/diagnose state; when Phase 1 hardening
  is not installed, show "not enforced" — **never a false ✓**.
- **Acceptance:** `SecurityIndicatorsTests` assert on/off/unknown rendering per indicator.

#### `3-open-finder` (GUI feature 6)
- **Deps:** `3-mount-unmount` · **Tier:** trivial
- **Files:** `gui/Actions/FinderOpener.swift`, `gui/Tests/FinderOpenerTests.swift`
- **Do:** `Open in Finder` reveals the mount point via `NSWorkspace`; enabled only when mounted.
- **Don't:** shell out.
- **Acceptance:** `FinderOpenerTests` assert the workspace call target + disabled-when-idle.

#### `3-diagnose-ui` (GUI feature 7)
- **Deps:** `3-menubar-shell` · **Tier:** small
- **Files:** `gui/Views/DiagnosePanel.swift`, `gui/Actions/DiagnoseRunner.swift`, `gui/Tests/DiagnoseRunnerTests.swift`
- **Do:** run `ntfsmac diagnose --json`, render a plain-language summary; reachable from idle + error
  states; non-privileged.
- **Acceptance:** `DiagnoseRunnerTests` parse sample diagnose JSON (healthy + degraded) into summary rows.

#### `3-first-run-install` (GUI feature 8)
- **Deps:** `3-xpc-helper` · **Tier:** large
- **Files:** `gui/FirstRun/HelperInstaller.swift`, `gui/Views/FirstRunView.swift`, `gui/Tests/HelperInstallerTests.swift`
- **Do:** install the privileged helper via `SMJobBless` with exactly one auth prompt; detect
  already-installed and skip; deny/mismatch → plain-language cause + Retry (red icon); reuse this path
  for the Preferences "Reinstall privileged helper" button.
- **Don't:** deviate from SMJobBless / ad-hoc signing (§3, L4/L5) — HARD-STOP.
- **Acceptance:** `HelperInstallerTests` mock the install service; assert install/skip/deny branches.

#### `3-preferences`
- **Deps:** `3-menubar-shell`, `3-first-run-install` · **Tier:** medium
- **Files:** `gui/Preferences/PreferencesView.swift`, `gui/Preferences/Settings.swift`, `gui/Tests/SettingsTests.swift`
- **Do:** controls with GUI-PLAN defaults — Launch at login (off), Default mount mode (Read-write),
  Default mount point (`/Volumes/<label>`), Show speed in menu bar (off), Reinstall privileged helper
  (button → `3-first-run-install`); persist via `@AppStorage`/UserDefaults.
- **Don't:** add controls beyond the GUI-PLAN table.
- **Acceptance:** `SettingsTests` assert defaults + persistence round-trip.

#### `3-liquid-glass`  ← styling pass, last, solo
- **Deps:** all Phase 3 feature units · **Tier:** medium
- **Files:** `gui/Style/GlassTheme.swift`, `gui/Style/Colors.swift`, per-view `.glassEffect` /
  `NSVisualEffectView` modifiers
- **Do:** apply `glassEffect` / `GlassEffectContainer` / `NSVisualEffectView` matching the
  already-built screens' existing colors/radii/spacing (`ui/prototype.html`, the original design
  comp, was removed 2026-07-13 — no separate file to read values from anymore); use the
  `liquid-glass-design` skill patterns.
- **Don't:** re-design, invent colors/radii, or run in parallel with feature units (merge churn).
- **Acceptance:** visual parity per state, checked dark+light against the running app (screenshot
  diff or a committed manual sign-off checklist).

---

## §7 — Autonomous execution protocol

### 7.1 Overall driver — Ralphinho / RFC-driven DAG
This task list **is** the decomposition. Each §6 unit maps 1:1 to a work unit; the `Deps` lines define
the DAG layers in §5. Each unit runs in its own isolated worktree; non-overlapping units in a layer land
speculatively in parallel through the merge queue; overlapping units (`2-mount`↔`2-fs-driver-flag`,
features↔`3-liquid-glass`) land sequentially with rebase. Eviction on merge conflict or test failure
feeds full conflict/diff/test-output context into the next pass (max 3 passes) — never a blind retry.

### 7.2 Per-unit pipeline — sequential + de-sloppify, depth by tier
`trivial`: implement → test. `small`: + code-review. `medium`: research → plan → implement → test →
review → review-fix. `large`: + final-review. **The reviewer is never the author.** A de-sloppify pass
runs after every implement step (separate context, positive framing — not negative instructions):
remove tests of language/framework features, over-defensive checks for impossible states, dead code, and
stray debug output; **keep** real business-logic and security tests.

### 7.3 Completion signals
- Unit done (acceptance passing + landed on `main`): `NTFSMAC_UNIT_COMPLETE:<unit-id>`.
- Unit blocked (HARD-STOP): `NTFSMAC_UNIT_BLOCKED:<unit-id>` + a `## BLOCKED` note.
- Phase done: `NTFSMAC_PHASE_COMPLETE:<phase>`.
- Project done (after Phase 3, only if GATE-CLI-BEFORE-GUI fired first): `NTFSMAC_PROJECT_COMPLETE`.
- Use a **3-consecutive-signal** threshold before stopping the loop, to avoid spinning on finished work.

### 7.4 Guardrails
- Per unit: `--max-runs 6`; `--max-cost` by tier — trivial $2 / small $5 / medium $12 / large $25.
- Hard stops that escalate to Kaveen and never auto-proceed (also see §0.3): destructive git ops;
  any signing/entitlement/XPC change deviating from §3/L4/L5; unfilled `sources.lock` pins
  (`TODO-KAVEEN`); a `-F freebsd` drop that won't compile clean.

### 7.5 Cross-iteration memory — `SHARED_TASK_NOTES.md` (`docs/dev/`, alongside this file)
Updated at the end of every iteration. A fresh worker reads it first. Sections:
- `## GATES` — restate GATE-CLI-BEFORE-GUI and Phase-1-deferrable at the top, always.
- `## PROGRESS` — checklist mirroring §6 unit ids with landed / blocked status.
- `## DECISIONS` — audit cuts confirmed (`v-audit`), whether `-F freebsd` was dropped or kept-with-reason,
  resolved `sources.lock` pins, any forced macOS-target bump.
- `## OPEN PINS` — `TODO-KAVEEN` items still blocking.
- `## FIXTURES` — reusable bats mocks (anylinuxfs/mount) + the Swift `HelperClient` mock, so later units
  don't re-invent them.
- `## BLOCKED` — current HARD-STOPs awaiting Kaveen.

---

## §8 — Risks & mitigations

| # | Risk | Sev | Mitigation |
|---|------|-----|------------|
| R1 | Hot-unplug kernel panic (blocking I/O on removed device) | Critical | NFS `soft` always (L3); poll-based dead-mount detection + forced teardown. |
| R2 | Privilege escalation via unvalidated device string | Critical | `^disk[0-9]+s[0-9]+$` at CLI **and** helper (L6); typed XPC, no string eval (§3). |
| R3 | Gatekeeper blocks ad-hoc-signed app | High | DMG + documented right-click-open; verify no quarantine xattr; CLI via tap avoids GUI quarantine. |
| R4 | Upstream drift (anylinuxfs / gvproxy / libkrunfw) | High | Everything pinned in `sources.lock`; Cargo.lock exact commit for libkrun; verify gvproxy vs anylinuxfs download script. |
| R5 | Dependency bloat / building unneeded FreeBSD & fs tooling | Med | Mandatory `v-audit`; settled cuts; justify every artifact in `AUDIT.md`; verify transitive deps before cutting (blkid stays). |
| R6 | Dirty NTFS mounted r/w → corruption | High | Detect dirty flag; default RO + explicit warning (prototype RO/dirty state); user opts into rw knowingly. |
| R7 | Speed tuning corrupts on unstable link | Med | Off by default; opt-in only; documented as risk (L8). |
| R8 | vmnet bridge leaks to other interfaces | Med | Phase 1 pf anchor scopes to the `/30`; route cleanup on teardown. Flag if deferred. |
| R9 | SMJobBless legacy on 13+ | Med | Keep SMJobBless per CLAUDE.md; isolate behind one Swift module; `SMAppService` swap is a Kaveen decision. |
| R10 | GUI drifts from locked design | Low | Already-built screens are source of truth (`ui/prototype.html` removed 2026-07-13); no redesign. |

---

## §9 — Open decisions (resolve before / during the loop)

These are **not** implementer guesses — they are Kaveen calls. Until resolved, dependent units HARD-STOP.

1. **`sources.lock` pins** — libkrunfw version+sha256, vmnet-helper version+sha256, anylinuxfs commit,
   libkrun commit, gvproxy commit, alpine tag+digest. `v-fetch-prebuilt` / `v-alpine-rootfs` cannot run
   until filled (currently `TODO-KAVEEN`).
2. **`-F freebsd` drop** — test-first in `v-anylinuxfs-build`; if it won't compile clean, keep the flag
   and log why (do not block the whole phase on it).
3. **Phase 1 timing** — this plan treats pf hardening as post-Phase-2, non-blocking. Confirm, or say if
   you want it blocking before the CLI ships.
