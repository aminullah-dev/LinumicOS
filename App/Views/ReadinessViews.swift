import LinumicCore
import SwiftUI

// MARK: - Operational readiness (آمادگی عملیاتی)

/// Passed is green, needing attention amber, failed red. Unknown and not applicable stay grey, never green, and every
/// state has its own icon, so colour is never the only sign.
extension ReadinessState {
    var tint: Color {
        switch self {
        case .passed: .statusGood
        case .needsAttention: .statusWarn
        case .failed: .statusBad
        case .unknown, .notApplicable: .statusUnknown
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        case .notApplicable: "minus.circle"
        }
    }
}

/// Only "ready" (every applicable check read and passed) is green. Not known and partly known are grey.
extension ReadinessStanding {
    var tint: Color {
        switch self {
        case .ready: .statusGood
        case .attention: .statusWarn
        case .failing: .statusBad
        case .notKnown, .partlyKnown: .statusUnknown
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.seal.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .failing: "xmark.octagon.fill"
        case .notKnown: "questionmark.circle.fill"
        case .partlyKnown: "circle.lefthalf.filled"
        }
    }
}

extension ReadinessDate {
    var date: Date {
        switch self {
        case .read(let at): at
        case .day(let day): day.start()
        }
    }
}

struct ReadinessBadge: View {
    let summary: ReadinessSummary

    var body: some View {
        BoardPill(text: summary.standing.title, symbol: summary.standing.symbol, color: summary.standing.tint, help: summary.headline)
    }
}

/// One check: its state (icon and word), what was found in one sentence, and where and when.
struct ReadinessRow: View {
    let result: ReadinessResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: result.state.symbol).foregroundStyle(result.state.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: result.check.title).font(.callout.weight(.semibold))
                    Spacer(minLength: 6)
                    Text(verbatim: result.state.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                DirectionalText(result.evidence)
                    .font(.callout)
                    .foregroundStyle(result.state == .unknown || result.state == .notApplicable ? .secondary : .primary)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                SourceLine(reference: result.source, date: result.date?.date)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A project's scorecard: the same checks for every project, the ones that do not apply folded away.
struct ReadinessPanel: View {
    let readiness: ProductReadiness
    @State private var showNotApplicable = false

    var body: some View {
        let summary = readiness.summary
        let shown = readiness.results.filter { $0.state != .notApplicable }
        let skipped = readiness.results.filter { $0.state == .notApplicable }
        DashboardPanel(title: "Operational readiness") {
            FitRow(spacing: 8) {
                ReadinessBadge(summary: summary)
                DirectionalText(summary.headline).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(shown) { result in
                Divider()
                ReadinessRow(result: result)
            }
            if !skipped.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showNotApplicable) {
                    ForEach(skipped) { ReadinessRow(result: $0) }
                } label: {
                    Text("\(skipped.count) checks do not apply to this project").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("The same checks for every project, each answered only from what was already read or recorded. Unknown means not read: it is never counted as passed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Every project with its headline, the weakest first. Archived projects sit below, in grey, and never push an active
/// one down.
struct ReadinessPortfolioView: View {
    let portfolio: ReadinessPortfolio
    let open: (String) -> Void
    @State private var showArchived = true

    var body: some View {
        let notKnown = portfolio.count(.notKnown) + portfolio.count(.partlyKnown)
        VStack(alignment: .leading, spacing: 12) {
            FitRow(spacing: 8) {
                pill(.failing, portfolio.count(.failing), String(localized: "\(portfolio.count(.failing)) failing"))
                pill(.attention, portfolio.count(.attention), String(localized: "\(portfolio.count(.attention)) need attention"))
                pill(.notKnown, notKnown, String(localized: "\(notKnown) not fully known"))
                pill(.ready, portfolio.count(.ready), String(localized: "\(portfolio.count(.ready)) ready"))
            }
            if !portfolio.active.isEmpty { rows(portfolio.active, secondary: false) }
            if !portfolio.archived.isEmpty {
                DisclosureGroup(isExpanded: $showArchived) {
                    rows(portfolio.archived, secondary: true).padding(.top, 8)
                } label: {
                    Text("\(portfolio.archived.count) archived projects").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Weakest first: failing, needing attention, not known, then ready. Every project gets the same checks, each answered only from what was already read or recorded; a check that was not read is Unknown and is never counted as passed. Nothing here creates a Desk item.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A count pill, coloured only when its count is not zero.
    private func pill(_ standing: ReadinessStanding, _ count: Int, _ text: String) -> some View {
        BoardPill(text: text, symbol: standing.symbol, color: count > 0 ? standing.tint : .statusUnknown)
    }

    private func rows(_ list: [ProductReadiness], secondary: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { readiness in
                ReadinessPortfolioRow(readiness: readiness, secondary: secondary) { open(readiness.id) }
                if readiness.id != list.last?.id { Divider() }
            }
        }
        .cardSurface()
    }
}

struct ReadinessPortfolioRow: View {
    let readiness: ProductReadiness
    var secondary = false
    let open: () -> Void

    var body: some View {
        let summary = readiness.summary
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    FitRow(spacing: 8, alignment: .firstTextBaseline) {
                        Text(verbatim: readiness.title).font(.callout.weight(.semibold)).foregroundStyle(secondary ? .secondary : .primary)
                        ReadinessBadge(summary: summary)
                    }
                    DirectionalText(summary.headline).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    // The first thing to look at: a failure, else what needs attention.
                    if let first = readiness.concerns.first {
                        Label {
                            DirectionalText("\(first.check.title): \(first.evidence)").lineLimit(2).multilineTextAlignment(.leading)
                        } icon: {
                            Image(systemName: first.state.symbol).foregroundStyle(first.state.tint).accessibilityHidden(true)
                        }
                        .font(.caption)
                        .foregroundStyle(secondary ? .secondary : .primary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityHint(Text("Opens this project's page with every check"))
    }
}
