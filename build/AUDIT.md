# build/AUDIT.md — `v-audit` (PLAN.md §6)

Every package/feature decision below is backed by evidence read from the real
`vendor/src/anylinuxfs` submodule at commit `8aa9ccd6504e64ca26ce769c1623ed1741c6b7d3`
(`ANYLINUXFS_COMMIT` in `build/sources.lock`) — never guessed. File:line citations are given
for every non-obvious call. Scope test: {ntfs-3g mount, rpc.nfsd export, blkid device
detection} per PLAN.md §6 `v-audit`.

## Alpine packages — `init-rootfs/default-alpine-packages.txt` (13 packages)

| Package | Decision | Evidence |
|---|---|---|
| `bash` | **KEEP** | `anylinuxfs/src/vm_image.rs:34` — `root_path.join("bin/bash")` is one of the files checked for rootfs validity (`required_files_exist`). Guest commands are run via `/bin/bash -c <cmd>` (`anylinuxfs/src/main.rs:731`). Hard requirement, not optional. |
| `blkid` | **KEEP** (settled, L-rule) | Disk identification — required by PLAN.md itself ("blkid-based device detection"). Also a shared-lib dependency (`libblkid.so.1`) of `lsblk`, `mount`, `nfs-utils`, `ntfs-3g-progs` per the real Alpine v3.23 aarch64 APKINDEX. |
| `btrfs-progs` | **CUT** | No source reference anywhere in `anylinuxfs`/`vmproxy`/`init-rootfs` beyond its own package-list entry. Not a transitive dependency of any kept package (APKINDEX: depends only on shared libs, all already satisfied elsewhere or unused once cut). BTRFS is a filesystem type ntfsmac doesn't support. |
| `cryptsetup` | **KEEP — reversed 2026-07-10** | Used for LUKS/BitLocker volume decryption: `vmproxy/src/main.rs:714` ("Decrypt LUKS/BitLocker volumes using cryptsetup"), `:752` (`Command::new("/sbin/cryptsetup")`). Originally cut (PLAN.md's XPC surface doesn't yet expose a passphrase param), but Kaveen wants encrypted-NTFS/BitLocker mount support preserved rather than silently dropped — feature cuts should not trade away user-facing capability. Kept in the trimmed list; wiring the passphrase param through the XPC surface is a Phase 2/3 task, not this audit's. |
| `lsblk` | **KEEP** | `anylinuxfs/src/diskutil/mod.rs:1146` runs `/bin/lsblk -O --json` inside the guest as the core of `get_lsblk_info`, used by both disk listing and mount device resolution. Confirmed hard dependency, not guessable from the package name alone. |
| `lvm2` | **KEEP** — corrected 2026-07-12, see below | Originally cut on the strength of one call site (`vgchange -ay`, confirmed harmless). Missed a second: `vmproxy/src/main.rs:1106-1120` — guest-side `vmproxy`'s own boot sequence unconditionally runs `mount_tmpfs()` over a fixed dir list including `/etc/lvm/archive` and `/etc/lvm/backup`, and `mount_tmpfs()` (`main.rs:633-640`) hard-`bail!`s on the first dir that doesn't exist. Those two dirs only exist because lvm2's Alpine postinstall script creates them — cutting the package removed the dirs, which crashed `vmproxy` on **every** VM boot (`Failed to mount tmpfs on /etc/lvm/archive` → guest exits 1 → host sees "libkrun VM exited with status: 1" → NFS server never comes up → mount fails). Confirmed against a real failing mount log, not assumed. Restored to keep the guest's fixed init-mount list intact; this is the sanctioned patch channel (swap the package list, never hand-edit the vendored submodule) already used for every other trim in this table. |
| `mdadm` | **CUT** | `anylinuxfs/src/diskutil/mod.rs:1150-1153` — `/sbin/mdadm --assemble --scan` only runs `if assemble_raid` (an explicit opt-in CLI flag for RAID arrays). ntfsmac's scope never sets this flag (no RAID support planned). Safe cut — the code path is never reached. |
| `mount` | **KEEP** | Used extensively and unconditionally: `/bin/mount` direct invocation (`vmproxy/src/main.rs:974`), `mount -t nfs -o ...` (`anylinuxfs/src/cmd_mount.rs:1056`, `anylinuxfs/src/fsutil.rs:322`), `mount -t tmpfs` for `/tmp`/`/run` setup in every guest script (`diskutil/mod.rs:1143-1144`, `main.rs:680`). Core requirement. |
| `nfs-utils` | **KEEP** (settled, L-rule) | Provides `rpc.nfsd`, explicitly required for the NFS export step of the mount flow (PLAN.md §2.2 step 5). Real APKINDEX shows it transitively pulls `rpcbind` and `python3` — both resolved automatically by `apk add nfs-utils`, no manual addition needed to the trimmed list. |
| `ntfs-3g` | **KEEP** (settled, L-rule) | Default driver (L1). Provides `mount.ntfs-3g`, `mount.ntfs`, `lowntfs-3g` — the actual FUSE mount binaries invoked for the default driver path. |
| `ntfs-3g-progs` | **CUT** | Provides `ntfsfix`, `ntfsresize`, `mkntfs`, `ntfslabel`, etc. Grepped the entire Rust source tree (`anylinuxfs/src`, `vmproxy/src`, `common-utils/src`) for every one of these tool names — **zero references**. Not invoked anywhere in the mount/unmount/diagnose flow. Dirty-volume detection (Phase 3 `3-dirty-ro-warning`) is handled by the FUSE driver itself at mount time (ntfs-3g's own dirty-bit check → automatic RO fallback), not by shelling out to `ntfsfix`. Can be re-added later if a repair feature is ever built — nothing in current PLAN.md scope calls for it. |
| `squashfs-tools` | **KEEP** — caught by audit, not assumption | Initially looked like a cut candidate (squashfs mounting is a kernel driver capability, not a userspace-tool need). Real evidence overturned that: `init-rootfs/main.go:345` embeds `unsquashfs -mem 32M -d $MOD_PATH modules.squashfs` into the **guest's own first-boot `vm-setup.sh`** (written via `writeSetupScript`, `main.go:325-350`), which unpacks the kernel-modules squashfs archive into `/lib/modules/$(uname -r)` at guest first boot. `unsquashfs` (from `squashfs-tools`) must be present in the guest image for this step to succeed. This is exactly the kind of transitive requirement PLAN.md warns not to cut on name alone. |
| `zfs` | **CUT** | No source reference beyond its own package-list line. ZFS is a filesystem type ntfsmac doesn't support. Its Alpine package deps (`libzfs`, `libnvpair`, etc.) are exclusive to it — nothing else in the trimmed set needs them. |

**Net result: 13 → 9 packages.** `bash blkid cryptsetup lsblk lvm2 mount nfs-utils ntfs-3g squashfs-tools`
written to `build/alpine-packages.trimmed.txt`.

## Cargo feature flags (real, read from the actual `Cargo.toml` files)

- `anylinuxfs/Cargo.toml`, `vmproxy/Cargo.toml`, `vmrunner-sys/Cargo.toml` — all three declare
  `default = ["freebsd"]` / `freebsd = []` (an empty marker feature; the actual `#[cfg(feature =
  "freebsd")]` gates live in the Rust source, e.g. `anylinuxfs/src/vm_image.rs:10`).
- Per PLAN.md's settled decision: **`-F freebsd` is marked test-drop.** Empirical
  "does it compile clean without the flag" verification is `v-anylinuxfs-build`'s job (tier
  `large`, has its own build+test step) — this audit only confirms the flag exists exactly as
  PLAN.md described and identifies where it's used, so that unit isn't guessing either.
- No other Cargo feature, dependency, or Alpine package beyond the settled cuts
  (`freebsd-bootstrap`, `vmproxy-bsd`, `-F freebsd`) is added or removed by this audit.

## Correction to CLAUDE.md's vendored-source table

`anylinuxfs/Cargo.toml` pins `libkrun = { version = "1.19.3", features = ["blk", "net"] }` — a
normal **crates.io** semver dependency, not a direct git dependency. `CLAUDE.md`'s table says
"Cargo.lock exact commit — not hand-edited," which assumes a git dependency; in reality the pin
that matters is the crates.io package version + Cargo.lock's checksum for that exact published
crate (still not hand-edited — same spirit, different mechanism). `build/sources.lock`'s
`LIBKRUN_COMMIT=SEE_CARGO_LOCK` entry still holds (Cargo.lock remains the source of truth), but
recorded here since it's a real discrepancy from the assumption in CLAUDE.md, not an invented
fact — flagged in `SHARED_TASK_NOTES.md` for Kaveen's awareness, not blocking.

## `init-freebsd` / `gvproxy-darwin` — confirms settled cuts are real, not just theoretical

`vendor/src/anylinuxfs/download-dependencies.sh` (upstream's own fetch script) does fetch
`init-freebsd` from `nohajc/libkrun` releases and a prebuilt `gvproxy-darwin` binary on macOS
hosts. This confirms the settled PLAN.md cuts are meaningful (upstream's default build includes
both) — ntfsmac's `v-fetch-prebuilt` must **not** replicate the `init-freebsd` fetch, and
`v-gvproxy` deliberately builds from source instead of using the prebuilt `gvproxy-darwin`
binary. Neither is a deviation from PLAN.md; both are the plan working as intended.

## `v-alpine-rootfs` build environment findings (2026-07-10)

Building `vmrunner-sys` (Rust, a `v-alpine-rootfs` dependency via the patched
`init-rootfs` Go tool) surfaced two real, repo-location-specific build bugs — not
upstream bugs, environment ones. Both are load-bearing for **any** future Cargo build
that pulls in `libkrun` from this repo (this will resurface in `v-anylinuxfs-build`,
which also depends on `libkrun` directly):

1. **Path-with-spaces breaks `krun-init-blob`'s build script.** This repo lives at
   `/Volumes/My Shared Files/Windows Shared Folder/ntfsmac` — a path containing
   spaces. `krun-init-blob`'s `build.rs` (pulled in transitively via `libkrun`)
   whitespace-splits the resolved `CC_LINUX` compiler path (the common
   `CC="ccache gcc"`-style convention of treating the env var as
   compiler-plus-flags), so a space in the path truncates it:
   `failed to execute /Volumes/My: No such file or directory`. Confirmed by building
   the identical vendored sources from a space-free path, which compiles clean.
   **Fix applied:** `build/init-rootfs.sh` builds the patched `vmrunner-sys`/`init-rootfs`
   copy from a space-free cache dir outside the repo (`$TMPDIR/ntfsmac-build/...`), not
   under `$REPO_ROOT/build/.cache/`. **Recommend `v-anylinuxfs-build` do the same** for
   building the `anylinuxfs` crate itself, to avoid re-discovering this.
2. **This repo's volume doesn't support the fsync/ioctl calls `go.podman.io/image`'s
   blob-copy step makes.** Real failure pulling the Alpine OCI image with output
   pointed at `vendor/rootfs/` (on this "Windows Shared Folder" network-mounted
   volume): `sync .../oci-put-blob...: inappropriate ioctl for device`. This is the
   same class of issue as the earlier `git add` failure on `graphify-out/graph.json`
   (session history) — this volume doesn't fully support POSIX semantics some tools
   assume. Plain writes (curl downloads, tar extraction, `go build`/`cargo build`
   output — see `vendor/kernel/`, `vendor/bin/`) work fine; it's specifically this
   fsync pattern that doesn't. **Fix applied:** the real Alpine pull/unpack also
   happens in the space-free off-volume cache dir, not `vendor/rootfs/` directly.
   **This means `build/init-rootfs.sh` cannot literally satisfy PLAN.md's "output
   under `vendor/rootfs/`" wording on this volume** — flagged in
   `SHARED_TASK_NOTES.md` for Kaveen; the script prints the real output path
   (`NTFSMAC_ROOTFS_HOME=...`) instead.
3. **New toolchain dependency: `lld`.** `cc_linux` (the vendored cross-compiler
   wrapper anylinuxfs already ships, used unmodified) invokes
   `/opt/homebrew/opt/llvm/bin/clang -fuse-ld=lld`; Homebrew's `llvm` formula does not
   bundle the `lld` linker — it's a separate formula. Installed via
   `brew install lld` (build-toolchain tap, consistent with Phase V's "zero brew taps
   beyond build-toolchain ones" exit criterion). Not yet added to `build/preflight.sh`
   — should be, since a fresh machine will hit the exact same failure.
4. **Real, confirmed empirical result:** `vmrunner-sys` compiles clean **without**
   `-F freebsd` (once the above two issues are worked around) — consistent with
   PLAN.md's settled "-F freebsd is test-drop" decision, now verified for this crate
   specifically (previously only asserted, not built).
5. **Real DAG gap found:** the vendored `init-rootfs` tool's full flow (pull → unpack →
   generate `vm-setup.sh` → embed `vmproxy` binary + `modules.squashfs` into the
   rootfs → boot a VM to actually run `apk add`) tries to copy `vmproxy` from a
   `libexec/` dir — but `vmproxy` is a `v-anylinuxfs-build` artifact, which PLAN.md's
   DAG (§5) places **after** `v-alpine-rootfs` (V-1 → V-2), not before. So
   `v-alpine-rootfs`, as literally scoped, cannot reach the VM-boot / real-apk-install
   step on a first pass. **What `build/init-rootfs.sh` verifies for real:** Alpine
   pulled at the digest-verified pin, unpacked, and `vm-setup.sh` generated with
   **exactly** our trimmed package list (`apk --update --no-cache add bash blkid
   cryptsetup lsblk mount nfs-utils ntfs-3g squashfs-tools` — confirmed byte-for-byte
   via a real run). This satisfies `v-alpine-rootfs`'s literal acceptance wording (the
   package manifest). **What's deferred:** vmproxy embedding + actual VM boot +
   real `apk add` execution — re-run `build/init-rootfs.sh` after `v-anylinuxfs-build`
   lands (it stages `vendor/bin/vmproxy` automatically if present) to complete and
   verify that part; `modules.squashfs` staging (from `v-fetch-prebuilt`'s output) is
   already wired and confirmed working.

## Integration note for `v-alpine-rootfs` (next unit, not resolved here)

`init-rootfs/main.go` embeds `default-alpine-packages.txt` via `//go:embed` at Go compile time
(`main.go:293`) and generates a first-boot `apk add` script from it (`writeSetupScript`,
`main.go:325`). `build/alpine-packages.trimmed.txt` (this unit's output) is the trimmed
replacement list, but *how* it gets substituted — patching anylinuxfs's embedded file before
building `init-rootfs`'s Go binary, vs. `build/init-rootfs.sh` building the rootfs directly via
`umoci` + our own `apk add` step bypassing anylinuxfs's Go tool — is `v-alpine-rootfs`'s decision
to make, not this audit's.
