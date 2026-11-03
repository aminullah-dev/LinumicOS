import LinumicCore
import SwiftUI

// MARK: - Management centre (مرکز مدیریت)

/// The home page: what is waiting on the owner, which project has a problem, and which readings can't be trusted. It
/// arranges what the Desk and the Products page already built (`CenterBuilder`) and every row opens the page that holds
/// it, so nothing is decided or changed here. Read-only.
struct CenterView: View {
    @Environment(DeskModel.self) private var deskModel
    @Environment(ProductsModel.self) private var products
    @Environment(MonitorModel.self) private var monitor
    @Environment(AutomationEngine.self) private var automation
    @Environment(Router.self) private var router
    @State private var showQuiet = false

    /// Rows shown before "All on the Desk": a home page that lists everything answers nothing.
    private let waitingLimit = 6

    var body: some View {
        // Reading `monitor.now` re-renders every minute, so day counts and freshness stay current.
        let now = max(.now, monitor.now)
        let report = CenterBuilder.build(desk: deskModel.desk(now: now), products: products.report(now: now), today: KeyDay(now),
                                         tier: products.tiers.tier(forProduct:))
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header(report, now: now)
                DataFreshnessBanner(now: now)
                weeklyReview(report, now: now)
                waiting(report)
                focus(report)
                maintenance(report)
                alsoToday(report)
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private func header(_ report: CenterReport, now: Date) -> some View {
        let stale = automation.freshness(now: now).problems.count
        return PageHeader(.center, subtitle: Text(now.formatted(date: .complete, time: .omitted))) {
            FitRow(spacing: 8) {
                ReleaseBadge(text: String(localized: "\(report.waiting.count) waiting on you"), symbol: "person.fill.checkmark",
                             color: report.waiting.isEmpty ? .statusGood : .statusWarn)
                // Counted from what was last read: with stale sources it says so, and zero isn't shown as all clear.
                ReleaseBadge(text: stale > 0 ? String(localized: "\(report.problemCount) projects with a problem, as last read")
                                             : String(localized: "\(report.problemCount) projects with a problem"),
                             symbol: "exclamationmark.triangle",
                             color: report.problemCount > 0 ? .statusBad : (stale > 0 ? .statusUnknown : .statusGood))
                if stale > 0 {
                    ReleaseBadge(text: String(localized: "\(stale) sources are out of date"), symbol: "clock.badge.exclamationmark", color: .statusUnknown)
                }
            }
        }
    }

    // MARK: Weekly review

    /// Why the waiting list may be longer than the truth: its ledgers haven't been reviewed. Only says; the ledgers are
    /// edited where they are, and this app never writes to them.
    @ViewBuilder
    private func weeklyReview(_ report: CenterReport, now: Date) -> some View {
        if let oldest = report.overdueLedgers.first {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(.statusWarn).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weekly review: \(report.overdueLedgers.count) ledgers are due").font(.headline)
                    Text("Oldest review: \(oldest.reviewedOn.start().shortDate), \(oldest.reviewedOn.days(until: KeyDay(now))) days ago. Some items waiting on you may already be done.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Open the Desk") { router.go(.desk) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    // MARK: Waiting on you

    @ViewBuilder
    private func waiting(_ report: CenterReport) -> some View {
        section(String(localized: "Waiting on you")) {
            if report.waiting.isEmpty {
                Text("Nothing on the Desk says it needs you today or this week.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(report.waiting.prefix(waitingLimit)) { row in
                        CenterDeskRow(row: row)
                        if row.id != report.waiting.prefix(waitingLimit).last?.id { Divider() }
                    }
                }
                .cardSurface()
                if report.waiting.count > waitingLimit {
                    Button { router.go(.desk) } label: {
                        Text("All \(report.waiting.count) on the Desk")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !report.pullRows.isEmpty {
                Button { router.go(.releaseCenter) } label: {
                    Label { Text("\(report.pullRows.count) pull requests waiting for you") } icon: { Image(systemName: "arrow.triangle.pull") }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Projects

    private func focus(_ report: CenterReport) -> some View {
        section(String(localized: "In focus")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(report.focus) { project in
                    Button { openProject(project) } label: {
                        ProductBoardCard(card: project.card, waiting: project.waiting.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens every value of this product with its source"))
                }
            }
        }
    }

    @ViewBuilder
    private func maintenance(_ report: CenterReport) -> some View {
        section(String(localized: "Maintenance")) {
            if !report.maintenanceAttention.isEmpty {
                VStack(spacing: 0) {
                    ForEach(report.maintenanceAttention) { project in
                        CenterProjectRow(project: project) { openProject(project) }
                        if project.id != report.maintenanceAttention.last?.id { Divider() }
                    }
                }
                .cardSurface()
            }
            if !report.maintenanceQuiet.isEmpty {
                DisclosureGroup(isExpanded: $showQuiet) {
                    VStack(spacing: 0) {
                        ForEach(report.maintenanceQuiet) { project in
                            CenterProjectRow(project: project) { openProject(project) }
                            if project.id != report.maintenanceQuiet.last?.id { Divider() }
                        }
                    }
                    .cardSurface()
                    .padding(.top, 8)
                } label: {
                    Text("\(report.maintenanceQuiet.count) with no known problem").font(.callout)
                }
            }
        }
    }

    // MARK: Also today

    @ViewBuilder
    private func alsoToday(_ report: CenterReport) -> some View {
        if !report.alsoToday.isEmpty {
            section(String(localized: "Also today")) {
                VStack(spacing: 0) {
                    ForEach(report.alsoToday.prefix(waitingLimit)) { row in
                        CenterDeskRow(row: row)
                        if row.id != report.alsoToday.prefix(waitingLimit).last?.id { Divider() }
                    }
                }
                .cardSurface()
                if report.alsoToday.count > waitingLimit {
                    Button { router.go(.desk) } label: { Text("All \(report.alsoToday.count) on the Desk") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func openProject(_ project: CenterProject) {
        router.go(.productBoard, request: .productCard(project.id))
    }
}

/// One Desk row. Opens it on the Desk, where its source, its marks and its actions are.
struct CenterDeskRow: View {
    @Environment(Router.self) private var router
    let row: DeskRow

    var body: some View {
        Button { router.go(.desk, request: .deskItem(row.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: row.item.severity.symbol)
                    .foregroundStyle(row.item.severity.color)
                    .accessibilityLabel(Text(verbatim: row.item.severity.title))
                VStack(alignment: .leading, spacing: 2) {
                    DirectionalText(row.item.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(verbatim: row.item.domain.name)
                        // An old reading says how old, so a line that may already be done isn't taken as today's news.
                        if row.isStale, let at = row.item.evidence.readAt {
                            Label { Text("Last read \(at.shortDate)") } icon: { Image(systemName: "clock.badge.exclamationmark") }
                                .foregroundStyle(.statusWarn)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
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
    }
}

/// One maintenance project: its name and what is known to be wrong, or that it could not be read.
struct CenterProjectRow: View {
    let project: CenterProject
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: project.card.product.title).font(.callout.weight(.semibold))
                    if let first = project.attention.first {
                        Text(verbatim: project.attention.count > 1 ? "\(first.text) +\(project.attention.count - 1)" : first.text)
                            .font(.caption).foregroundStyle(first.isSerious ? Color.statusBad : Color.statusWarn).lineLimit(2)
                    } else if project.isUnread {
                        Text("Not read yet, so unknown").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !project.waiting.isEmpty {
                    PillLabel(text: Text("\(project.waiting.count) waiting"), symbol: "person.fill.checkmark", color: .statusWarn)
                }
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
