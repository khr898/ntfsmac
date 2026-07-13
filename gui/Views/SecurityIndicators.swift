import SwiftUI

/// GUI-PLAN.md v1 feature 5: "Security indicators (isolated network ✓, VPN-bypass ✓)". Three
/// states, not two — `PLAN.md` Phase 1 (pf/route hardening) is deferrable/non-blocking
/// (`SHARED_TASK_NOTES.md` GATES section), so a real install can legitimately have no hardening
/// data to report at all. `.unknown` exists specifically so "no data" never renders as `.enforced`.
public enum SecurityIndicatorStatus: Equatable, Sendable {
    case enforced
    case notEnforced
    case unknown
}

public struct SecurityIndicatorStyle: Equatable {
    public let symbolName: String
    public let color: Color
    public let text: String

    // `fileprivate`, not the default memberwise init: the "never a false ✓" guarantee must be
    // compiler-enforced, not just true because nothing else in the module happens to call
    // `SecurityIndicator.style` today. Only that function (same file) can construct a value.
    fileprivate init(symbolName: String, color: Color, text: String) {
        self.symbolName = symbolName
        self.color = color
        self.text = text
    }
}

/// This unit's Do clause, verbatim: "when Phase 1 hardening is not installed, show 'not
/// enforced' — never a false ✓." `.unknown` gets the same non-affirmative treatment for the
/// same reason: an indicator this code cannot currently evaluate must never look like a pass.
public enum SecurityIndicator {
    public static func style(for status: SecurityIndicatorStatus, label: String) -> SecurityIndicatorStyle {
        switch status {
        case .enforced:
            // VoiceOver symmetry: all three states self-describe by text alone, not just by
            // icon/color for the positive case (a bare label relies on the system's default
            // accessibility description of the SF Symbol glyph, less robust than the others).
            return SecurityIndicatorStyle(symbolName: "checkmark.shield.fill", color: .ntfsGreen, text: "\(label): enforced")
        case .notEnforced:
            return SecurityIndicatorStyle(symbolName: "exclamationmark.shield.fill", color: .ntfsYellow, text: "\(label): not enforced")
        case .unknown:
            return SecurityIndicatorStyle(symbolName: "questionmark.diamond", color: .secondary, text: "\(label): unknown")
        }
    }
}

/// Read-only display. Wiring real `isolatedNetwork`/`vpnBypass`/`pfRulesLoaded` values from a
/// live helper/diagnose check is later units' territory (`3-diagnose-ui` runs `ntfsmac diagnose
/// --json`; Phase 1's own pf-anchor/route-guard state isn't currently surfaced by `diagnose.sh`
/// at all — flagged in `SHARED_TASK_NOTES.md`) — this unit's Files list is display-only.
/// `ui/prototype.html`'s Security section (comp lines 201-224) always shows three rows
/// (network isolated / VPN bypass active / pf firewall rules loaded), stacked vertically with a
/// small circular checkmark badge each — `pfRulesLoaded` didn't exist before this pass because
/// only two of the three were ever wired; added for visual parity, same `.unknown`-by-default
/// honesty as the other two until Phase 1 surfaces real state.
public struct SecurityIndicatorsView: View {
    public let isolatedNetwork: SecurityIndicatorStatus
    public let vpnBypass: SecurityIndicatorStatus
    public let pfRulesLoaded: SecurityIndicatorStatus

    public init(
        isolatedNetwork: SecurityIndicatorStatus,
        vpnBypass: SecurityIndicatorStatus,
        pfRulesLoaded: SecurityIndicatorStatus = .unknown
    ) {
        self.isolatedNetwork = isolatedNetwork
        self.vpnBypass = vpnBypass
        self.pfRulesLoaded = pfRulesLoaded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // `ui/prototype.html` comp lines 202-203/376-377 — same uppercase-tracked title
            // style `SpeedBar`'s "TRANSFER SPEED" uses. Missing entirely before this pass.
            Text("SECURITY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary.opacity(0.7))
            VStack(alignment: .leading, spacing: 6) {
                row("Network isolated", isolatedNetwork)
                row("VPN bypass active", vpnBypass)
                row("pf firewall rules loaded", pfRulesLoaded)
            }
        }
    }

    private func row(_ label: String, _ status: SecurityIndicatorStatus) -> some View {
        let style = SecurityIndicator.style(for: status, label: label)
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(style.color.opacity(0.14))
                    .overlay(Circle().strokeBorder(style.color.opacity(0.3)))
                if status == .enforced {
                    ShieldCheckGlyph(color: style.color)
                } else {
                    Image(systemName: style.symbolName)
                        .font(.system(size: 7))
                        .foregroundStyle(style.color)
                }
            }
            .frame(width: 15, height: 15)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(style.text)
    }
}
