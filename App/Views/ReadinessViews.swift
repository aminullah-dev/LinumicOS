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

/// The counts of a scorecard as icon and number, the weakest first, then how much of it was read. The sentence it
/// stands for (`headline`) is what VoiceOver reads and what the pointer shows.
struct ReadinessTally: View {
    let summary: ReadinessSummary

    var body: some View {
        // A flow, not a fixed row: at the largest text sizes the counts go onto a second line instead of off the card.
        FlowLayout(spacing: 10, lineSpacing: 4) {
            count(.failed, summary.failed)
            count(.needsAttention, summary.needsAttention)
            count(.unknown, summary.unknown)
            count(.passed, summary.passed)
            Text(verbatim: summary.knownLine).font(.rowCaption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary.headline))
        .help(Text(verbatim: summary.headline))
    }

    @ViewBuilder
    private func count(_ state: ReadinessState, _ number: Int) -> some View {
        if number > 0 {
            HStack(spacing: 3) {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Text(number.formatted()).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        }
    }
}

/// One check: its name with its state beside it (icon, word and colour together, as on every badge), what was found
/// in one sentence, and where and when.
struct ReadinessRow: View {
    let result: ReadinessResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The state at the row's far edge, one column to run the eye down; under the name when they don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    state
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    state
                }
            }
            DirectionalText(result.evidence)
                .font(.rowBody)
                .foregroundStyle(result.state == .unknown || result.state == .notApplicable ? .secondary : .primary)
                .monospacedDigit()
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .selectableText()
            SourceLine(reference: result.source, date: result.date?.date)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text(verbatim: result.check.title).font(.rowTitle).multilineTextAlignment(.leading)
    }

    private var state: some View {
        BoardPill(text: result.state.title, symbol: result.state.symbol, color: result.state.tint)
    }
}

/// A project's scorecard: the same checks for every project, the ones that do not apply folded away.
struct ReadinessPanel: View {
    let readiness: ProductReadiness
    @State private var showNotApplicable = false

    var body: some View {
        let summary = readiness.summary
        // What failed first: the verdict above and the first row under it say the same thing.
        let shown = readiness.weakestFirst
        let skipped = readiness.results.filter { $0.state == .notApplicable }
        DashboardPanel(title: "Operational readiness") {
            PillRow(spacing: 10) {
                ReadinessBadge(summary: summary)
                ReadinessTally(summary: summary)
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
            PillRow(spacing: 8) {
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
                        Text(verbatim: readiness.title).font(.rowTitle).foregroundStyle(secondary ? .secondary : .primary)
                        ReadinessBadge(summary: summary)
                    }
                    ReadinessTally(summary: summary)
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
