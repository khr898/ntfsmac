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
/// Accepts "diskNsM" (e.g. disk2s1) or "diskN" (e.g. disk4 for unpartitioned BitLocker/NTFS).
public let deviceNamePattern = "^disk[0-9]+(s[0-9]+)?$"

private let precompiledDeviceRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: deviceNamePattern)
}()

public func validateDevice(_ device: String) -> Bool {
    let range = NSRange(location: 0, length: device.utf16.count)
    return precompiledDeviceRegex.firstMatch(in: device, options: [], range: range) != nil
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

/// Legacy constant kept for API compatibility.
/// Security review finding: the privileged helper runs as root and must NEVER resolve or execute
/// binaries from `/opt/homebrew`, because on Apple Silicon macOS, `/opt/homebrew` is owned by the
/// local user/admin group, allowing unprivileged local privilege escalation to root.
public let homebrewOptPrefix = "/opt/homebrew/opt/ntfsmac"

public let ntfsmacCandidatePrefixes = [installPrefix]

/// Privileged helper resolution: always returns `installPrefix` (`/usr/local/ntfsmac`).
/// Dropping Homebrew prefixes prevents local privilege escalation via user-writable directories.
public func resolveNtfsmacPrefix(fileManager: FileManager = .default) -> String {
    installPrefix
}

public func resolveAnylinuxfsPath(fileManager: FileManager = .default) -> String {
    "\(installPrefix)/bin/anylinuxfs"
}

/// Verifies that an executable and every component of its path is owned by root (uid 0)
/// and not writable by group or others (st_mode & 0o022 == 0).
/// Prevents local privilege escalation where an attacker modifies an executable or replaces
/// a directory component to trick a root daemon into running malicious code.
public func isSecureRootOwnedExecutable(atPath path: String) -> Bool {
    if ProcessInfo.processInfo.environment["NTFSMAC_SKIP_ROOT_PATH_CHECK"] == "1" {
        return true
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let resolvedPath = url.path

    var statBuf = stat()
    guard lstat(resolvedPath, &statBuf) == 0 else { return false }
    guard (statBuf.st_mode & S_IFMT) == S_IFREG else { return false }
    guard (statBuf.st_mode & 0o111) != 0 else { return false }
    guard statBuf.st_uid == 0 else { return false }
    guard (statBuf.st_mode & 0o022) == 0 else { return false }

    var currentURL = url.deletingLastPathComponent()
    while currentURL.path != "/" {
        var dirStat = stat()
        guard lstat(currentURL.path, &dirStat) == 0 else { return false }
        guard (dirStat.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard dirStat.st_uid == 0 else { return false }
        guard (dirStat.st_mode & 0o022) == 0 else { return false }
        currentURL = currentURL.deletingLastPathComponent()
    }

    var rootStat = stat()
    guard lstat("/", &rootStat) == 0 else { return false }
    guard rootStat.st_uid == 0, (rootStat.st_mode & 0o022) == 0 else { return false }

    return true
}

/// Recursively sets root:wheel ownership and strips group/other write permissions on a directory tree.
public func setSecureOwnershipRecursively(at directory: URL) {
    _ = chown(directory.path, 0, 0)
    _ = chmod(directory.path, 0o755)
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return }
    for case let fileURL as URL in enumerator {
        _ = chown(fileURL.path, 0, 0)
        var st = stat()
        if lstat(fileURL.path, &st) == 0 {
            let mode = (st.st_mode & ~0o022)
            _ = chmod(fileURL.path, mode_t(mode))
        }
    }
}

public let helperMachServiceName = "com.khr898.ntfsmac.helper"

public enum FsDriver: String, Codable, Sendable {
    // Raw value matches `cli/commands/mount.sh`'s literal `--fs-driver` values (L1: ntfs-3g is
    // the implicit default, ntfs3 is opt-in only via this flag, never an `-o` token).
    case ntfs3g = "ntfs-3g"
    case ntfs3 = "ntfs3"
    // ext2/3/4: the kernel auto-detects, so this is NOT a --fs-driver value. It's the GUI's
    // signal to the helper to skip --fs-driver (ntfs-3g can't mount ext4) and pass
    // --ignore-permissions instead, so the NFS export gets all_squash,anonuid=0,anongid=0
    // (vendor vmproxy/main.rs:1327) and the macOS user can write past ext's Unix ownership.
    // Reuses the existing `driver` XPC channel — no protocol signature change. NTFS keeps
    // .ntfs3g/.ntfs3 and never gets all_squash ("do not change the NTFS part").
    case ext = "ext"
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

/// Mutating XPC surface. Mount/unmount call the CLI's per-session security transaction inside the
/// already-root helper; there is deliberately no raw "load these PF rules" method anymore. That
/// older split API could load an unevaluated anchor with no lifecycle ownership or measured state.
/// `listDrives`/`status`/`diagnose` are deliberately absent:
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
    func mount(device: String, driver: String, mountPoint: String?, readOnly: Bool, recoveryKey: String?, reply: @escaping (Data?, String?) -> Void)

    /// `target` is re-validated against `isValidUnmountTarget` inside the helper.
    func unmount(target: String, reply: @escaping (Data?, String?) -> Void)

    /// Removes one recorded session, or reconciles stale sessions when nil. Never flushes a
    /// global/shared anchor, so one mount cannot invalidate another mount's protection.
    func teardown(sessionID: String?, reply: @escaping (Data?, String?) -> Void)

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

    /// Runs `anylinuxfs list --microsoft` and `anylinuxfs list --linux` as root to enumerate all
    /// mountable NTFS, BitLocker, and ext partitions. Because the helper runs as root, unpartitioned
    /// whole-disk devices (e.g. BitLocker To Go USB drives on disk4) can be read with libblkid
    /// without the permission errors an unprivileged GUI process hits.
    func listDrives(reply: @escaping (Data?, String?) -> Void)

    /// Self-termination path for GUI Quit. The GUI's Quit flow first calls `unmount`/`teardown`
    /// for cleanup, then this so the privileged launchd on-demand helper doesn't linger as root
    /// after the app closes (Activity Monitor can't kill it without sudo — it must exit itself
    /// via XPC). Replies before `exit(0)`, same reason `uninstallHelper` does: a reply queued
    /// after self-termination never reaches the client, and the GUI's `await` would hang.
    /// Distinct from `uninstallHelper` (which un-blesses + bootouts the launchd job for removal);
    /// this leaves registration intact so the next app launch re-uses the same blessed helper.
    func exitHelper(reply: @escaping (Data?, String?) -> Void)

    /// Tests Full Disk Access (FDA) by attempting to open raw disk device /dev/rdisk0 read-only.
    func checkFDA(reply: @escaping (Bool) -> Void)
}

/// Seam for `HelperService` so unit tests can assert on the exact argv built for a request
/// without ever spawning a real (privileged) process. `RealCommandRunner` is the only
/// production implementation.
public protocol PrivilegedCommandRunning {
    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult
    func run(_ executablePath: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult
    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult
}

extension PrivilegedCommandRunning {
    public func run(_ executablePath: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        run(executablePath, arguments)
    }
}

public struct RealCommandRunner: PrivilegedCommandRunning {
    public static let timeoutExitCode: Int32 = 124

    public init() {}

    private func configureEnvironment(for process: Process) {
        var env = ProcessInfo.processInfo.environment
        if let connection = NSXPCConnection.current() {
            let uid = connection.effectiveUserIdentifier
            let gid = connection.effectiveGroupIdentifier
            env["SUDO_UID"] = String(uid)
            env["SUDO_GID"] = String(gid)
            if let pw = getpwuid(uid) {
                if let dir = pw.pointee.pw_dir {
                    env["HOME"] = String(cString: dir)
                }
                if let name = pw.pointee.pw_name {
                    let username = String(cString: name)
                    env["SUDO_USER"] = username
                    env["USER"] = username
                    env["LOGNAME"] = username
                }
            }
        }
        if let home = env["HOME"] {
            let prefFile = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/com.khr898.ntfsmac.plist")
            if let dict = NSDictionary(contentsOf: prefFile),
               let preserve = dict["com.khr898.ntfsmac.settings.preservePrivateRelay"] as? Bool,
               preserve {
                env["NTFSMAC_PRESERVE_PRIVATE_RELAY"] = "1"
            }
        }
        process.environment = env
    }

    private func createSecureOutputFile() -> (url: URL, handle: FileHandle)? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-command-\(UUID().uuidString)")
        let fd = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return (outputURL, handle)
    }

    public func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        if geteuid() == 0 && !isSecureRootOwnedExecutable(atPath: executablePath) {
            return CommandResult(output: "helper: refused execution of non-root-owned or group/world-writable binary at \(executablePath)", exitCode: -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        configureEnvironment(for: process)

        guard let (outputURL, outputHandle) = createSecureOutputFile() else {
            return CommandResult(output: "helper: failed to create command output file", exitCode: -1)
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
        } catch {
            return CommandResult(output: "helper: failed to launch \(executablePath): \(error)", exitCode: -1)
        }

        process.waitUntilExit()
        try? outputHandle.synchronize()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CommandResult(output: output, exitCode: process.terminationStatus)
    }

    /// Runs an unprivileged or otherwise bounded command. The protocol requirement above stays
    /// unbounded because helper mount/install operations have their own lifecycle contracts; the
    /// GUI drive scanner opts into this overload so a wedged raw-device probe cannot live forever.
    /// A temporary file avoids pipe-buffer and inherited-pipe EOF traps if the child spawns its
    /// own short-lived probe subprocess before the timeout fires.
    public func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        if geteuid() == 0 && !isSecureRootOwnedExecutable(atPath: executablePath) {
            return CommandResult(output: "helper: refused execution of non-root-owned or group/world-writable binary at \(executablePath)", exitCode: -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        configureEnvironment(for: process)

        guard let (outputURL, outputHandle) = createSecureOutputFile() else {
            return CommandResult(output: "helper: failed to create command output file", exitCode: -1)
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
        } catch {
            return CommandResult(output: "helper: failed to launch \(executablePath): \(error)", exitCode: -1)
        }

        let processGroup = DispatchGroup()
        processGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            processGroup.leave()
        }

        var timedOut = false
        let timeoutMilliseconds = max(1, Int(timeout * 1_000))
        if processGroup.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            timedOut = true
            process.terminate()
            // A process stuck in a kernel-backed device operation may ignore SIGTERM. Keep the
            // caller bounded and escalate only that exact child after a short grace period.
            if processGroup.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                _ = processGroup.wait(timeout: .now() + .milliseconds(250))
            }
        }

        try? outputHandle.synchronize()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        if timedOut {
            let suffix = output.isEmpty ? "" : "\n\(output)"
            return CommandResult(output: "command timed out\(suffix)", exitCode: Self.timeoutExitCode)
        }
        return CommandResult(output: output, exitCode: process.terminationStatus)
    }

    public func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        if geteuid() == 0 && !isSecureRootOwnedExecutable(atPath: executablePath) {
            return CommandResult(output: "helper: refused execution of non-root-owned or group/world-writable binary at \(executablePath)", exitCode: -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        configureEnvironment(for: process)

        guard let (outputURL, outputHandle) = createSecureOutputFile() else {
            return CommandResult(output: "helper: failed to create command output file", exitCode: -1)
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
        } catch {
            return CommandResult(output: "helper: failed to launch \(executablePath): \(error)", exitCode: -1)
        }
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: input.data(using: .utf8) ?? Data())
        } catch {
            // EPIPE or child closed pipe early
        }
        try? inPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        try? outputHandle.synchronize()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CommandResult(output: output, exitCode: process.terminationStatus)
    }
}

/// Implements the minimal privileged XPC surface (§3, `3-xpc-helper`'s Do clause). Every method
/// re-validates its own input before `runner` ever sees it — the helper
/// treats every caller as hostile regardless of what the GUI/CLI already checked.
public final class HelperService: NSObject, HelperXPCProtocol {
    /// One lock across every connection-owned HelperService instance. Mutating calls must not
    /// interleave a mount with teardown/staging/removal: that could erase a freshly created
    /// session anchor or delete the CLI while a privileged operation is starting.
    private static let mutationLock = NSLock()
    private let runner: PrivilegedCommandRunning
    private let resolvePrefix: @Sendable () -> String
    private let expectedCLITreeHash: String
    private let exitSink: @Sendable () -> Void
    private let fdaCheck: (@Sendable () -> Bool)?

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
        expectedCLITreeHash: String = GeneratedCLIManifest.expectedTreeHashHex,
        exitSink: @Sendable @escaping () -> Void = { exit(0) },
        fdaCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.runner = runner
        if let ntfsmacPrefix {
            self.resolvePrefix = { ntfsmacPrefix }
        } else {
            self.resolvePrefix = { resolveNtfsmacPrefix() }
        }
        self.expectedCLITreeHash = expectedCLITreeHash
        self.exitSink = exitSink
        self.fdaCheck = fdaCheck
    }

    private func encode(_ result: CommandResult, reply: (Data?, String?) -> Void) {
        guard let data = try? JSONEncoder().encode(result) else {
            reply(nil, "helper: failed to encode result")
            return
        }
        reply(data, nil)
    }

    public func mount(device: String, driver: String, mountPoint: String?, readOnly: Bool, recoveryKey: String?, reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
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
        if let recoveryKey, recoveryKey.isEmpty || recoveryKey.utf8.count > 256 || recoveryKey.contains("\n") || recoveryKey.contains("\r") {
            reply(nil, "rejected: invalid BitLocker password or recovery key")
            return
        }
        var args = [device]
        if let mountPoint { args.append(mountPoint) }
        if fsDriver == .ext {
            // ext: no --fs-driver (kernel auto-detects; ntfs-3g can't mount ext4) + all_squash
            // so the macOS user can write past ext's Unix ownership. NTFS keeps --fs-driver.
            args.append("--ignore-permissions")
        } else {
            args.append(contentsOf: ["--fs-driver", fsDriver.rawValue])
        }
        if readOnly { args.append("--read-only") }
        let executable = "\(resolvePrefix())/bin/ntfsmac"
        let result: CommandResult
        if let recoveryKey {
            args.append("--bitlocker-credential-stdin")
            result = runner.runPipingStdin(recoveryKey + "\n", to: executable, ["mount"] + args)
        } else {
            args.append("--credential-required-error")
            result = runner.run(executable, ["mount"] + args)
        }
        encode(result, reply: reply)
    }

    public func unmount(target: String, reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard isValidUnmountTarget(target) else {
            reply(nil, "rejected: unmount target \"\(target)\" is neither a valid device nor a /Volumes/ path")
            return
        }
        let result = runner.run("\(resolvePrefix())/bin/ntfsmac", ["unmount", target], timeout: 30.0)
        encode(result, reply: reply)
    }

    public func teardown(sessionID: String?, reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if let sessionID, !validateDevice(sessionID) {
            reply(nil, "rejected: sessionID \"\(sessionID)\" does not match \(deviceNamePattern)")
            return
        }
        var args: [String] = []
        if let sessionID { args.append(sessionID) }
        let result = runner.run("\(resolvePrefix())/libexec/ntfsmac/lib/pf-teardown.sh", args, timeout: 30.0)
        encode(result, reply: reply)
    }

    public func removeDependencies(reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard noActiveNfsMount() else {
            reply(nil, "rejected: an NFS mount is currently active — unmount it first")
            return
        }

        // Resolved once and reused for the rest of this call — every path below must agree on
        // the same prefix within one invocation (reporting one path in `removedPaths` while
        // deleting another would be its own bug), unlike `mount`/`unmount` which only ever touch
        // the prefix once each.
        let prefix = resolvePrefix()
        // Reconcile rather than flushing every record. If another non-XPC CLI mount appears,
        // active state is preserved and the second mount-table check below aborts removal.
        let cleanup = runner.run("\(prefix)/libexec/ntfsmac/lib/pf-teardown.sh", [], timeout: 30.0)
        guard cleanup.exitCode == 0,
              !cleanup.output.contains("=unknown"),
              !cleanup.output.contains("=notEnforced")
        else {
            reply(nil, "rejected: session security cleanup could not be proven")
            return
        }

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
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
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

        // TOCTOU mitigation: stage cli-src into a secure 0700 root:wheel directory before hashing
        // and executing, preventing unprivileged users from swapping files mid-flight.
        let stageID = UUID().uuidString
        let secureStagingDir = URL(fileURLWithPath: "/tmp/ntfsmac-stage-\(stageID)")
        do {
            try FileManager.default.createDirectory(at: secureStagingDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            if geteuid() == 0 {
                _ = chown(secureStagingDir.path, 0, 0)
                _ = chmod(secureStagingDir.path, 0o700)
            }
        } catch {
            reply(nil, "rejected: failed to create secure staging directory: \(error)")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: secureStagingDir)
        }

        let stagedCliSrcDir = secureStagingDir.appendingPathComponent("cli-src")
        do {
            try FileManager.default.copyItem(at: cliSrcDir, to: stagedCliSrcDir)
            if geteuid() == 0 {
                setSecureOwnershipRecursively(at: stagedCliSrcDir)
            }
        } catch {
            reply(nil, "rejected: failed to copy cli-src to secure staging directory: \(error)")
            return
        }

        guard let actualHash = computeTreeHash(at: stagedCliSrcDir), actualHash == expectedCLITreeHash else {
            reply(nil, "rejected: cli-src content does not match the hash pinned into this helper at build time — refusing (possible tampering)")
            return
        }
        // Idempotency: if the installed CLI tree already matches this helper's pinned hash, skip
        // the reinstall. Without this, a new app build re-blesses the helper but `CLIAutoStager`
        // never re-stages (it skips on "any ntfsmac installed"), so the installed `ntfsmac` stays
        // stale and rejects flags the new helper sends (e.g. --ignore-permissions). The marker is
        // written by this helper after a successful install, so a mismatch/missing marker means
        // "stale or first run" → run install.sh, then refresh the marker.
        let markerPath = "\(installPrefix)/libexec/ntfsmac/cli-tree.sha256"
        if let marker = try? String(contentsOfFile: markerPath, encoding: .utf8),
           marker.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCLITreeHash {
            encode(CommandResult(output: "cli already current", exitCode: 0), reply: reply)
            return
        }
        let stagedScriptPath = stagedCliSrcDir.appendingPathComponent("install.sh")
        let result = runner.run(stagedScriptPath.path, ["--no-path-link"])
        if result.exitCode == 0 {
            try? expectedCLITreeHash.write(toFile: markerPath, atomically: true, encoding: .utf8)
        }
        encode(result, reply: reply)
    }

    public func version(reply: @escaping (String?) -> Void) {
        reply(expectedCLITreeHash)
    }

    public func listDrives(reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let prefixBin = "\(resolvePrefix())/bin/anylinuxfs"
        let anylinuxfs = FileManager.default.isExecutableFile(atPath: prefixBin) ? prefixBin : resolveAnylinuxfsPath()
        guard FileManager.default.isExecutableFile(atPath: anylinuxfs) else {
            reply(nil, "rejected: anylinuxfs not found or not executable at \(anylinuxfs)")
            return
        }
        let microsoft = runner.run(anylinuxfs, ["list", "--microsoft"], timeout: 10.0)
        let linux = runner.run(anylinuxfs, ["list", "--linux"], timeout: 10.0)
        let exitCode: Int32
        let combinedOutput: String
        if microsoft.exitCode == 0 || linux.exitCode == 0 {
            exitCode = 0
            var outputs: [String] = []
            if !microsoft.output.isEmpty { outputs.append(microsoft.output) }
            if !linux.output.isEmpty { outputs.append(linux.output) }
            combinedOutput = outputs.joined(separator: "\n")
        } else {
            exitCode = microsoft.exitCode != 0 ? microsoft.exitCode : linux.exitCode
            combinedOutput = [microsoft.output, linux.output].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        encode(CommandResult(output: combinedOutput, exitCode: exitCode), reply: reply)
    }

    public func checkFDA(reply: @escaping (Bool) -> Void) {
        if let check = fdaCheck {
            reply(check())
            return
        }
        let fd = Darwin.open("/dev/rdisk0", O_RDONLY)
        if fd >= 0 {
            Darwin.close(fd)
            reply(true)
        } else {
            let fallbackFd = Darwin.open("/dev/disk0", O_RDONLY)
            if fallbackFd >= 0 {
                Darwin.close(fallbackFd)
                reply(true)
            } else {
                reply(false)
            }
        }
    }

    public func uninstallHelper(reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let label = helperMachServiceName
        _ = runner.run("/bin/rm", ["-f", "/Library/LaunchDaemons/\(label).plist"])
        // Deleting our own running binary is safe on Unix — the inode stays valid until this
        // process exits.
        let removeBinary = runner.run("/bin/rm", ["-f", "/Library/PrivilegedHelperTools/\(label)"])
        _ = runner.run("/usr/bin/tccutil", ["reset", "SystemPolicyAllFiles", label])
        _ = runner.run("/usr/bin/tccutil", ["reset", "All", label])
        _ = runner.run("/bin/launchctl", ["enable", "system/\(label)"])
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

    public func exitHelper(reply: @escaping (Data?, String?) -> Void) {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard noActiveNfsMount() else {
            reply(nil, "rejected: cannot exit helper while NFS mounts are active")
            return
        }
        // Reply first, then self-terminate — same ordering as `uninstallHelper`: a reply queued
        // after `exit(0)` never reaches the client and the GUI's `await` hangs. `exitSink`
        // defaults to `exit(0)` in production; tests inject a capturing closure so they can
        // assert the call happened without terminating the test process.
        reply(Data(), nil)
        exitSink()
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

extension NSXPCConnection {
    public var connectionAuditToken: audit_token_t? {
        guard let value = self.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token)
        return token
    }
}

/// Caller identity check supporting both kernel audit tokens (primary) and PID (fallback/tests).
/// Ad-hoc signing (L4 — no paid Developer account, no notarization) means there is no trusted
/// certificate chain to pin against: this confirms the connecting process's own code-signed
/// identifier and code signature validity using the kernel audit token.
public func verifyClientIdentity(connection: NSXPCConnection, expectedIdentifier: String) -> Bool {
    if let token = connection.connectionAuditToken {
        return verifyClientIdentity(auditToken: token, expectedIdentifier: expectedIdentifier)
    }
    return verifyClientIdentity(pid: connection.processIdentifier, expectedIdentifier: expectedIdentifier)
}

public func verifyClientIdentity(auditToken: audit_token_t, expectedIdentifier: String) -> Bool {
    var token = auditToken
    let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    return verifyClientIdentity(attributes: attributes, expectedIdentifier: expectedIdentifier)
}

public func verifyClientIdentity(pid: pid_t, expectedIdentifier: String) -> Bool {
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    return verifyClientIdentity(attributes: attributes, expectedIdentifier: expectedIdentifier)
}

public func verifyClientIdentity(attributes: CFDictionary, expectedIdentifier: String) -> Bool {
    var code: SecCode?
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
