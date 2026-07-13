import Foundation
import HelperShared

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
    // `nonisolated(unsafe)`: `deinit` can't be `@MainActor`-isolated, and `NSXPCConnection` isn't
    // `Sendable` — but Apple documents `invalidate()` as safe to call from any thread, so this is
    // a real, scoped, platform-backed exception, not a blind suppression. Explicit `Sendable` on
    // the class (added for `StaleHelperDetecting`'s `withTaskGroup`-based timeout in
    // `HelperInstaller`, which needs to capture a `HelperClient` in a `@Sendable` closure): safe
    // because `@MainActor` isolation already serializes every other access, and this one field is
    // the documented exception above, not a new unchecked one.
    private nonisolated(unsafe) let connection: NSXPCConnection

    public init(machServiceName: String = helperMachServiceName) {
        connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
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

    public func mount(device: String, driver: FsDriver, mountPoint: String? = nil, readOnly: Bool = false) async throws -> CommandResult {
        guard validateDevice(device) else { throw HelperClientError.invalidDevice(device) }
        return try await call { proxy, reply in
            proxy.mount(device: device, driver: driver.rawValue, mountPoint: mountPoint, readOnly: readOnly, reply: reply)
        }
    }

    public func unmount(target: String) async throws -> CommandResult {
        guard isValidUnmountTarget(target) else { throw HelperClientError.invalidUnmountTarget(target) }
        return try await call { proxy, reply in proxy.unmount(target: target, reply: reply) }
    }

    public func applyPfRules(subnetCIDR: String) async throws -> CommandResult {
        try await call { proxy, reply in proxy.applyPfRules(subnetCIDR: subnetCIDR, reply: reply) }
    }

    public func teardown(subnetCIDR: String? = nil) async throws -> CommandResult {
        try await call { proxy, reply in proxy.teardown(subnetCIDR: subnetCIDR, reply: reply) }
    }

    public func removeDependencies() async throws -> CommandResult {
        try await call { proxy, reply in proxy.removeDependencies(reply: reply) }
    }

    public func uninstallHelper() async throws -> CommandResult {
        try await call { proxy, reply in proxy.uninstallHelper(reply: reply) }
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
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
