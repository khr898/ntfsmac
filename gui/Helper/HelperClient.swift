import Foundation
import HelperShared
import os.log

private let helperClientLog = Logger(subsystem: "com.khr898.ntfsmac", category: "HelperClient")

public enum HelperClientError: Error {
    case invalidDevice(String)
    case invalidUnmountTarget(String)
    case helper(String)
    case decode
    case proxyUnavailable
}

/// Every privileged action the GUI takes routes through here — never a raw `sudo` shell-out
/// (L5). Validates locally first (fast UX feedback) but the helper is the real gate: it
/// re-validates independently and this client never assumes its own check was sufficient.
/// `@MainActor`: every real caller (`MountController`/`RemountController` via the `@MainActor`
/// `HelperMounting` protocol, `PopoverContentView`'s Quit-time `teardown()`) already only ever
/// calls this from the main actor — making that explicit satisfies Swift 6 strict concurrency
/// without an `@unchecked Sendable` escape hatch.
@MainActor
public final class HelperClient: Sendable {
    // `nonisolated(unsafe)`: all access goes through `currentConnection()` or the invalidation
    // handler, both guarded by `connectionLock`.
    //
    // The connection is intentionally lazy. Creating/resuming it in `init` races first-run
    // SMJobBless: the app constructs its clients before the helper exists, leaving their first
    // real request attached to a failed bootstrap connection. The user then sees "couldn't
    // communicate with helper" immediately after authorizing a successful install. Creating it
    // at the first privileged request removes that race; an invalidated connection is still
    // rebuilt on the following call.
    private nonisolated(unsafe) var connection: NSXPCConnection?
    private let connectionLock = NSLock()
    private let machServiceName: String
    private let connectionFactory: @Sendable (String) -> NSXPCConnection

    public init(machServiceName: String = helperMachServiceName) {
        self.machServiceName = machServiceName
        self.connectionFactory = Self.makeConnection(machServiceName:)
        self.connection = nil
    }

    init(
        machServiceName: String,
        connectionFactory: @escaping @Sendable (String) -> NSXPCConnection
    ) {
        self.machServiceName = machServiceName
        self.connectionFactory = connectionFactory
        self.connection = nil
    }

    deinit {
        connection?.invalidate()
    }

    private nonisolated static func makeConnection(machServiceName: String) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.resume()
        return connection
    }

    // Runs on XPC's own queue, not the main actor (same as `call()`/`version()` below). Clear only
    // the connection that actually invalidated: a delayed callback from an old connection must
    // not discard a newer replacement.
    private nonisolated func wireInvalidationHandler(on connection: NSXPCConnection) {
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            helperClientLog.notice("XPC connection invalidated — will rebuild on next call")
            self.connectionLock.lock()
            if self.connection === connection {
                self.connection = nil
            }
            self.connectionLock.unlock()
        }
    }

    // `connectionLock`-guarded so construction and invalidation cannot race over which connection
    // is current. Nothing is created until the first actual helper request.
    private nonisolated func currentConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection {
            return connection
        }
        let newConnection = connectionFactory(machServiceName)
        connection = newConnection
        wireInvalidationHandler(on: newConnection)
        return newConnection
    }

    // `nonisolated`: NSXPCConnection invokes both this and the error handler below from its own
    // internal XPC dispatch queue, never the main actor — a plain method on this `@MainActor`
    // class would otherwise be implicitly main-actor-isolated, and Swift's runtime actor check
    // (`dispatch_assert_queue`) traps (SIGTRAP) the moment it's actually invoked off-main-thread.
    // Confirmed by crashing this exact way live this session (`ntfsmac-gui-...ips`: `closure #1 in
    // closure #1 in HelperClient.call(_:)` -> `_swift_task_checkIsolatedSwift` ->
    // `dispatch_assert_queue_fail`, on the `NSXPCConnection.m-user...helper` queue) after adding a
    // real (non-no-op) error handler without also keeping this nonisolated.
    private nonisolated func decode(_ data: Data?, _ error: String?) throws -> CommandResult {
        if let error { throw HelperClientError.helper(error) }
        guard let data, let result = try? JSONDecoder().decode(CommandResult.self, from: data) else {
            throw HelperClientError.decode
        }
        return result
    }

    // ponytail: this used to be `proxy() throws -> HelperXPCProtocol` with a no-op
    // `remoteObjectProxyWithErrorHandler({ _ in })` — confirmed live (this session) that any real
    // XPC-level failure (stale connection after the helper gets reinstalled/replaced while the GUI
    // is already running) silently drops the completion reply forever: the continuation below is
    // never resumed, so the caller hangs indefinitely with no error and no timeout. Apple's docs
    // guarantee the reply block and this error handler are mutually exclusive per call, so wiring
    // the error handler to reject the same continuation the reply block resolves is safe (no
    // double-resume) and turns every silent hang into a real thrown error.
    private nonisolated func call(_ body: @escaping @Sendable (HelperXPCProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = currentConnection().remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: HelperClientError.helper(error.localizedDescription))
            }) as? HelperXPCProtocol else {
                continuation.resume(throwing: HelperClientError.proxyUnavailable)
                return
            }
            body(proxy) { data, error in
                do {
                    continuation.resume(returning: try self.decode(data, error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func mount(device: String, driver: FsDriver, mountPoint: String? = nil, readOnly: Bool = false, recoveryKey: String? = nil) async throws -> CommandResult {
        guard validateDevice(device) else { throw HelperClientError.invalidDevice(device) }
        return try await call { proxy, reply in
            proxy.mount(device: device, driver: driver.rawValue, mountPoint: mountPoint, readOnly: readOnly, recoveryKey: recoveryKey, reply: reply)
        }
    }

    public func unmount(target: String) async throws -> CommandResult {
        guard isValidUnmountTarget(target) else { throw HelperClientError.invalidUnmountTarget(target) }
        return try await call { proxy, reply in proxy.unmount(target: target, reply: reply) }
    }

    public func teardown(sessionID: String? = nil) async throws -> CommandResult {
        try await call { proxy, reply in proxy.teardown(sessionID: sessionID, reply: reply) }
    }

    public func removeDependencies() async throws -> CommandResult {
        try await call { proxy, reply in proxy.removeDependencies(reply: reply) }
    }

    public func uninstallHelper() async throws -> CommandResult {
        try await call { proxy, reply in proxy.uninstallHelper(reply: reply) }
    }

    /// GUI Quit's final call after `unmount`/`teardown`: asks the privileged launchd helper to
    /// `exit(0)` itself so it doesn't linger as root after the app closes (Activity Monitor can't
    /// kill it without sudo). The helper replies before self-terminating, so this await returns
    /// cleanly — the connection dropping immediately after is expected, not an error.
    public func exitHelper() async throws -> CommandResult {
        try await call { proxy, reply in proxy.exitHelper(reply: reply) }
    }

    public func stageCLI(installScriptPath: String) async throws -> CommandResult {
        try await call { proxy, reply in proxy.stageCLI(installScriptPath: installScriptPath, reply: reply) }
    }

    /// Bare string reply, not a `CommandResult` — `version` never runs a shell command, so
    /// there's no exit code/output to wrap. Same error-handler-rejects-the-continuation wiring
    /// as `call()`, so a stale/unresponsive helper (the exact case this method exists to detect)
    /// throws instead of hanging. `nonisolated`, same reason `call()` above is: `NSXPCConnection`
    /// invokes the error handler and reply closure from its own internal dispatch queue, never
    /// the main actor — omitting this traps (`dispatch_assert_queue_fail`) the moment a real XPC
    /// callback actually fires off-main (confirmed live: this exact omission SIGTRAP'd
    /// `PopoverStateRenderTests`, which constructs `CLIAutoStager`/`HelperClient` for real).
    public nonisolated func version() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard let proxy = currentConnection().remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: HelperClientError.helper(error.localizedDescription))
            }) as? HelperXPCProtocol else {
                continuation.resume(throwing: HelperClientError.proxyUnavailable)
                return
            }
            proxy.version { versionHash in
                if let versionHash {
                    continuation.resume(returning: versionHash)
                } else {
                    continuation.resume(throwing: HelperClientError.decode)
                }
            }
        }
    }
}
