# ntfsmac GUI — Feature & Button Plan

> Custom SwiftUI menu-bar app (no Dock icon). Wraps the CLI + pf security layer via an XPC helper.
> Companion to `PLAN.md` Phase 3 — that covers engineering scaffolding; this covers what the user sees and taps.

## Design principles

- **One job, zero clutter.** Pick a drive, mount it, get out of the way.
- **Status at a glance.** Menu-bar icon colour tells the whole story without opening the popover.
- **Never lie about safety.** If a drive mounts read-only (dirty journal), say so loudly before the user trusts a write.

---

## App shape

Menu-bar agent → click icon → popover. No windows except Preferences and the first-run helper prompt.

### Menu-bar icon states

| Colour | Meaning |
|--------|---------|
| Grey | Idle, nothing mounted |
| Blue (pulsing) | Mounting |
| Green | Mounted read/write |
| Yellow | Mounted **read-only** (dirty journal) |
| Red | Error |

---

## Features

**v1 (MVP — ship with the GUI):**
1. Auto-detect compatible drives (polls `anylinuxfs list`).
2. One-click mount / unmount.
3. Live mount status + transfer speed.
4. Dirty-drive read-only detection + warning.
5. Security indicators (isolated network ✓, VPN-bypass ✓).
6. Open mounted volume in Finder.
7. Diagnose (runs the CLI diagnostic, shows result).
8. First-run helper install (one auth prompt, via SMJobBless).

**v2 (later):**
- Launch at login toggle.
- Per-drive default mount options (ro/rw, mount point).
- Multi-drive mounts (gated on upstream vmnet-helper / concurrent-mount support).
- Notifications on mount/unmount/error.
- Eject-all.

---

## Button & control plan

### Popover — idle (no mount)

| Control | Action | Enabled when |
|---------|--------|--------------|
| Drive row `[Mount]` | Mount that drive r/w via XPC helper | A compatible drive is detected |
| Refresh (↻) | Re-scan drives now | Always |
| `Diagnose` | Run CLI diagnostic, show summary | Always |
| ⚙ (gear) | Open Preferences | Always |
| `Quit` | Exit app, tear down network state | Always |

### Popover — mounted

| Control | Action | Enabled when |
|---------|--------|--------------|
| `Open in Finder` | Reveal mount point | Mounted |
| `Unmount` | Safe unmount + pf/route teardown | Mounted |
| Speed bar | Live throughput (read-only display) | Mounting / mounted |
| ⚙ / `Quit` | As above | Always |

### Read-only (dirty) state — extra

| Control | Action |
|---------|--------|
| Warning banner | "Mounted read-only — drive has an unclean journal. Eject safely in Windows to enable writing." (non-dismissable while RO) |
| `Mount read/write anyway` | Re-mount r/w **only after** an explicit confirm dialog spelling out corruption risk |

### Error state

| Control | Action |
|---------|--------|
| Error message | Plain-language cause (helper not installed, binary missing, mount failed) |
| `Retry` | Re-attempt last action |
| `Diagnose` | Jump to diagnostics |

### Preferences window

| Control | Type | Default |
|---------|------|---------|
| Launch at login | Toggle | Off |
| Default mount mode | Segmented: Read-only / Read-write | Read-write |
| Default mount point | Path picker | `/Volumes/<label>` |
| Show speed in menu bar | Toggle | Off |
| Reinstall privileged helper | Button | — |

---

## Control → privilege boundary (non-negotiable)

Every control that mounts, unmounts, or touches pf/route goes through the **SMJobBless XPC helper** — never a raw `sudo` shell-out from the UI. Device names are validated against `^disk[0-9]+s[0-9]+$` in *both* the UI and the helper before any shell call. (Mirrors `PLAN.md` §4.2.)
