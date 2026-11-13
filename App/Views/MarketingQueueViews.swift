import LinumicCore
import SwiftUI

// MARK: - The Marketing page (بازاریابی)

/// Every marketing item in one place (owner, 2026-11-13): each brand's scheduled queue (its end, the clock change: the
/// register's marketing obligations), the posts and social accounts, and market research. Marketing is shown nowhere
/// else: not on the Desk, the Center (except one line when something is overdue), the Obligations page, a project's
/// card or its readiness. Read-only toward the networks; it never posts. A ledger's text is never read: the page shows
/// when the ledger file last changed, and Verify opens it in its own app.
struct MarketingView: View {
    @Environment(Router.self) private var router
    @Environment(ObligationsModel.self) private var obligations
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        @Bindable var router = router
        let now = max(.now, monitor.now)
        let summary = MarketingSummary(register: obligations.register(now: now), today: KeyDay(now))
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                PageHeader(.marketing) {
                    PillRow(spacing: 8) {
                        if summary.overdue > 0 {
                            ReleaseBadge(text: String(localized: "\(summary.overdue) overdue"), symbol: "exclamationmark.octagon", color: .statusBad)
                        }
                        if summary.dueThisWeek > 0 {
                            ReleaseBadge(text: String(localized: "\(summary.dueThisWeek) due within 7 days"), symbol: "calendar.badge.exclamationmark", color: .statusWarn)
                        }
                        if summary.dateUnknown > 0 {
                            ReleaseBadge(text: String(localized: "\(summary.dateUnknown) with no date"), symbol: "questionmark.circle", color: .statusUnknown)
                        }
                        if summary.open == 0 {
                            ReleaseBadge(text: String(localized: "Nothing open in the queue"), symbol: "checkmark.circle", color: .statusUnknown)
                        }
                    }
                    Picker("Part", selection: $router.marketingTab) {
                        ForEach(MarketingTab.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 480)
                }
                switch router.marketingTab {
                case .queue: MarketingQueueTab()
                case .posts: ContentCalendarView()
                case .research: MarketIntelligenceView()
                }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle(SidebarItem.marketing.title)
    }
}

// MARK: - Queue

/// Each brand's marketing obligations beside its ledger, the brand with the oldest overdue row first. A row is dated,
/// closed with its evidence or reopened here, as on the Obligations page (the same sheets and the same obligations.json).
private struct MarketingQueueTab: View {
    @Environment(MarketingQueueModel.self) private var model
    @Environment(ObligationsModel.self) private var obligations
    @Environment(MonitorModel.self) private var monitor
    @Environment(Router.self) private var router
    @State private var adding = false
    @State private var completing: Obligation?
    @State private var dating: Obligation?
    @State private var highlighted: String?

    var body: some View {
        let now = max(.now, monitor.now)
        let today = KeyDay(now)
        let brands = MarketingQueue.urgentFirst(model.brands(obligations: obligations, now: now), today: today)
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            AdaptiveStack(spacing: 8) {
                Text("Each brand's scheduled queue and the clock change, with their sources. Nothing is posted from here. A ledger's text is never read: Verify opens it in its own app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if MarketingQueueModel.readsLedgers {
                        Button { Task { await model.refresh() } } label: { Label("Check ledgers", systemImage: "arrow.clockwise") }
                            .keyboardShortcut("r")
                            .help("Read the ledgers' modification dates again (never their text)")
                    }
                    Button { adding = true } label: { Label("Add…", systemImage: "plus") }
                        .help("Add a marketing date with its source")
                }
                .fixedSize()
            }
            ForEach(brands) { brand in
                MarketingBrandCard(brand: brand, today: today, checked: model.checkedAt != nil, highlighted: highlighted,
                                   verify: brand.ledger.map { ledger in { verify(ledger) } },
                                   done: { completing = $0 }, setDate: { dating = $0 }, reopen: { obligations.reopen($0) })
            }
            Text("A ledger's date is its file's modification date, read without opening it. A ledger that changed after a date was recorded may have moved that date: verify it there.")
                .font(.caption).foregroundStyle(.secondary)
            #if os(macOS)
            if !model.grantedFolders.isEmpty {
                HStack {
                    Text(String(localized: "Read-only grants for Verify: \(model.grantedFolders.joined(separator: ", "))"))
                        .font(.caption).foregroundStyle(.secondary).selectableText()
                    Spacer()
                    Button("Remove access", role: .destructive) { model.revokeAll() }
                }
            }
            #endif
        }
        .task { await model.refresh() }
        .onChange(of: router.request, initial: true) {
            // A marketing obligation to show (the Command Palette, an old link to it on the Obligations page).
            guard case .obligation(let id)? = router.take({ if case .obligation = $0 { true } else { false } }) else { return }
            highlighted = id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if highlighted == id { highlighted = nil }
            }
        }
        .sheet(isPresented: $adding) { ObligationAddSheet(areas: [.marketing]) }
        .sheet(item: $completing) { ObligationDoneSheet(obligation: $0) }
        .sheet(item: $dating) { ObligationDateSheet(obligation: $0) }
        .alert("Not opened", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
        .alert("Not saved", isPresented: Binding(get: { obligations.errorMessage != nil }, set: { if !$0 { obligations.errorMessage = nil } })) {
            Button("OK") { obligations.errorMessage = nil }
        } message: {
            Text(verbatim: obligations.errorMessage ?? "")
        }
    }

    private func verify(_ ledger: MarketingLedger) {
        #if os(macOS)
        model.verify(ledger)
        #endif
    }
}

private struct MarketingBrandCard: View {
    let brand: MarketingQueueBrand
    let today: KeyDay
    let checked: Bool
    let highlighted: String?
    let verify: (() -> Void)?
    let done: (Obligation) -> Void
    let setDate: (Obligation) -> Void
    let reopen: (Obligation) -> Void

    private var tint: Color {
        let open = brand.obligations.filter { !$0.isClosed }
        if open.contains(where: { ObligationRules.lane($0, today: today) == .overdue }) { return .statusBad }
        if !brand.changedSince.isEmpty || open.contains(where: { ObligationRules.lane($0, today: today) == .week }) { return .statusWarn }
        return .brandAccent
    }

    var body: some View {
        StripeCard(tint: tint) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: brand.brand).font(.panelTitle)
                Spacer()
                if let verify, MarketingQueueModel.readsLedgers {
                    Button(action: verify) { Label("Verify…", systemImage: "checkmark.magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Open the ledger in its own app to check the dates there. The first time, grant its folder (read-only).")
                }
            }
            if let ledger = brand.ledger {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileText).font(.rowCaption).foregroundStyle(.secondary)
                    Text(verbatim: ledger.displayFile).font(.caption2.monospaced()).foregroundStyle(.tertiary).selectableText()
                        .help(Text(String(localized: "Named as the ledger in: \(ledger.source)")))
                }
            } else {
                Text("No ledger is recorded for this brand.").font(.rowCaption).foregroundStyle(.secondary)
            }
            if brand.obligations.isEmpty {
                Text("No queue end is recorded for this brand.").font(.rowBody).foregroundStyle(.secondary)
            }
            ForEach(brand.obligations) { o in
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ObligationRowView(obligation: o, today: today, highlighted: highlighted == o.id,
                                      done: { done(o) }, setDate: { setDate(o) }, open: {}, closeAtSource: {}, reopen: { reopen(o) },
                                      showsContext: false)
                    if brand.changedSince.contains(o.id) {
                        ReleaseBadge(text: String(localized: "The ledger changed after this was recorded: verify"),
                                     symbol: "exclamationmark.triangle", color: .statusWarn)
                    }
                }
            }
        }
    }

    private var fileText: String {
        guard MarketingQueueModel.readsLedgers else { return String(localized: "Ledger dates are read on the Mac only.") }
        switch brand.file {
        case .modified(let d)?: return String(localized: "Ledger last changed \(d.formatted(date: .abbreviated, time: .shortened))")
        case .missing?: return String(localized: "The ledger file was not found.")
        case .unknown(let why)?: return String(localized: "When the ledger last changed is unknown (\(why)).")
        case nil: return checked ? String(localized: "When the ledger last changed is unknown.") : String(localized: "Not checked yet.")
        }
    }
}
