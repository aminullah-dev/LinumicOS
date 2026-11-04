import LinumicCore
import SwiftUI

// MARK: - The centre (مرکز)

/// The home page, alerts first: what is waiting on the owner, which project has a problem, and which readings can't be
/// trusted. Only exceptions are shown; when there are none it says "All clear" and shows the projects in focus. It
/// arranges what the Desk, the Products page and the Brief already built (`CenterBuilder`), and every row opens the page
/// that holds it, so nothing is decided or changed here. Read-only.
///
/// The Brief and the Dashboard folded into it (2026-11-04): every Brief line is a Desk item, and so here when it needs
/// the owner; the Brief's "What changed since yesterday" and the Dashboard's facts to confirm are here, behind a tap or
/// only when there are some. Their pages are in the Archive.
struct CenterView: View {
    @Environment(DeskModel.self) private var deskModel
    @Environment(ProductsModel.self) private var products
    @Environment(MonitorModel.self) private var monitor
    @Environment(AutomationEngine.self) private var automation
    @Environment(BriefModel.self) private var briefs
    @Environment(InventoryModel.self) private var inventory
    @Environment(Router.self) private var router
    @State private var showQuiet = false
    @State private var showAlsoToday = false
    @State private var showChanges = false

    /// Rows shown before "Open the Desk": a home page that lists everything answers nothing.
    private let waitingLimit = 6

    var body: some View {
        // Reading `monitor.now` re-renders every minute, so day counts and freshness stay current.
        let now = max(.now, monitor.now)
        let report = CenterBuilder.build(desk: deskModel.desk(now: now), products: products.report(now: now), today: KeyDay(now),
                                         tier: products.tiers.tier(forProduct:))
        let stale = automation.freshness(now: now).problems.count
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header(report, stale: stale, now: now)
                DataFreshnessBanner(now: now)
                weeklyReview(report, now: now)
                confirmations
                waiting(report)
                focus(report)
                maintenance(report)
                alsoToday(report)
                changes(now: now)
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    /// The day, one status line, and search. A count is shown here and nowhere else on the page.
    private func header(_ report: CenterReport, stale: Int, now: Date) -> some View {
        PageHeader(.center, subtitle: Text(now.formatted(date: .complete, time: .omitted))) {
            FitRow(spacing: 8) {
                if report.isAllClear(staleSources: stale) {
                    ReleaseBadge(text: String(localized: "All clear"), symbol: "checkmark.circle.fill", color: .statusGood)
                } else {
                    if !report.waiting.isEmpty {
                        ReleaseBadge(text: String(localized: "\(report.waiting.count) waiting on you"), symbol: "person.fill.checkmark", color: .statusWarn)
                    }
                    // Counted from what was last read: with stale sources it says so (the banner below names them).
                    if report.problemCount > 0 {
                        ReleaseBadge(text: stale > 0 ? String(localized: "\(report.problemCount) projects with a problem, as last read")
                                                     : String(localized: "\(report.problemCount) projects with a problem"),
                                     symbol: "exclamationmark.triangle", color: .statusBad)
                    }
                }
            }
            CenterSearchButton()
        }
    }

    // MARK: Notices

    /// Why the waiting list may be longer than the truth: its ledgers haven't been reviewed. Only says; the ledgers are
    /// edited where they are, and this app never writes to them.
    @ViewBuilder
    private func weeklyReview(_ report: CenterReport, now: Date) -> some View {
        if let oldest = report.overdueLedgers.first {
            CenterNotice(symbol: "calendar.badge.clock", color: .statusWarn,
                         title: Text("Weekly review: \(report.overdueLedgers.count) ledgers are due"),
                         detail: Text("Oldest review: \(oldest.reviewedOn.start().shortDate), \(oldest.reviewedOn.days(until: KeyDay(now))) days ago. Some items waiting on you may already be done."),
                         action: Text("Open the Desk")) { router.go(.desk) }
        }
    }

    /// From the Dashboard: inventory facts that wait for the owner's confirmation. Shown only when there are some.
    @ViewBuilder
    private var confirmations: some View {
        let s = inventory.summary
        if s.pendingConfirmations > 0 {
            CenterNotice(symbol: s.conflictingItems > 0 ? "exclamationmark.triangle.fill" : "person.badge.clock",
                         color: s.conflictingItems > 0 ? .statusBad : .statusWarn,
                         title: Text("\(s.pendingConfirmations) facts need your confirmation"),
                         detail: s.conflictingItems > 0 ? Text("\(s.conflictingItems) of them conflict with another source.") : nil,
                         action: Text("Open Verification")) { router.go(.verification) }
        }
    }

    // MARK: Waiting on you

    /// The owner's rows, the worst first; pull requests and quiet agents as one line each. Nothing when nothing waits:
    /// the header already says "All clear".
    @ViewBuilder
    private func waiting(_ report: CenterReport) -> some View {
        if !report.waiting.isEmpty || !report.pullRows.isEmpty || !report.quietAgentRows.isEmpty {
            section(String(localized: "Waiting on you")) {
                if !report.waiting.isEmpty {
                    rows(Array(report.waiting.prefix(waitingLimit)))
                }
                FitRow(spacing: 16) {
                    if report.waiting.count > waitingLimit {
                        Button { router.go(.desk) } label: {
                            Label { Text("Open the Desk") } icon: { Image(systemName: SidebarItem.desk.symbol) }
                        }
                    }
                    if !report.pullRows.isEmpty {
                        Button { router.go(.releaseCenter) } label: {
                            Label { Text("\(report.pullRows.count) pull requests waiting for you") } icon: { Image(systemName: "arrow.triangle.pull") }
                        }
                    }
                    if !report.quietAgentRows.isEmpty {
                        Button { router.go(.agents) } label: {
                            Label { Text("\(report.quietAgentRows.count) agents with no recent pull request") } icon: { Image(systemName: "moon.zzz") }
                        }
                    }
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
                    .accessibilityHint(Text("Opens this project's page"))
                }
            }
        }
    }

    @ViewBuilder
    private func maintenance(_ report: CenterReport) -> some View {
        if !report.maintenanceAttention.isEmpty || !report.maintenanceQuiet.isEmpty {
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
    }

    // MARK: Behind a tap

    /// Rows due today that are true but not the owner's to do: collapsed, so they never crowd what is.
    @ViewBuilder
    private func alsoToday(_ report: CenterReport) -> some View {
        if !report.alsoToday.isEmpty {
            DisclosureGroup(isExpanded: $showAlsoToday) {
                VStack(alignment: .leading, spacing: 8) {
                    rows(Array(report.alsoToday.prefix(waitingLimit)))
                    if report.alsoToday.count > waitingLimit {
                        Button { router.go(.desk) } label: { Text("Open the Desk") }.buttonStyle(.borderless)
                    }
                }
                .padding(.top, 8)
            } label: {
                disclosureLabel(String(localized: "Also today"), count: report.alsoToday.count)
            }
        }
    }

    /// From the Brief: what changed since yesterday's snapshot. Information, so collapsed; nothing when nothing changed.
    @ViewBuilder
    private func changes(now: Date) -> some View {
        if let section = briefs.brief(now: now).section(.changes), case .items = section.state, !section.lines.isEmpty {
            DisclosureGroup(isExpanded: $showChanges) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.lines) { line in
                        BriefLineRow(line: line) { router.open($0) }
                        if line.id != section.lines.last?.id { Divider() }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .padding(.top, 8)
            } label: {
                disclosureLabel(section.kind.title, count: section.lines.count)
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

    private func rows(_ list: [DeskRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { row in
                CenterDeskRow(row: row)
                if row.id != list.last?.id { Divider() }
            }
        }
        .cardSurface()
    }

    private func disclosureLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(.headline)
            PillLabel(text: Text(verbatim: count.formatted()), color: .statusInfo)
        }
        .accessibilityElement(children: .combine)
    }

    private func openProject(_ project: CenterProject) {
        router.go(.productBoard, request: .productCard(project.id))
    }
}

/// Search as the way to anything: the Command Palette, from the top of the home page (⌘K anywhere).
private struct CenterSearchButton: View {
    @Environment(Router.self) private var router
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button { router.isPalettePresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Search screens, records and commands").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                #if os(macOS)
                Text(verbatim: "⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityHidden(true)
                #endif
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.08), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Search screens, records and commands (⌘K)"))
        .accessibilityHint(Text("Opens the Command Palette"))
    }
}

/// One notice on the centre: what is off, in one line, and the one button that goes where it is fixed. The same card
/// for every notice, so the page has one shape for "look here".
private struct CenterNotice: View {
    let symbol: String
    let color: Color
    let title: Text
    var detail: Text?
    let action: Text
    let perform: () -> Void

    init(symbol: String, color: Color, title: Text, detail: Text? = nil, action: Text, perform: @escaping () -> Void) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.detail = detail
        self.action = action
        self.perform = perform
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title.font(.headline)
                if let detail { detail.font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button(action: perform) { action }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
