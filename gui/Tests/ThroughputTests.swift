import Foundation
import Testing
@testable import NtfsmacGUI

// GUI-PLAN.md "Speed bar — Live throughput": this unit's acceptance is formatting + zero/idle
// handling. `computeRate` is pure (no real clock/interface I/O), so it's tested directly rather
// than through `ThroughputMonitor`'s real `Task.sleep`-driven polling loop (timing-flaky).

@Test func formatsBytesPerSecondAcrossUnitBoundaries() {
    #expect(ThroughputFormatter.format(0) == "0 B/s")
    #expect(ThroughputFormatter.format(512) == "512 B/s")
    #expect(ThroughputFormatter.format(1_500) == "1.5 KB/s")
    #expect(ThroughputFormatter.format(12_400_000) == "12.4 MB/s")
    #expect(ThroughputFormatter.format(3_200_000_000) == "3.2 GB/s")
}

@Test func formatsNegativeOrZeroAsIdleZero() {
    #expect(ThroughputFormatter.format(0) == "0 B/s")
    #expect(ThroughputFormatter.format(-100) == "0 B/s")
}

@Test func computeRateReturnsBytesPerSecondOverElapsedInterval() {
    let start = Date()
    let rate = ThroughputMonitor.computeRate(
        previousBytes: 1_000, previousAt: start,
        currentBytes: 3_000, currentAt: start.addingTimeInterval(2)
    )
    #expect(rate == 1_000)
}

@Test func computeRateReturnsNilWhenNoTimeHasElapsed() {
    let now = Date()
    let rate = ThroughputMonitor.computeRate(
        previousBytes: 1_000, previousAt: now,
        currentBytes: 2_000, currentAt: now
    )
    #expect(rate == nil)
}

@Test func computeRateReturnsNilOnCounterReset() {
    // A lower current count than the last sample (interface replumbed / fresh session) must
    // never surface as a negative rate.
    let start = Date()
    let rate = ThroughputMonitor.computeRate(
        previousBytes: 5_000, previousAt: start,
        currentBytes: 100, currentAt: start.addingTimeInterval(1)
    )
    #expect(rate == nil)
}

@MainActor
@Test func monitorStartsAtZero() {
    // Only proves 0->0 idle handling, not an actual nonzero->0 reset: `bytesPerSecond` is
    // `private(set)` and `sample()` is private, so there's no seam to drive it nonzero without
    // reintroducing a real-clock dependency (the polling loop this file deliberately avoids
    // testing directly). `computeRate`'s own tests above cover the real rate math.
    let monitor = ThroughputMonitor(counter: FixedByteCounter(bytes: 0))
    #expect(monitor.bytesPerSecond == 0)
    monitor.stop()
    #expect(monitor.bytesPerSecond == 0)
}

private struct FixedByteCounter: InterfaceByteCounting {
    let bytes: UInt64
    func totalBytes() -> UInt64 { bytes }
}
