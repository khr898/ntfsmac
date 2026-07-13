import SwiftUI

/// Plain-language summary row (this unit's Do clause: "render a plain-language summary" — not
/// a raw JSON/log dump).
public struct DiagnoseSummaryRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let isHealthy: Bool
}

/// Pure mapping from the real `DiagnoseReport` JSON shape to display rows — separated from the
/// `View` below the same way `StatusIcon`/`SecurityIndicator` are, so `DiagnoseRunnerTests` can
/// assert on parsed rows without a SwiftUI view-inspection dependency.
public enum DiagnoseSummary {
    public static func rows(for report: DiagnoseReport) -> [DiagnoseSummaryRow] {
        [
            DiagnoseSummaryRow(
                id: "binaries",
                label: "Vendor binaries",
                value: report.missingBinaries == 0 ? "all present" : "\(report.missingBinaries) missing",
                isHealthy: report.missingBinaries == 0
            ),
            DiagnoseSummaryRow(
                id: "quarantine",
                label: "Quarantine",
                value: report.quarantinedBinaries == 0 ? "clear" : "\(report.quarantinedBinaries) quarantined",
                isHealthy: report.quarantinedBinaries == 0
            ),
            DiagnoseSummaryRow(
                id: "kernel",
                label: "Kernel pin",
                value: report.kernelPin,
                isHealthy: report.kernelPin == "match"
            ),
            DiagnoseSummaryRow(
                id: "bridge",
                label: "vmnet bridge",
                value: report.bridge,
                isHealthy: report.bridge == "up"
            ),
        ]
    }
}

/// Reachable from idle + error states (this unit's Do clause) — the caller decides when to show
/// it; this view just renders whatever `DiagnoseRunner` currently has.
public struct DiagnosePanel: View {
    @ObservedObject public var runner: DiagnoseRunner

    public init(runner: DiagnoseRunner) {
        self.runner = runner
    }

    public var body: some View {
        Group {
            if let report = runner.report {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(DiagnoseSummary.rows(for: report)) { row in
                        Label("\(row.label): \(row.value)", systemImage: row.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(row.isHealthy ? Color.primary : Color.orange)
                            .font(.caption)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
            } else if let errorMessage = runner.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.ntfsRed.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ntfsRed.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ntfsRed.opacity(0.2)))
            } else if runner.isRunning {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }
}
