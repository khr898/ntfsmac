import Foundation
import Security
import Darwin
import CryptoKit

// Shared between the privileged helper (`ntfsmac-helper`) and the GUI client
// (`gui/Helper/HelperClient.swift`). PLAN.md §3: the XPC interface is the trust boundary —
// everything in this file is untrusted input until `validateDevice` / `isValidUnmountTarget`
// says otherwise, and the helper re-validates independently of whatever the GUI already checked.

/// PLAN.md L6 — device names are validated against this pattern before touching any shell
/// invocation, in both the CLI (`cli/lib/validate-device.sh`) and here, independently.
public let deviceNamePattern = "^disk[0-9]+s[0-9]+$"

public func validateDevice(_ device: String) -> Bool {
    device.range(of: deviceNamePattern, options: .regularExpression) != nil
}

/// Shared `/Volumes/`-rooted path shape check: non-traversal, and — security review finding
/// (2026-07-13, CRITICAL, originally scoped to `mount`'s `mountPoint` only) — no shell
/// metacharacters, since the vendored `anylinuxfs::cmd_mount::mount()` splices this unescaped
/// into a `sh -c` string (`mount -t nfs ... "<mount_point>"` / the mirror unmount path) and a
/// value containing `"` can break out of that quoted argument. Security review finding
/// (2026-07-13, HIGH): `unmount`'s target got only the traversal check, not this blocklist,
/// despite feeding the same vendored mount/unmount code — nothing proved the unmount path
/// doesn't have the same unescaped-splice shape as mount's. Shared here so the two validators
/// can't drift apart again.
private func isValidVolumesPath(_ path: String) -> Bool {
    guard path.hasPrefix("/Volumes/"), !path.contains("..") else { return false }
    let forbidden = CharacterSet(charactersIn: "\"'`$\\;\n\r&|<>(){}*?~")
    return path.rangeOfCharacter(from: forbidden) == nil
}

/// `anylinuxfs unmount` (and our `cli/commands/unmount.sh` wrapper) accepts either a bare
/// `diskNsM` device or an already-resolved mount point — mirrors `unmount.sh`'s own comment.
/// A bare device still runs the full L6 regex; a path goes through `isValidVolumesPath`.
public func isValidUnmountTarget(_ target: String) -> Bool {
    if validateDevice(target) { return true }
    return isValidVolumesPath(target)
}

/// `mount`'s optional `mountPoint` — see `isValidVolumesPath`.
public func isValidMountPoint(_ path: String) -> Bool {
    isValidVolumesPath(path)
}

/// `applyPfRules`/`teardown`'s `subnetCIDR` gate. Security review finding (2026-07-13, HIGH):
/// `cli/lib/pf-anchor.sh` loads this value into a root `pfctl` anchor with no format/scope check
/// — a syntactically valid but overly wide CIDR (e.g. `0.0.0.0/0`) would violate the anchor's
/// own "never widen scope beyond the subnet" invariant. The vmnet-helper host-only bridge this
/// project uses is always an RFC1918-private `/30` (PLAN.md "vmnet-helper host-only `/30`
/// bridge") — this checks exactly that shape, independent of whatever the caller claims.
public func isValidSubnetCIDR(_ cidr: String) -> Bool {
    let parts = cidr.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, parts[1] == "30" else { return false }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    var bytes: [UInt8] = []
    for octet in octets {
        guard octet.count >= 1, octet.count <= 3, octet.allSatisfy(\.isNumber), let value = UInt8(octet) else { return false }
        bytes.append(value)
    }
    // RFC1918 private ranges only — 10/8, 172.16/12, 192.168/16.
    switch bytes[0] {
    case 10: return true
    case 172: return bytes[1] >= 16 && bytes[1] <= 31
    case 192: return bytes[1] == 168
    default: return false
    }
}

/// `stageCLI`'s input check — same discipline as `validateDevice`/`isValidUnmountTarget`
/// (never trust the caller). `build/package-app.sh` only ever produces one relative layout;
/// this string match is what pins the helper to running *that* script and nothing an
/// unprivileged caller could point elsewhere. `..` is rejected outright — a literal absolute
/// path suffix match already can't be satisfied by a traversal, but reject defense-in-depth
/// rather than rely solely on the suffix check.
public func isValidStageCLIPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("..") && path.hasSuffix("/Contents/Resources/cli-src/install.sh")
}

/// Deterministic content hash over every regular file under `directory` — sorted relative
/// paths, each file's SHA-256 digest folded in that order into one combined digest. Security
/// review finding (2026-07-12, CRITICAL): `isValidStageCLIPath`'s shape check alone doesn't
/// prove the caller-supplied `install.sh` is the genuine, untampered one this app shipped —
/// ad-hoc signing (L4) means `codesign -v` on the individual copied binaries only proves
/// internal self-consistency, not authenticity, and `verifyClientIdentity`'s pid-based check can
/// be spoofed by any locally ad-hoc-signed process claiming the same identifier string. This
/// hash is what actually closes that gap: the *expected* value is compiled into this helper
/// binary at build time (`GeneratedCLIManifest.expectedTreeHashHex`, written by
/// `build/package-app.sh` before the shipped build, verified reproducible via a throwaway first
/// build pass using this exact function) — something only the trusted build pipeline can set,
/// not a caller of the XPC API, not even one that fully spoofs `verifyClientIdentity`.
/// `stageCLI` recomputes this over the caller-supplied path's containing directory and refuses
/// to execute anything that doesn't match bit-for-bit.
public func computeTreeHash(at directory: URL) -> String? {
    guard let enumerator = FileManager.default.enumerator(
        at: directory.standardizedFileURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }

    let prefix = directory.standardizedFileURL.path
    var relativePaths: [String] = []
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return nil
        }
        // Security review finding (2026-07-13, CRITICAL): the previous `isRegularFile`-only
        // filter silently excluded symlinks from the hash — their presence/target contributed
        // nothing to `actualHash`, so a symlink planted anywhere under `directory` (dereferenced
        // by `install.sh` or anything it sources) bypassed the tamper check entirely. Fail
        // closed instead: a build-generated `cli-src/` tree should never legitimately contain a
        // symlink, so any symlink here — file or directory — rejects the whole hash rather than
        // being silently skipped.
        if values.isSymbolicLink == true { return nil }
        guard values.isRegularFile == true else { continue }
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(prefix + "/") else { continue }
        relativePaths.append(String(path.dropFirst(prefix.count + 1)))
    }
    guard !relativePaths.isEmpty else { return nil }
    relativePaths.sort()

    var combined = SHA256()
    for relativePath in relativePaths {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(relativePath).path) else { return nil }
        combined.update(data: Data(relativePath.utf8))
        combined.update(data: Data(SHA256.hash(data: data)))
    }
    return combined.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Fixed resolution path for vendored binaries the helper shells out to. `install.sh`'s CLI
/// path writes here directly; the GUI's first-run installer (`3-first-run-install`) stages its
/// own bundled copies to the same prefix so the privileged helper — which runs standalone under
/// launchd after SMJobBless, no `Bundle.main` back to the .app — always resolves one fixed path
/// regardless of which install path produced it.
public let installPrefix = "/usr/local/ntfsmac"

/// Second candidate: Homebrew's own version-independent `opt/<formula>` symlink (always
/// present once `brew install ntfsmac` links it, Apple Silicon default prefix — this project
/// is arm64-only per CLAUDE.md, so no Intel `/usr/local` brew prefix to also check). The
/// Formula deliberately keeps normal `bin.install`/`libexec.install` (Homebrew forbids `sudo`
/// during `brew install`, so it can never write the fixed `installPrefix` above) — this second
/// candidate is what lets the privileged helper find a brew-tap-only install without either
/// side needing to know about the other's install mechanism.
public let homebrewOptPrefix = "/opt/homebrew/opt/ntfsmac"

public let ntfsmacCandidatePrefixes = [installPrefix, homebrewOptPrefix]

/// Picks whichever candidate actually has a real `bin/ntfsmac` on disk, first-listed wins.
/// Falls back to `installPrefix` (the documented default) when neither is present — same
/// behavior every caller already hardcoded before this existed, so injecting this as a
/// default parameter value never changes what a from-clean unit test observes.
public func resolveNtfsmacPrefix(fileManager: FileManager = .default) -> String {
    for candidate in ntfsmacCandidatePrefixes where fileManager.isExecutableFile(atPath: "\(candidate)/bin/ntfsmac") {
        return candidate
    }
    return installPrefix
}

public let helperMachServiceName = "com.khr898.ntfsmac.helper"

public enum FsDriver: String, Codable, Sendable {
    // Raw value matches `cli/commands/mount.sh`'s literal `--fs-driver` values (L1: ntfs-3g is
    // the implicit default, ntfs3 is opt-in only via this flag, never an `-o` token).
    case ntfs3g = "ntfs-3g"
    case ntfs3 = "ntfs3"
}

/// Generic passthrough result for wrapper scripts that only ever print human-readable text —
/// none of `mount.sh`/`unmount.sh`/`pf-anchor.sh`/`pf-teardown.sh` emit structured JSON, so this
/// carries the real (stdout+stderr, exit code) shape rather than inventing fields none of them
/// produce.
public struct CommandResult: Codable, Sendable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

/// PLAN.md §3 XPC surface — this unit's Do clause scopes exactly these four methods (mount,
/// unmount, applyPfRules, teardown). `listDrives`/`status`/`diagnose` are deliberately absent:
/// each is read-only and explicitly Don't-listed as privileged in their own units
/// (`3-drive-detect`, `3-status-speed`, `3-diagnose-ui` all call the CLI directly, unprivileged).
@objc public protocol HelperXPCProtocol {
    /// `device` is re-validated against `deviceNamePattern` inside the helper before any shell
    /// call — never trusts the caller (§3). `driver`'s raw value must match `FsDriver`.
    /// `readOnly`: appends `ro` to the NFS client mount options (`cli/lib/nfs-mount.sh`'s
    /// `--read-only` flag) — the only real lever for a requested read-only mount, since
    /// anylinuxfs/ntfs-3g have no mode-request flag of their own (confirmed: no `force`/mode
    /// field on `MountCmd` in the vendored `cli.rs`; ntfs-3g's own dirty-journal check is the
    /// only thing that can *also* force read-only, independent of this flag).
    func mount(device: String, driver: String, mountPoint: String?, readOnly: Bool, reply: @escaping (Data?, String?) -> Void)

    /// `target` is re-validated against `isValidUnmountTarget` inside the helper.
    func unmount(target: String, reply: @escaping (Data?, String?) -> Void)

    /// Renders `cli/lib/pf-anchor.sh`'s anchor for `subnetCIDR` and loads it via
    /// `pfctl -a ntfsmac -f -` (anchor-scoped, never a bare `pfctl -f`).
    func applyPfRules(subnetCIDR: String, reply: @escaping (Data?, String?) -> Void)

    /// Runs `cli/lib/pf-teardown.sh` (anchor-scoped `pfctl -a ntfsmac -F rules`, idempotent).
    func teardown(subnetCIDR: String?, reply: @escaping (Data?, String?) -> Void)

    /// Removes `installPrefix` (CLI + vendored dependencies, same tree `cli/commands/
    /// uninstall.sh` targets) plus the real invoking user's `~/.anylinuxfs` (rootfs cache +
    /// config.toml) and `~/Library/Logs/anylinuxfs*.log` — never the helper itself (see
    /// `uninstallHelper`). Rejects while any NFS mount is active, same safety check
    /// `uninstall.sh` makes.
    func removeDependencies(reply: @escaping (Data?, String?) -> Void)

    /// Un-blesses this helper: deletes its own `/Library/LaunchDaemons` plist and
    /// `/Library/PrivilegedHelperTools` binary, replies to the client, then `launchctl bootout`s
    /// its own launchd job last. The last XPC call any client should make — the mach service is
    /// gone once this returns. Combined with `removeDependencies`, this is what lets "drag the
    /// app to Trash" leave zero leftovers.
    func uninstallHelper(reply: @escaping (Data?, String?) -> Void)

    /// Runs the bundled `install.sh` (staged read-only inside the calling app's own
    /// `Contents/Resources/cli-src/`, `build/package-app.sh`) as this already-root helper
    /// process, with `--no-path-link` so a GUI-only install never puts `ntfsmac` on the user's
    /// Terminal PATH. `installScriptPath` is re-validated inside the helper (§3: never trust
    /// the caller) before any shell call — must resolve to a real file whose path literally
    /// ends `/Contents/Resources/cli-src/install.sh`, the one fixed layout this script ever
    /// produces; nothing else is accepted regardless of what the GUI sends.
    func stageCLI(installScriptPath: String, reply: @escaping (Data?, String?) -> Void)

    /// Reports the CLI tree hash this specific running helper binary was built with
    /// (`expectedCLITreeHash`, same value `stageCLI` gates on). Has nothing to do with staging —
    /// it exists so `HelperInstaller` can tell "a helper is registered" (`SMJobCopyDictionary`,
    /// which only proves *some* job exists under the label — see its own doc comment) apart from
    /// "the registered helper is *this build's* helper." A daemon left running from a previous
    /// build reports its own old hash (or, for a helper old enough to predate this method
    /// entirely, doesn't answer at all) — both read as stale to the caller.
    func version(reply: @escaping (String?) -> Void)
}

/// Seam for `HelperService` so unit tests can assert on the exact argv built for a request
/// without ever spawning a real (privileged) process. `RealCommandRunner` is the only
/// production implementation.
public protocol PrivilegedCommandRunning {
    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult
    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult
}

/// Lock-protected single-value holder — lets `captureOutput`'s two background readers each
/// write their own result without Swift 6 strict concurrency flagging a shared captured `var`
/// as a data race (the two boxes below are never touched by more than one thread at a time in
/// practice, but the type system can't see that through a plain closure capture).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public struct RealCommandRunner: PrivilegedCommandRunning {
    public init() {}

    /// Drains both pipes concurrently on background queues, started *before* `waitUntilExit()`
    /// — reading them sequentially afterward (the previous shape of this code) deadlocks the
    /// instant combined stdout+stderr exceeds the ~64KB pipe buffer: the child blocks writing to
    /// a full pipe nobody is draining yet, while this thread blocks in `waitUntilExit()` waiting
    /// for a child that itself is blocked. Apple's own `Process`/`Pipe` docs call this out
    /// explicitly. Every command run through here so far produced small enough output to never
    /// hit it — `HelperService.stageCLI`'s `install.sh` (several file copies + `codesign`/`xattr`
    /// calls per binary) was the first real trigger.
    private func captureOutput(_ process: Process, _ outPipe: Pipe, _ errPipe: Pipe) -> String {
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return (String(data: outBox.get(), encoding: .utf8) ?? "") + (String(data: errBox.get(), encoding: .utf8) ?? "")
    }

    public func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(output: "helper: failed to launch \(executablePath): \(error)", exitCode: -1)
        }
        let combined = captureOutput(process, outPipe, errPipe)
        return CommandResult(output: combined, exitCode: process.terminationStatus)
    }

    public func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(output: "helper: failed to launch \(executablePath): \(error)", exitCode: -1)
        }
        inPipe.fileHandleForWriting.write(input.data(using: .utf8) ?? Data())
        inPipe.fileHandleForWriting.closeFile()
        let combined = captureOutput(process, outPipe, errPipe)
        return CommandResult(output: combined, exitCode: process.terminationStatus)
    }
}

/// Implements the four privileged XPC methods this unit scopes (§3, `3-xpc-helper`'s Do
/// clause). Every method re-validates its own input before `runner` ever sees it — the helper
/// treats every caller as hostile regardless of what the GUI/CLI already checked.
public final class HelperService: NSObject, HelperXPCProtocol {
    private let runner: PrivilegedCommandRunning
    private let resolvePrefix: @Sendable () -> String
    private let expectedCLITreeHash: String

    /// `ntfsmacPrefix`, when passed (tests only), pins the CLI location instead of resolving it
    /// live. Production always passes `nil` so every privileged call below re-runs
    /// `resolveNtfsmacPrefix()` fresh rather than freezing a snapshot at `HelperService.init`.
    /// That distinction matters because `main.swift` creates one `HelperService` per XPC
    /// connection, and the GUI opens several independent connections at launch
    /// (`MountController`, `RemountController`, `CLIAutoStager`, `HelperInstaller`,
    /// `HelperUninstaller` each default-construct their own `HelperClient()`) — often before
    /// first-run CLI staging (`stageCLI`) has finished writing the binary, or before a later
    /// brew relink/reinstall changes which candidate prefix is live. A snapshot taken at that
    /// early moment stayed wrong for the connection's entire lifetime with no way to recover
    /// short of relaunching the GUI. Re-resolving is two cheap `isExecutableFile` stats — worth
    /// paying on every call to never go stale. `expectedCLITreeHash` defaults to the
    /// build-time-generated manifest so production always checks against what actually shipped
    /// with this binary; tests inject their own known-good hash instead of depending on a real
    /// build having run.
    public init(
        runner: PrivilegedCommandRunning,
        ntfsmacPrefix: String? = nil,
        expectedCLITreeHash: String = GeneratedCLIManifest.expectedTreeHashHex
    ) {
        self.runner = runner
        if let ntfsmacPrefix {
            self.resolvePrefix = { ntfsmacPrefix }
        } else {
            self.resolvePrefix = { resolveNtfsmacPrefix() }
        }
        self.expectedCLITreeHash = expectedCLITreeHash
    }

    private func encode(_ result: CommandResult, reply: (Data?, String?) -> Void) {
        guard let data = try? JSONEncoder().encode(result) else {
            reply(nil, "helper: failed to encode result")
            return
        }
        reply(data, nil)
    }

    public func mount(device: String, driver: String, mountPoint: String?, readOnly: Bool, reply: @escaping (Data?, String?) -> Void) {
        guard validateDevice(device) else {
            reply(nil, "rejected: device \"\(device)\" does not match \(deviceNamePattern)")
            return
        }
        guard let fsDriver = FsDriver(rawValue: driver) else {
            reply(nil, "rejected: unknown driver \"\(driver)\"")
            return
        }
        if let mountPoint, !isValidMountPoint(mountPoint) {
            reply(nil, "rejected: mountPoint \"\(mountPoint)\" is not a valid /Volumes/ path")
            return
        }
        var args = [device]
        if let mountPoint { args.append(mountPoint) }
        args.append(contentsOf: ["--fs-driver", fsDriver.rawValue])
        if readOnly { args.append("--read-only") }
        let result = runner.run("\(resolvePrefix())/bin/ntfsmac", ["mount"] + args)
        encode(result, reply: reply)
    }

    public func unmount(target: String, reply: @escaping (Data?, String?) -> Void) {
        guard isValidUnmountTarget(target) else {
            reply(nil, "rejected: unmount target \"\(target)\" is neither a valid device nor a /Volumes/ path")
            return
        }
        let result = runner.run("\(resolvePrefix())/bin/ntfsmac", ["unmount", target])
        encode(result, reply: reply)
    }

    public func applyPfRules(subnetCIDR: String, reply: @escaping (Data?, String?) -> Void) {
        guard isValidSubnetCIDR(subnetCIDR) else {
            reply(nil, "rejected: subnetCIDR \"\(subnetCIDR)\" is not a private /30")
            return
        }
        let render = runner.run("\(resolvePrefix())/libexec/ntfsmac/lib/pf-anchor.sh", [subnetCIDR])
        guard render.exitCode == 0 else {
            encode(render, reply: reply)
            return
        }
        let load = runner.runPipingStdin(render.output, to: "/sbin/pfctl", ["-a", "ntfsmac", "-f", "-"])
        encode(load, reply: reply)
    }

    public func teardown(subnetCIDR: String?, reply: @escaping (Data?, String?) -> Void) {
        if let subnetCIDR, !isValidSubnetCIDR(subnetCIDR) {
            reply(nil, "rejected: subnetCIDR \"\(subnetCIDR)\" is not a private /30")
            return
        }
        var args: [String] = []
        if let subnetCIDR { args.append(subnetCIDR) }
        let result = runner.run("\(resolvePrefix())/libexec/ntfsmac/lib/pf-teardown.sh", args)
        encode(result, reply: reply)
    }

    public func removeDependencies(reply: @escaping (Data?, String?) -> Void) {
        guard noActiveNfsMount() else {
            reply(nil, "rejected: an NFS mount is currently active — unmount it first")
            return
        }

        // Resolved once and reused for the rest of this call — every path below must agree on
        // the same prefix within one invocation (reporting one path in `removedPaths` while
        // deleting another would be its own bug), unlike `mount`/`unmount` which only ever touch
        // the prefix once each.
        let prefix = resolvePrefix()
        _ = runner.run("\(prefix)/libexec/ntfsmac/lib/pf-teardown.sh", [])

        // Re-check immediately before the destructive delete, not just once at the top — a
        // concurrent `mount(...)` XPC call could land in the gap between the first check and
        // here (a fresh `HelperService` per connection, no shared lock). Narrows, doesn't
        // eliminate, the TOCTOU window; this project's own priority ordering ("security and
        // connection stability outrank speed") calls for the extra check over skipping it.
        guard noActiveNfsMount() else {
            reply(nil, "rejected: an NFS mount became active — aborting before removing files")
            return
        }

        var removedPaths = [prefix]
        _ = runner.run("/bin/rm", ["-rf", prefix])

        // install.sh's own PATH convenience (`/usr/local/bin/ntfsmac` -> `installPrefix`/bin/
        // ntfsmac) is never created by the brew tap — brew manages its own `opt/homebrew/bin`
        // symlink and removes it itself on `brew uninstall`. Only clean up the one *we* might
        // have created, and only if it still points where we'd have pointed it — never blow
        // away an unrelated file a user happens to have at that path. Checked against the
        // fixed `installPrefix` constant (not `ntfsmacPrefix`): that symlink only ever targets
        // the install.sh layout, regardless of which prefix this helper resolved as active.
        let pathSymlink = "/usr/local/bin/ntfsmac"
        let linkTarget = runner.run("/bin/readlink", [pathSymlink])
        if linkTarget.exitCode == 0,
           linkTarget.output.trimmingCharacters(in: .whitespacesAndNewlines) == "\(installPrefix)/bin/ntfsmac" {
            removedPaths.append(pathSymlink)
            _ = runner.run("/bin/rm", ["-f", pathSymlink])
        }

        if let home = Self.invokingUserHomeDirectory() {
            let cachePath = home.appendingPathComponent(".anylinuxfs").path
            removedPaths.append(cachePath)
            _ = runner.run("/bin/rm", ["-rf", cachePath])

            let logsDir = home.appendingPathComponent("Library/Logs")
            let logFiles = (try? FileManager.default.contentsOfDirectory(atPath: logsDir.path)) ?? []
            let matchingLogs = logFiles
                .filter { $0.hasPrefix("anylinuxfs") && $0.hasSuffix(".log") }
                .map { logsDir.appendingPathComponent($0).path }
            if !matchingLogs.isEmpty {
                removedPaths.append(contentsOf: matchingLogs)
                _ = runner.run("/bin/rm", ["-f"] + matchingLogs)
            }
        }

        encode(CommandResult(output: removedPaths.joined(separator: "\n"), exitCode: 0), reply: reply)
    }

    private func noActiveNfsMount() -> Bool {
        runner.run("/sbin/mount", ["-t", "nfs"]).output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func stageCLI(installScriptPath: String, reply: @escaping (Data?, String?) -> Void) {
        guard isValidStageCLIPath(installScriptPath) else {
            reply(nil, "rejected: installScriptPath \"\(installScriptPath)\" is not a bundled install.sh")
            return
        }
        // Resolve symlinks before either check below — a component could be swapped between an
        // earlier look and this one otherwise (the same TOCTOU class `removeDependencies`'
        // immediate-recheck-before-delete already guards against elsewhere in this file).
        let resolvedScriptPath = URL(fileURLWithPath: installScriptPath).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolvedScriptPath.path) else {
            reply(nil, "rejected: \(installScriptPath) does not exist or isn't executable")
            return
        }
        let cliSrcDir = resolvedScriptPath.deletingLastPathComponent()
        guard let actualHash = computeTreeHash(at: cliSrcDir), actualHash == expectedCLITreeHash else {
            reply(nil, "rejected: cli-src content does not match the hash pinned into this helper at build time — refusing (possible tampering)")
            return
        }
        let result = runner.run(resolvedScriptPath.path, ["--no-path-link"])
        encode(result, reply: reply)
    }

    public func version(reply: @escaping (String?) -> Void) {
        reply(expectedCLITreeHash)
    }

    public func uninstallHelper(reply: @escaping (Data?, String?) -> Void) {
        let label = helperMachServiceName
        _ = runner.run("/bin/rm", ["-f", "/Library/LaunchDaemons/\(label).plist"])
        // Deleting our own running binary is safe on Unix — the inode stays valid until this
        // process exits.
        let removeBinary = runner.run("/bin/rm", ["-f", "/Library/PrivilegedHelperTools/\(label)"])
        encode(removeBinary, reply: reply)
        // `bootout` sends this very process a kill signal and (per its documented semantics)
        // can finish tearing the process down before a reply queued *after* it would ever reach
        // the client — confirmed live as the actual cause of "can't communicate with helper" on
        // every uninstall attempt on a real second Mac (this bug reproduces independent of the
        // app's install path or quarantine state; it's a self-inflicted race, not either of
        // those). Replying first, then self-terminating last, is the fix: nothing after this
        // point should assume the helper is still reachable.
        _ = runner.run("/bin/launchctl", ["bootout", "system/\(label)"])
    }

    /// The GUI runs unprivileged as the real logged-in user; this helper runs as root under
    /// launchd, so `NSHomeDirectory()`/`$HOME` here would resolve to *root's* home, not the
    /// user's. `NSXPCConnection.current()` returns the connection driving the call presently in
    /// flight (Apple's documented pattern for this), and `effectiveUserIdentifier` is a
    /// kernel-verified peer credential — not client-supplied data, so it can't be spoofed by a
    /// malicious message the way a plain parameter could. Mirrors anylinuxfs's own
    /// `home_dir_from_uid` (`vendor/.../anylinuxfs/src/main.rs`) — same problem, same class of
    /// solution.
    private static func invokingUserHomeDirectory() -> URL? {
        guard let uid = NSXPCConnection.current()?.effectiveUserIdentifier,
              let pw = getpwuid(uid), let dir = pw.pointee.pw_dir
        else { return nil }
        return URL(fileURLWithPath: String(cString: dir))
    }
}

/// Best-effort caller-identity check. Ad-hoc signing (L4 — no paid Developer account, no
/// notarization) means there is no trusted certificate chain to pin against: this only confirms
/// the connecting process's own code-signed identifier, which any locally ad-hoc-signed binary
/// can also claim. The load-bearing security control is per-call input validation above
/// (`validateDevice`/`isValidUnmountTarget`), not this check — documented here so it isn't
/// mistaken for a strong boundary later.
public func verifyClientIdentity(pid: pid_t, expectedIdentifier: String) -> Bool {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
        return false
    }
    var requirement: SecRequirement?
    let requirementString = "identifier \"\(expectedIdentifier)\"" as CFString
    guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
          let requirement else {
        return false
    }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}
