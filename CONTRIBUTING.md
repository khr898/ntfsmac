# Contributing

## Before you start

Read [`docs/dev/PLAN.md`](docs/dev/PLAN.md) (architecture, phases, build order) and, for GUI work,
[`GUI-PLAN.md`](GUI-PLAN.md) (button-level spec). Build order is fixed — CLI (Phase 0 → V →
1 → 2) before any Phase 3 GUI work — don't jump ahead. [`CLAUDE.md`](CLAUDE.md) /
[`AGENTS.md`](AGENTS.md) has the non-negotiables (driver default, transport, signing,
privilege boundary) — don't re-litigate those in a PR without discussion first.

## Setup

- Apple Silicon Mac, macOS 13.0+. No Intel fallback is supported or planned.
- Clone with submodules: `git clone --recurse-submodules <repo-url>` (or
  `git submodule update --init` after a plain clone — `vendor/src/anylinuxfs` is a
  submodule).
- CLI build/install: `./install.sh` (refuses non-arm64, ad-hoc signs, strips quarantine
  xattrs).
- GUI build: `swift build` via `Package.swift`, or open in Xcode.

## Testing

- Manual test guide (real hardware, outside a sandboxed agent environment):
  [`docs/dev/TESTING.md`](docs/dev/TESTING.md).
- Automated: `.github/workflows/ci.yml` runs on push/PR.

## Making changes

- Keep the CLI and GUI in sync with `PLAN.md`/`GUI-PLAN.md` — if a change drifts from what
  those docs specify, update the doc in the same PR, don't silently diverge.
- Every mount/unmount/pf/route control change must keep going through the SMJobBless XPC
  helper — see [`SECURITY.md`](SECURITY.md).
- Device identifiers must stay validated against `^disk[0-9]+s[0-9]+$` in both CLI and
  GUI/helper before any shell invocation.

## Pull requests

- Conventional commit-style messages (`feat:`, `fix:`, `refactor:`, …).
- Note which `PLAN.md`/`GUI-PLAN.md` unit(s) the change addresses, if any.
- Security-sensitive changes (XPC helper, privilege boundary, pf/route handling) should call
  that out explicitly in the PR description.
