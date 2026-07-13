import Foundation

/// Cumulative byte counter for the network interface(s) carrying NFS traffic. Read-only,
/// unprivileged (this unit's Do clause: "sample without privileged calls").
public protocol InterfaceByteCounting {
    func totalBytes() -> UInt64
}

/// vmnet.framework (what `vmnet-helper` uses) creates host-side `bridge1xx`-style interfaces
/// for its NAT/bridged networking — documented macOS/vmnet.framework behavior, not this repo's
/// own convention. Matching by name prefix is a heuristic: checked first whether the CLI exposes
/// a real interface name anywhere (`RuntimeInfo` in `vendor/.../api.rs`, `diagnose.sh`) — it
/// doesn't, so there is no exact per-mount identifier available to the GUI today. Flagged in
/// `SHARED_TASK_NOTES.md` for verification against a real mount; sums in+out bytes across every
/// matching interface rather than trying to pick "the one" bridge.
public struct RealInterfaceByteCounter: InterfaceByteCounting {
    public init() {}

    public func totalBytes() -> UInt64 {
        var addrsHead: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrsHead) == 0, let first = addrsHead else { return 0 }
        defer { freeifaddrs(addrsHead) }

        var total: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor {
            defer { cursor = iface.pointee.ifa_next }
            guard String(cString: iface.pointee.ifa_name).hasPrefix("bridge"),
                  let data = iface.pointee.ifa_data
            else { continue }
            let ifData = data.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
            // ponytail: ifi_ibytes/ifi_obytes are 32-bit on Darwin (if_data, not if_data64) —
            // wraps past 4GB cumulative traffic on one interface. computeRate's reset guard
            // drops that single sample (nil, not a crash/wrong reading); self-heals next tick
            // since `sample()` still records the wrapped count as the new baseline.
            total += UInt64(ifData.ifi_ibytes) + UInt64(ifData.ifi_obytes)
        }
        return total
    }
}

/// Formats a byte rate for display — pure, no I/O, this is the acceptance-tested surface.
public enum ThroughputFormatter {
    private static let units = ["B/s", "KB/s", "MB/s", "GB/s"]

    public static func format(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        var value = bytesPerSecond
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        let precision = unitIndex == 0 ? "%.0f %@" : "%.1f %@"
        return String(format: precision, value, units[unitIndex])
    }
}

/// Polls `InterfaceByteCounting` on an interval while mounting/mounted (GUI-PLAN.md "Speed bar
/// — Live throughput"); hidden/zeroed when idle — driven by whoever calls `stop()` (this unit's
/// Files list doesn't include the popover wiring, same deferred-integration precedent as
/// `3-drive-detect`/`3-mount-unmount`).
@MainActor
public final class ThroughputMonitor: ObservableObject {
    @Published public private(set) var bytesPerSecond: Double = 0

    private let counter: any InterfaceByteCounting
    private var pollTask: Task<Void, Never>?
    private var lastSample: (bytes: UInt64, at: Date)?

    public init(counter: any InterfaceByteCounting = RealInterfaceByteCounter()) {
        self.counter = counter
    }

    deinit {
        pollTask?.cancel()
    }

    public func start(interval: Duration = .seconds(1)) {
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        lastSample = nil
        bytesPerSecond = 0
    }

    /// Pure — separated from `sample()`'s real-clock/real-counter I/O so timing-independent
    /// tests can exercise the rate math directly (`ThroughputTests`'s "formatting" acceptance).
    nonisolated static func computeRate(previousBytes: UInt64, previousAt: Date, currentBytes: UInt64, currentAt: Date) -> Double? {
        let elapsed = currentAt.timeIntervalSince(previousAt)
        // A lower current count than the last sample means a counter reset (interface
        // replumbed, e.g. a fresh mount session) — drop that sample rather than report a
        // nonsensical negative rate.
        guard elapsed > 0, currentBytes >= previousBytes else { return nil }
        return Double(currentBytes - previousBytes) / elapsed
    }

    private func sample() {
        let now = Date()
        let bytes = counter.totalBytes()
        defer { lastSample = (bytes, now) }
        guard let last = lastSample,
              let rate = Self.computeRate(previousBytes: last.bytes, previousAt: last.at, currentBytes: bytes, currentAt: now)
        else { return }
        bytesPerSecond = rate
    }
}
