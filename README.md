# ntfsmac

NTFS read/write (and ext2/3/4) on Apple Silicon macOS — no kernel extension, no SIP modification.

Wraps [`anylinuxfs`](https://github.com/nohajc/anylinuxfs) (a `libkrun` microVM running
`ntfs-3g`), exported to macOS over NFS on a host-only `vmnet` bridge. CLI first, GUI second.

## Why

macOS does not have native NTFS write support. The usual fixes are a kernel extension
(blocked by newer SIP policy) or a paid third-party driver. ntfsmac takes a third path: a
disposable Linux microVM does the actual NTFS write, and macOS just mounts it over NFS —
no kext, no SIP toggle, no System Extension approval dance.

The same microVM path also mounts **ext2, ext3, and ext4** partitions: the guest kernel's
built-in `ext4` driver handles all three (blkid auto-detects the type — no `--fs-driver`
needed). No extra packages or kernel modules ship for it; `ext4.ko`/`jbd2.ko`/`mbcache.ko`
are already built into the vendored kernel image.

## What's new

- **Network proxy configuration (GUI & CLI)** — configure Direct, System, or Custom HTTP/HTTPS/SOCKS5 proxies for microVM setup, OCI downloads, and guest package updates. Supports automatic macOS System Settings detection via `scutil`, `install.sh --proxy`, and environment variables with automatic credential masking.
- **In-app software updates (GUI)** — check for updates directly within the GUI Settings window, stream download progress, verify bundle integrity, and relaunch seamlessly with active-mount protection.
- **Pre-installed Alpine runtime for instant first mount** — the installer pre-provisions and configures the Alpine Linux microVM runtime upfront, eliminating first-mount download wait times.
- **Proactive Full Disk Access guidance** — automated FDA detection immediately guides helper permissions post-setup and in diagnostics before permission errors occur.
- **BitLocker encrypted volume support** — mount BitLocker-encrypted Windows partitions directly from the GUI or CLI using your password or 48-digit numerical recovery key.
- **ext2/3/4 mount support** — mount Linux ext2, ext3, and ext4 partitions the same way as
  NTFS. The guest kernel's built-in ext4 driver handles all three (blkid auto-detects the
  type, no `--fs-driver` flag needed); no extra packages or kernel modules ship for it.
- **Multiple concurrent mounts** — mount more than one drive at once. The CLI mounts each
  device independently, and the GUI's mounted view lists every mounted drive with its own
  status and speed indicator (the old single-drive "Combined" speed readout is gone).
- **More useful, privacy-safe diagnostics** — CLI and GUI reports identify expected and detected
  host-runtime versions, audited source commits, the installed Alpine/cache version and guest
  package versions, plus app/build, system, helper, kernel, network, and mount health without
  exposing local paths or network identity.
- **Reproducible first-run environment** — the runtime pulls an immutable Alpine arm64 digest,
  keeps versioned caches side by side, and packaging rejects floating image references.
- **Authoritative mount state and transport diagnostics** — the GUI reconciles anylinuxfs session
  evidence with the host NFS mount table, while diagnostics fail closed unless an active ntfsmac
  mount uses the expected private vmnet path and effective `soft` NFS parameters.
- **Per-session network security** — each mount owns its evaluated PF child anchor, PF enable
  reference, and only the exact VPN-bypass host route it needs; teardown never flushes global PF
  state or removes another session's route.
- **iCloud Private Relay & VPN compatibility** — `--preserve-private-relay` (CLI) and Settings toggle (GUI) prevent macOS PF firewall activation from interrupting iCloud Private Relay while preserving the exact microVM host route.

## Requirements

- **Apple Silicon (arm64) only.** No Intel fallback.
- macOS 13.0+.

## Install

CLI, via Homebrew tap:

```sh
brew tap khr898/ntfsmac
brew install ntfsmac
ntfsmac diagnose
```

GUI: download the latest ad-hoc-signed `.dmg` from [Releases](../../releases) — not
distributed as a Homebrew cask (see [Signing & distribution](#signing--distribution)).

## Usage

```sh
ntfsmac mount [disk identifier]      # mounts read/write (omit to pick from connected drives)
ntfsmac mount disk4s1                           # prompts for password if BitLocker-encrypted
echo "$KEY" | ntfsmac mount disk4s1 --bitlocker-credential-stdin # non-interactive BitLocker mount
ntfsmac mount disk4s1 --preserve-private-relay  # keep iCloud Private Relay / VPNs uninterrupted
ntfsmac mount disk4s1 --read-only               # mount read-only
ntfsmac mount disk4s1 --fs-driver ntfs3         # opt into kernel ntfs3 driver (default: ntfs-3g)
ntfsmac unmount [disk identifier]    # unmounts a drive (omit to pick from active mounts)
ntfsmac diagnose                     # environment + bridge + helper health check
ntfsmac diagnose --json              # structured JSON health check for bug reports
ntfsmac uninstall                    # removes CLI, runtime state, and the GUI's privileged helper
ntfsmac help
```

### Mount Options

- `[device]` — Device identifier: partition (`diskNsM`, e.g. `disk4s1`) or unpartitioned whole disk (`diskN`, e.g. `disk4`). Omit to interactively select from detected drives.
- `[mount_point]` — Custom mount path (default: `/Volumes/<label>`).
- `--bitlocker-credential-stdin` (or `--recovery-key-stdin`) — Reads the BitLocker password or 48-digit recovery key from stdin (never exposed in argv, process lists, or shell history).
- `--preserve-private-relay` — Bypasses host `pfctl -E` to keep iCloud Private Relay active while still installing the `/32` endpoint host route to prevent VPN tunnel capture.
- `--read-only` — Client-side read-only NFS mount (`ro`).
- `--fs-driver ntfs-3g|ntfs3` — NTFS driver choice (default: `ntfs-3g`). Ext2/3/4 drives automatically use the kernel ext4 driver.
- `--ignore-permissions` — Maps ownership to local user (`all_squash`). Passed automatically for ext drives.

### BitLocker Volumes (GUI & CLI)

ntfsmac unlocks BitLocker-encrypted NTFS and FAT volumes with your user password or 48-digit numerical recovery key (`xxxxxx-xxxxxx-xxxxxx-...`).

- **In the GUI**:
  1. Connected BitLocker partitions appear with the `BitLocker` label in the menu-bar popover.
  2. Click **Mount**. An unlock dialog overlay opens with a secure password field.
  3. Type your BitLocker password or recovery key and click **Unlock & Mount** (or press Return).
  4. If a volume was previously mounted read-only due to an unclean Windows shutdown, the yellow **Dirty Banner** also offers an inline credential prompt to unlock and remount read/write.
  5. The password is kept strictly in transient memory during mount; it is never stored in macOS Keychain, app settings, or disk files.

- **In the CLI (Interactive Terminal)**:
  Run `ntfsmac mount diskNsM` (or run bare `ntfsmac mount` and pick the drive from the menu). If the volume is BitLocker-encrypted, ntfsmac prompts you securely:
  ```text
  Enter BitLocker password or recovery key for disk4s1: 
  ```
  Terminal echo is turned off (`read -s`), so your password is not shown on screen and is **never written to shell history** (`~/.zsh_history` or `~/.bash_history`).

- **In the CLI (Scripted / Automation)**:
  Pipe the password or recovery key via standard input using `--bitlocker-credential-stdin`:
  ```sh
  echo "111111-222222-333333-444444-555555-666666-777777-888888" | ntfsmac mount disk4s1 --bitlocker-credential-stdin
  ```
  Or stream it from a password manager:
  ```sh
  op read "op://vault/drive/password" | ntfsmac mount disk4s1 --bitlocker-credential-stdin
  ```
  Credentials are piped directly to the microVM via an unlinked anonymous descriptor (`/dev/fd/9`) — secrets never appear in `argv`, process inspection (`ps aux`), or logs.

Device identifiers are validated against `^disk[0-9]+(s[0-9]+)?$` before any command touches
them — supporting both sliced partitions (`disk4s1`) and unpartitioned whole-disk volumes
(`disk4`, such as BitLocker To Go USB flash drives) — see [SECURITY.md](SECURITY.md).

### Network Proxy Configuration (GUI & CLI)

For corporate networks, VPNs, or environments with restricted internet access, ntfsmac can route microVM downloads and package provisioning through a network proxy:

- **In the GUI**:
  1. Open **Settings** (gear icon) in the menu-bar popover.
  2. Under **Network Proxy**, choose your desired mode:
     - **Direct**: Connect directly without a proxy.
     - **System**: Automatically detect HTTP/HTTPS/SOCKS proxy configuration from macOS System Settings.
     - **Custom**: Enter a custom proxy URL (e.g. `http://127.0.0.1:7890` or `http://user:pass@proxy.example.com:8080`).
  3. Settings synchronize atomically to `~/.anylinuxfs/config.toml` under `[network]` and apply automatically to microVM operations.
  4. If first-run microVM initialization encounters connectivity issues, the setup view provides an immediate action to configure your proxy and retry.

- **In the CLI & Installer**:
  - Pass `--proxy` during installation:
    ```sh
    sudo bash install.sh --proxy http://127.0.0.1:7890
    ```
  - Or set standard proxy environment variables in your shell:
    ```sh
    export NTFSMAC_PROXY="http://127.0.0.1:7890"
    # Or HTTP_PROXY / HTTPS_PROXY / ALL_PROXY
    ```
  - Check active proxy configuration anytime with `ntfsmac diagnose`:
    ```text
    diagnose: network proxy: http://127.0.0.1:7890 (source: config)
    ```
    Sensitive credentials in proxy URLs are automatically masked (`***`) across terminal outputs and JSON diagnostics.

## Troubleshooting

Installed but a drive won't mount, or the app "starts but does nothing"? Run the built-in
health check first — it's read-only and never mounts anything:

```sh
ntfsmac diagnose          # human-readable
ntfsmac diagnose --json   # same data on one line, handy for bug reports
```

From the GUI, a normal click on **Diagnose** shows the plain-language summary. For a developer
report, hold **Command (⌘)** while clicking **Diagnose**: ntfsmac runs the same read-only
`diagnose --json` command and opens a save panel for a formatted `.json` file. You choose where
the file is written; ntfsmac never uploads or sends it automatically. Review it if desired, then
attach it manually to a bug report.

What each line means:

| `diagnose` line | Meaning / fix |
| --- | --- |
| `ntfsmac version: <release> (<build>)` | Identifies the exact app/CLI build that produced the report. The same value appears below the Settings title. |
| `macOS version: <ver>` / `architecture: <arch>` | Must be **13.0+** and `arm64`. An `unsupported` note is fatal. |
| `network proxy: <url> (source: <source>)` | Reports active network proxy configuration (`direct`, `system`, `config`, or `environment`) with credentials masked. |
| `privileged helper: installed` | Required by the GUI for privileged mount/network operations. A CLI-only installation can legitimately report `not installed`. |
| `vendor binaries missing: N` (N > 0) | A vendored binary (`anylinuxfs`/`gvproxy`/`vmnet-helper`/`vmproxy`) wasn't found. Reinstall: `brew reinstall ntfsmac`, or re-run `install.sh`. |
| `quarantined binaries: N` (N > 0) | Gatekeeper quarantined a vendored binary, so it won't launch. Reinstall (the installer strips the xattr), or clear it: `xattr -dr com.apple.quarantine <path>`. |
| `kernel pin: mismatch` / `missing` | The pinned `modules.squashfs` kernel image doesn't match `sources.lock`. Reinstall to restore the pinned image. |
| `anylinuxfs version: <detected> (expected <version>)` | Separates the installed host runtime from the audited source version. A mismatch is degraded and should be repaired by reinstalling. |
| `Alpine runtime: <state>` | Reports the approved tag/digest and whether the matching versioned cache is complete, missing, legacy, interrupted, or mismatched; Diagnose never downloads or deletes a cache. |
| `guest ntfs-3g` / `guest nfs-utils` | Reports fixed package-version tokens read from the selected guest cache, or `not installed` / `unavailable` without exposing local paths. |
| `vmnet bridge: down` | Expected when nothing is mounted; it should read `up` while a volume is mounted. If it stays `down` during a mount, approve the vmnet-helper permission prompt and retry. |
| `active network helper: <state>` | Uses fixed privacy-safe tokens to distinguish `vmnet`, `gvproxy`, mixed, missing, or unavailable evidence. |
| `NFS transport contract: <state>` | Active ntfsmac mounts are healthy only when they resolve inside the private vmnet pool, route through a bridge, use effective `soft` parameters, and have no loopback NFS listener. |
| `VPN default route: detected` | A tunnel owns the default route. This is informational; the report does not record which VPN/interface or any address/route details. |
| `current NFS mount count: N` | Number of active NFS mounts, without their names or paths. |
| `overall: degraded` | One of the fatal checks above failed — fix that line first. |

When macOS asks for Full Disk Access it may show the standalone privileged tool with a generic
executable icon and its technical service name, `com.khr898.ntfsmac.helper`. This is **ntfsmac
Helper**, not an unrelated package; enable that exact entry. The SMJobBless helper is one signed
executable rather than an app/resource bundle, so its icon cannot be customized independently
without changing the privileged-helper architecture.

**Pre-installed Alpine runtime (instant first mount).** Installation (`install.sh`) and GUI
auto-staging pre-install and configure the approved Alpine Linux arm64 runtime upfront, enabling
drives to mount instantly offline without waiting on a first-mount download. If the cache is ever
cleared or missing, the runtime initializes automatically on first mount against the approved tag
and SHA-256 digest pinned in `sources.lock` (~50–150 MB).

**Can't write to an ext volume / `Operation not permitted`.** ext2/3/4 are real
Unix filesystems with their own ownership bits, so ntfsmac auto-passes
`--ignore-permissions` for any ext-family drive (the NFS export gets
`all_squash,anonuid=0,anongid=0` and the macOS mount gets `noowners` — files appear
owned by you and are writable). You should not need to pass `--ignore-permissions`
yourself for ext; if an ext mount is read-only, reinstall (older CLI builds had a bug
that skipped the flag for unlabeled ext drives). Verify the flag reached the mount:

```sh
mount | grep nfs     # expect "noowners" in the options for an ext volume
```

If `noowners` is present but `ls`/`cp` on the mounted volume still says
`Operation not permitted`, the volume is writable but **macOS is blocking the
app's access to the mount point** — a privacy/TCC gate, not an NFS permission
issue. This only affects access *from that app*:

- **GUI** — the ntfsmac app proactively checks and guides Full Disk Access on initial setup
  and launch. Grant it once in macOS System Settings and the GUI reads/writes without issue.
- **CLI** — Terminal needs Full Disk Access **only if you want to write from
  the Terminal** (e.g. `cp`, `tee`, shell redirects into `/Volumes/<vol>`).
  With Terminal FDA off, the mount is still writable — Finder and other
  FDA-granted apps can read/write it — but Terminal itself gets
  `Operation not permitted`. To use the CLI for writes, grant it: **System
  Settings → Privacy & Security → Full Disk Access → add Terminal**, restart
  Terminal. Readers who only ever write via Finder can leave Terminal FDA off.

**Unpartitioned raw volumes / whole disks (`disk4`).** ntfsmac supports both partitioned
drives (`diskNsM`, e.g. `disk4s1`) and unpartitioned whole-disk volumes (`disk4`, common for
BitLocker To Go USB flash drives and raw-formatted disks) — device identifiers are validated
against `^disk[0-9]+(s[0-9]+)?$`. When macOS shows "The disk you attached was not readable by
this computer" because it does not recognize BitLocker, `diskutil list` shows the drive as `disk4`
with no slice rows. ntfsmac detects and mounts the raw volume directly:

```sh
ntfsmac mount disk4
```

Filing a bug? Please include:

- the `ntfsmac diagnose --json` output, or the JSON file saved with **⌘-click Diagnose** in the GUI,
- your macOS version (`sw_vers -productVersion`) and Mac model,
- the disk identifier you used, in `diskNsM` or `diskN` form (e.g. `disk4s1`, or unpartitioned `disk4`).

For security issues, see [SECURITY.md](SECURITY.md) — please don't file those publicly.

## GUI

Menu-bar app (no Dock icon): pick a drive, mount it, get out of the way. Menu-bar icon color
tells the whole story — grey idle, blue mounting, green mounted read/write, yellow mounted
read-only (dirty journal), red error. Full button-level spec in [GUI-PLAN.md](docs/dev/GUI-PLAN.md).

Includes in-app software updates (Settings → Check for Updates), BitLocker unlock dialogs,
proactive Full Disk Access guidance, and real-time per-drive throughput monitors.

<div align="center">
  <table>
    <tr>
      <td valign="middle" align="center"><img src="docs/screenshots/ss1.jpg" alt="ntfsmac popup screenshot 1" width="250"></td>
      <td valign="middle" align="center"><img src="docs/screenshots/ss2.jpg" alt="ntfsmac popup screenshot 2" width="250"></td>
      <td valign="middle" align="center"><img src="docs/screenshots/ss3.jpg" alt="ntfsmac popup screenshot 3" width="250"></td>
    </tr>
  </table>
</div>


## Architecture

```
macOS ── NFS (soft mount) ──> vmnet host-only bridge ──> libkrun microVM ── ntfs-3g ──> NTFS drive
```

Every control that mounts, unmounts, or touches `pf`/route state goes through a SMJobBless
XPC helper — the GUI never shell-outs to `sudo` directly. Full architecture and phased build
plan: [docs/dev/PLAN.md](docs/dev/PLAN.md).

`MountController.mountedDrives` is a presentation cache, not proof of a mount. The GUI pairs
anylinuxfs status with the macOS NFS mount table on launch, popover open, Refresh, after helper
completion, and on a bounded poll. Missing or contradictory evidence remains recoverable but is
shown as warning/unknown rather than green.

The privileged mount transaction measures the newly created private `/30`, installs and reads back
a direct child of the evaluated macOS `com.apple/*` PF path, acquires one PF enable reference, and
repairs only an exact VPN-captured guest route before the backend NFS readiness check can complete.
State is root-owned and per device; unmount and stale-session recovery release only resources whose
ownership can still be proven.

## Signing & distribution

Ad-hoc signed only (`codesign -s -`) — no paid Apple Developer account, no notarization.
That's why the GUI ships as a DMG (never a Homebrew cask) and the CLI lives in a personal
tap (never `homebrew-core`).

## Status

CLI-first build, currently in the Phase 3 GUI build-out. See
[docs/dev/PLAN.md](docs/dev/PLAN.md) for the full phase plan.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Working with an AI coding agent? Start with
[CLAUDE.md](CLAUDE.md) (also readable as [AGENTS.md](AGENTS.md)).

## Security

Please report vulnerabilities per [SECURITY.md](SECURITY.md) rather than filing a public issue.

## License

MIT — see [LICENSE](LICENSE).
