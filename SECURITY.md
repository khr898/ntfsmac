# Security Policy

ntfsmac runs a privileged XPC helper (SMJobBless) that can mount/unmount filesystems and
touch `pf`/route state, and drives a Linux microVM with a host-only network bridge. Treat
anything in `helper/`, `gui/Helper/`, `gui/FirstRun/`, and the mount/unmount CLI paths as
security-sensitive.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a suspected vulnerability. Instead, email
the maintainer directly or use GitHub's private
[security advisory](../../security/advisories/new) form for this repo. Include:

- Affected component (CLI, GUI, XPC helper, or the vendored microVM path).
- Steps to reproduce, and the macOS/hardware combination it was found on.
- Impact you'd expect (e.g. privilege escalation, arbitrary mount target, network bridge
  escape).

Expect an acknowledgment within a few days. This is a solo-maintained project — response
time isn't SLA-backed, but security reports get priority over feature work.

## Scope notes

- **Signing:** ad-hoc only (`codesign -s -`), no notarization. That's a known, accepted
  trust-model limitation (see `CLAUDE.md`'s non-negotiables) — reports that just restate
  "this isn't notarized" without a concrete exploit path aren't actionable findings.
- **Device validation:** every command path validates device identifiers against
  `^disk[0-9]+s[0-9]+$` before any shell invocation, in both the CLI and the GUI/helper. A
  bypass of that check is a valid, high-priority report.
- **Privilege boundary:** every mount/unmount/pf/route action must route through the
  SMJobBless XPC helper. A code path that shells out to `sudo` directly from GUI code, or an
  XPC caller-identity check that can be spoofed, is a valid, high-priority report.
