# ntfsmac

> New here? [README.md](README.md) has install/usage; [CONTRIBUTING.md](CONTRIBUTING.md) has
> human setup steps. This file (mirrored at [AGENTS.md](AGENTS.md)) is AI-agent instructions —
> read it before generating code in this repo, human or agent.

NTFS read/write on Apple Silicon macOS, no kernel extension, no SIP modification. Wraps `anylinuxfs` (libkrun microVM running ntfs-3g, exported to macOS over NFS on a host-only vmnet bridge). CLI first, GUI second — build order is fixed, don't jump ahead.

Full spec: **`docs/dev/PLAN.md`** (architecture, phases, build steps) and **`GUI-PLAN.md`** (SwiftUI menu-bar app, button-level spec). Read the relevant phase section before writing code for it — don't work from memory of what these say. `ui/prototype.html` (the original static HTML/SVG design comp) was removed 2026-07-13 — the already-built SwiftUI screens are now the visual source of truth for colors, radii, spacing, and the vibrancy/blur recipe. Match what's already built; don't re-design.

## Non-negotiables (do not re-litigate)

- **Driver:** ntfs-3g default. ntfs3 is opt-in only via `--fs-driver ntfs3`, never via an `-o` token (it's inert there).
- **Transport:** NFS only, over vmnet-helper host-only `/30` bridge. No SMB. No loopback/`127.94.0.1` design — that's dead, don't resurrect it.
- **NFS mount mode stays `soft`** — never switch to `hard`, it's what prevents a kernel panic on hot-unplug.
- **Signing:** ad-hoc only (`codesign -s -`). No paid Apple Developer account, no notarization. This is why the GUI is DMG-only (never a Homebrew cask) and the CLI is a formula in Kaveen's own tap (never homebrew-core).
- **Every control that mounts/unmounts/touches pf/route goes through the SMJobBless XPC helper** — never a raw `sudo` shell-out from Swift UI code.
- **Device names validated against `^disk[0-9]+s[0-9]+$`** before any shell invocation, in both CLI and GUI/helper.
- **Platform:** Apple Silicon only. Don't add Intel fallback paths.
- Security and connection stability outrank speed. Speed tuning (rsize/wsize/async export) is opt-in and documented as risk, never silently defaulted on.

## Build order

CLI (Phase 0 → V → 1 → 2) fully working and installable before any Phase 3 GUI code. Phase 1 (pf hardening) is defense-in-depth, not blocking — CLI can ship without it and gain it later, but don't skip it silently; call it out if deferring.

## Stack & environment

- CLI: zsh scripts + vendored Rust/Go binaries (built via Phase V, not hand-written by us).
- GUI: Swift + SwiftUI, menu-bar agent (`LSUIElement`, no Dock icon), macOS 13.0+ target unless a specific API forces higher — verify, don't assume.
- Dev machine: MacBook M3 Pro, Parallels available for VM-based testing if ever needed (shouldn't be — no Linux VM step exists in this build).
- Kaveen's language background: Python/Java, newer to Rust/Swift/shell and to CI/CD, licensing, security-policy infra. Explain non-boilerplate Rust/Swift/shell decisions briefly when introducing them; don't over-explain repeated patterns.

## Working style

- Kaveen reviews and decides; doesn't want to hand-write boilerplate. Generate full files/scripts, flag the specific lines that need a decision.
- Deliver complete, consolidated output per unit of work — not incremental step-by-step prompting. A "unit" = one phase's deliverables, or one component build script, not the whole project at once.
- Don't pause mid-task for confirmation on mechanical steps. Do stop and ask before: destructive git operations, anything touching signing/entitlements in a way that deviates from PLAN.md, or scope decisions PLAN.md leaves open (e.g. version pins not yet filled in `sources.lock`).
- Errors get reported after Kaveen runs something, not pre-emptively hedged against. Don't pre-apologize for code that hasn't been tested yet.
- Direct, casual, no filler, no encouragement padding. Flag scope creep against PLAN.md explicitly if a request drifts from it.

## Repo identity

Own repo: `github.com/khr898/ntfsmac`, remote `git@github.com:khr898/ntfsmac.git`. **`PLAN.md` still has `YOURUSERNAME` placeholders in several spots** (target repo line, tap install instructions, `install.sh`'s `NTFSMAC_REPO`, release notes template) — treat `YOURUSERNAME` as `khr898` wherever it appears in PLAN.md rather than leaving it literal in generated code/scripts. Homebrew tap is `khr898/ntfsmac`.



Everything vendored/built comes from these. Use these exact repos — don't substitute forks or mirrors without flagging it.

| Component | Source | Pin method |
|---|---|---|
| anylinuxfs (submodule, Rust CLI + build scripts) | `https://github.com/nohajc/anylinuxfs` | git submodule, pinned commit in `build/sources.lock` |
| libkrun (Cargo dep of anylinuxfs + vmrunner-sys) | `https://github.com/containers/libkrun`, branch `stable-1.19.x` | `Cargo.lock` exact commit — not hand-edited |
| libkrunfw (kernel image + modules, vendored prebuilt) | `https://github.com/nohajc/libkrunfw/releases` — this is nohajc's fork, NOT `containers/libkrunfw` upstream | version + sha256 in `build/sources.lock` |
| vmnet-helper (Apple-signed, vendored prebuilt) | `https://github.com/nirs/vmnet-helper/releases` | version + sha256 in `build/sources.lock` |
| gvproxy (built from source, pure Go) | `https://github.com/containers/gvisor-tap-vsock`, tag `v0.8.9` (verify against anylinuxfs's `download-dependencies.sh` for drift before building) | commit in `build/sources.lock` |
| Alpine rootfs base (pulled by init-rootfs via umoci) | Docker Hub `alpine` image | pin to a specific tag + digest in `build/sources.lock` — never `alpine:latest` |

Don't fetch: `init-freebsd` (containers/libkrun releases) — FreeBSD guest init, not needed for NTFS, do not add to `sources.lock` or `fetch-prebuilt.sh`.

## Dependency trimming — build only what NTFS/CLI/macOS-arm64 needs

We are not copying anylinuxfs's already-compiled binaries or its full default build — we build from source ourselves specifically so unnecessary parts can be cut. Every vendored/built artifact should be justified by: does the CLI (and later GUI) need this for NTFS mount/unmount on Apple Silicon? If not, cut it.

**First Phase V task, before any build script is written: audit the real source.** Claude Code has `git clone` access this chat didn't — use it. Clone the `nohajc/anylinuxfs` submodule per V.2, then actually read (don't guess from memory or search snippets):
- `init-rootfs/default-alpine-packages.txt` — the real current package list. One confirmed data point from a public error log: it's 13 packages including `bash`, `blkid`, `btrfs-progs` — the rest were not verified and should not be assumed. Read the actual file and cut anything not required for {ntfs-3g mount, rpc.nfsd export, blkid-based device detection}. Filesystem tools for fs types ntfsmac doesn't support (btrfs-progs, xfsprogs, zfs userspace, mdadm/lvm2 if not needed for the target use case) are the likely cut candidates — but confirm against the real file and against what ntfs-3g/rpc.nfsd actually depend on before removing anything, since some "unrelated-looking" packages may be transitive requirements.
- `anylinuxfs/Cargo.toml`, `vmproxy/Cargo.toml`, `vmrunner-sys/Cargo.toml` — the actual current feature flags, not just the `freebsd` one PLAN.md already names.
- `init-rootfs/main.go` and its go.mod — confirm which OCI/umoci pull options and embedded config are or aren't needed.

Known cuts already decided in PLAN.md — treat these as settled, not open questions:

- **Drop `freebsd-bootstrap` entirely and the FreeBSD `vmproxy-bsd` cross-build.** Optional guest support for FreeBSD filesystems, irrelevant to NTFS, pulls in a separate nightly toolchain + `-Z build-std` cross-build for zero feature value.
- **Test dropping the `freebsd` feature flag** (`-F freebsd`) from the `anylinuxfs` and `vmproxy` Cargo builds. Confirm it still compiles clean without the flag before committing to it — don't drop blind.
- **Never fetch `init-freebsd`** from libkrun releases (see table above).

Beyond this settled list: if a build step, Cargo feature, Alpine package, or fetched artifact isn't clearly required for {NTFS mount, ntfs-3g default / ntfs3 opt-in, NFS export over vmnet, Apple Silicon}, don't silently include it — call it out and confirm with Kaveen before adding it to `sources.lock`, `build-all.sh`, or the Alpine package list. This is an ongoing decision, not a one-time pass — re-check it any time a new upstream component gets pulled in. Never remove a package/feature without confirming it isn't a transitive dependency of something that is needed (e.g. `blkid` looks droppable but is almost certainly required for disk identification — verify before cutting, don't cut on name alone).



- After Phase V: `vendor/bin/anylinuxfs list` works with zero brew taps beyond build-toolchain ones; runtime kernel image matches the `sources.lock` pin, not whatever libkrun's build-time libkrunfw dragged in.
- Before any Homebrew formula work: confirm ad-hoc signed binaries carry no quarantine xattr from the install path used.
- Before Phase 3 starts: Phase 2 CLI deliverables in PLAN.md are all checked off.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
