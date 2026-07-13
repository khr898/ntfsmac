# Third-Party Licenses

ntfsmac's own original source code (the CLI, GUI, privileged helper, and build
scripts in this repository) is licensed under the MIT License — see
[LICENSE](LICENSE).

To do its job (NTFS read/write via a disposable Linux microVM, exported over NFS),
ntfsmac vendors, builds, and/or downloads several third-party components at build
time. Each retains its own upstream license. These components are **aggregated
with** ntfsmac's own code — run as a separate submodule build, a separate VM guest
kernel, or separately-distributed prebuilt binaries invoked as external
processes — not statically or dynamically linked into, nor a derivative work
incorporating, ntfsmac's own MIT-licensed code. Pinned versions/commits/hashes for
all of these live in [`build/sources.lock`](build/sources.lock).

| Component | License | Source | Usage |
|---|---|---|---|
| [anylinuxfs](https://github.com/nohajc/anylinuxfs) | GPL-3.0 | `github.com/nohajc/anylinuxfs` | Git submodule at `vendor/src/anylinuxfs`, built from source (`cargo build --release`) into `vendor/bin/anylinuxfs`, run as a separate host-side process. License text vendored unmodified at `vendor/src/anylinuxfs/LICENSE`. |
| Linux kernel (via libkrunfw) | GPL-2.0 | `github.com/nohajc/libkrunfw` (releases; this is nohajc's fork, not `containers/libkrunfw` upstream) | Prebuilt guest kernel image + modules, downloaded by `build/fetch-prebuilt.sh` into `vendor/kernel/`. Runs as the boot kernel *inside* the disposable libkrun microVM guest — a separate execution context from ntfsmac's own host-side binaries, never linked into them. |
| [libkrun](https://github.com/containers/libkrun) (branch `stable-1.19.x`) | Apache-2.0 | `github.com/containers/libkrun` | Cargo dependency of `anylinuxfs` (and `vmrunner-sys`), compiled as part of the `anylinuxfs` build above; provides the microVM hypervisor runtime. |
| [vmnet-helper](https://github.com/nirs/vmnet-helper) | Apache-2.0 | `github.com/nirs/vmnet-helper` (releases) | Apple-signed prebuilt binary, downloaded by `build/fetch-prebuilt.sh` into `vendor/bin/vmnet-helper`, run as a separate host-side helper process to bring up the host-only vmnet bridge. |
| [gvproxy](https://github.com/containers/gvisor-tap-vsock) (tag `v0.8.9`) | Apache-2.0 | `github.com/containers/gvisor-tap-vsock` | Built from source (Go) by `build/build-gvproxy.sh` into `vendor/bin/gvproxy`, run as a separate host-side process for guest network proxying. |
| Alpine Linux rootfs base | Mixed (per-package; no single blanket license) | Docker Hub `library/alpine`, pinned tag + digest in `build/sources.lock` | Pulled via `umoci` by `build/init-rootfs.sh` to assemble the guest VM's root filesystem. Only the trimmed package set in `build/alpine-packages.trimmed.txt` is included — see `build/AUDIT.md` for what was cut and why. Each Alpine package carries its own upstream license; consult the [Alpine package license index](https://pkgs.alpinelinux.org/packages) for a given package's specific license if needed.

## Why aggregation, not linking

- `anylinuxfs`, `gvproxy`, and `vmnet-helper` are separate executables invoked by
  ntfsmac's CLI/helper via `exec`/process spawn — no shared address space, no
  static or dynamic linking against ntfsmac's own binaries.
- The Linux kernel + Alpine rootfs run as the guest operating system inside a
  libkrun microVM — an entirely separate machine context from the macOS host
  process that ntfsmac's own code runs in.
- `libkrun` is a Cargo dependency of `anylinuxfs` itself (compiled into the
  `anylinuxfs` binary, not into any ntfsmac-authored binary) — it is upstream's
  dependency, inherited unmodified via the pinned submodule build.

If you redistribute a build of ntfsmac, you are responsible for complying with
each of the above licenses for the corresponding vendored/built artifact (e.g.
including GPL-3.0/GPL-2.0 source-availability obligations for anylinuxfs and the
kernel, and Apache-2.0 NOTICE requirements for libkrun/vmnet-helper/gvproxy).
