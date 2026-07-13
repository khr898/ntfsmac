import SwiftUI

/// GUI-PLAN.md "Popover — mounted": "Speed bar | Live throughput (read-only display) | Mounting
/// / mounted". Renders nothing while idle/error — this unit's Do clause ("hidden when idle").
/// `ui/prototype.html`'s "Transfer Speed" section (comp lines 168-196) shows separate animated
/// Read/Write rows — `ThroughputMonitor` only samples one combined interface-level byte count
/// (`gui/Drives/ThroughputMonitor.swift`, no read/write split exists), so this renders one row
/// in the same visual language rather than fabricating a fake split with no real data behind it.
public struct SpeedBar: View {
    @ObservedObject public var appState: AppState
    @ObservedObject public var monitor: ThroughputMonitor

    public init(appState: AppState, monitor: ThroughputMonitor) {
        self.appState = appState
        self.monitor = monitor
    }

    public var body: some View {
        // Exhaustive switch, not a boolean OR chain: a new `MountState` case must force a
        // decision here rather than silently falling through to "hidden".
        switch appState.state {
        case .mounting, .mountedReadWrite, .mountedReadOnly, .mountedReadOnlyDirty:
            VStack(alignment: .leading, spacing: 10) {
                Text("TRANSFER SPEED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary.opacity(0.7))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        HStack(spacing: 5) {
                            SpeedDirectionGlyph(color: .ntfsGreen, pointsUp: true)
                            Text("Combined")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ThroughputFormatter.format(monitor.bytesPerSecond))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.07))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(LinearGradient(colors: [.ntfsGreen, .ntfsBlue], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * activityFraction)
                                    .animation(.easeOut(duration: 0.3), value: monitor.bytesPerSecond)
                            }
                    }
                    .frame(height: 3)
                }
            }
        case .idle, .error:
            EmptyView()
        }
    }

    /// No fixed max scale is meaningful for an arbitrary NFS link, so this is a soft visual cue
    /// (log-scaled, capped) rather than a literal percentage-of-bandwidth — same honesty
    /// tradeoff as `SecurityIndicatorStatus.unknown`: an approximate bar, not a fabricated exact one.
    private var activityFraction: Double {
        guard monitor.bytesPerSecond > 0 else { return 0 }
        return min(1.0, log10(monitor.bytesPerSecond + 1) / 8.0)
    }
}
