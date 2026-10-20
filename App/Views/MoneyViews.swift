import LinumicCore
import SwiftUI

/// Money (پول): who paid, what is on the way, what we owe salons and what we pay, read-only, from what the WorkTrack
/// and Operations models already read and the obligations register. Built on every render; nothing is saved. Every
/// figure says where and when it was read; one that was not read is Unknown with its reason, never 0. Amounts stay in
/// their own currency, side by side.
struct MoneyView: View {
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(OperationsModel.self) private var operations
    @Environment(ObligationsModel.self) private var obligations
    @Environment(Router.self) private var router
    @State private var isReading = false

    var body: some View {
        let input = MoneyInput.collect(worktrack: worktrack, safeBeauty: operations.safeBeauty, obligations: obligations)
        let report = MoneyBuilder.build(input, now: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(input)
                summary(report)
                received(report)
                onTheWay(report, input: input)
                salons(report, input: input)
                wePay(report)
                stores(report)
                Text("Nothing on this page is saved on this device or sent to Linumic's cloud. Automation reads it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .refreshable { await readNow() }
        .navigationTitle(SidebarItem.money.title)
        .toolbar {
            ToolbarItem {
                Button { Task { await readNow() } } label: { Label("Read now", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(isReading)
                    .help("Read WorkTrack (the company list with it, for the TEST marks) and SafeBeauty's balances again")
            }
        }
    }

    /// The whole WorkTrack refresh, not the money parts alone: invoices are filtered with the TEST and DUPLICATE marks
    /// of the same reading. SafeBeauty's balances at the same time.
    private func readNow() async {
        isReading = true
        defer { isReading = false }
        async let w: Void = worktrack.refresh()
        async let s: Void = operations.safeBeauty.refreshBalances()
        _ = await (w, s)
    }

    // MARK: Header and summary

    private func header(_ input: MoneyInput) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read-only. Every figure says where and when it was read. Amounts stay in their own currency: never converted, never added across currencies.")
                .font(.callout).foregroundStyle(.secondary)
            FitRow(spacing: 8) {
                if let env = input.worktrack.environment, env != "production" {
                    ReleaseBadge(text: String(localized: "WorkTrack: \(env), not production"), symbol: "theatermasks", color: .blue)
                }
                if let env = input.safeBeauty.environment, env != "production" {
                    ReleaseBadge(text: String(localized: "SafeBeauty: \(env), not production"), symbol: "theatermasks", color: .blue)
                }
                if isReading { ProgressView().controlSize(.small) }
            }
        }
    }

    private func summary(_ report: MoneyReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            MoneySummaryCard(question: .received, symbol: "arrow.down.circle", tint: .green,
                             figures: [(report.figure(.worktrackHesabPayReceived), String(localized: "HesabPay")),
                                       (report.figure(.worktrackInvoicesPaid), String(localized: "By hand"))])
            MoneySummaryCard(question: .onTheWay, symbol: "clock.arrow.circlepath", tint: .blue,
                             figures: [(report.figure(.worktrackRenewalsExpected), String(localized: "Renewals (forecast)")),
                                       (report.figure(.worktrackInvoicesOutstanding), String(localized: "Invoices sent"))])
            MoneySummaryCard(question: .owedToSalons, symbol: "building.2", tint: .orange,
                             figures: [(report.figure(.safeBeautyOwedToSalons), String(localized: "We owe")),
                                       (report.figure(.safeBeautyOwedBySalons), String(localized: "They owe us"))])
            MoneySummaryCard(question: .wePay, symbol: "creditcard", tint: .purple,
                             figures: [(report.figure(.accountCosts), String(localized: "As each bill says"))])
        }
    }

    // MARK: Sections

    private func received(_ report: MoneyReport) -> some View {
        MoneySection(title: MoneyQuestion.received.title, symbol: "arrow.down.circle") {
            MoneyFigureRow(figure: report.figure(.worktrackHesabPayReceived))
            if let revenue = report.revenue {
                MoneyBreakdown(title: String(localized: "By Solar Hijri month (Kabul)"),
                               rows: revenue.earned.byMonth.prefix(6).map { m in
                                   ("\(m.year)/\(String(format: "%02d", m.month))", MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(m.totalAfn), .afn)), m.orderCount)
                               })
                MoneyBreakdown(title: String(localized: "By plan"),
                               rows: revenue.earned.byPlan.map { ($0.plan, MoneyFormat.text(MoneyAmount(MoneyAmount.decimal($0.totalAfn), .afn)), $0.orderCount) })
                if revenue.excluded.companyCount > 0 {
                    let amount = MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(revenue.excluded.amountAfn), .afn))
                    MoneyNote(String(localized: "Left out: \(revenue.excluded.companyCount) TEST or DUPLICATE companies (\(revenue.excluded.orderCount) orders, \(amount))."))
                }
                MoneyNote(String(localized: "Paid orders of a TEST company that was purged count as earned again: WorkTrack leaves out only companies that still exist. Mark test companies TEST; do not purge one that paid until WorkTrack is fixed."),
                          symbol: "exclamationmark.triangle", tint: .orange)
                MoneyNote(String(localized: "Pending HesabPay checkouts are not counted: WorkTrack has no route that lists them across companies."))
                MoneyNote(String(localized: "Who paid each HesabPay order is on that company's page in WorkTrack customers."))
            }
            Divider()
            MoneyFigureRow(figure: report.figure(.worktrackInvoicesPaid))
            Text("Typed by hand in the WorkTrack CRM. Kept apart from HesabPay and never added to it: one payment can be in both.")
                .font(.caption).foregroundStyle(.secondary)
            if !report.paidByMethod.isEmpty {
                MoneyBreakdown(title: String(localized: "By method"),
                               rows: report.paidByMethod.map { (methodTitle($0.method), MoneyFormat.text($0.totals), $0.totals.count) })
            }
            if !report.recentPaid.isEmpty {
                MoneyInvoiceList(title: String(localized: "Paid most recently"), rows: report.recentPaid)
            }
        }
    }

    private func onTheWay(_ report: MoneyReport, input: MoneyInput) -> some View {
        MoneySection(title: MoneyQuestion.onTheWay.title, symbol: "clock.arrow.circlepath") {
            MoneyFigureRow(figure: report.figure(.worktrackRenewalsExpected))
            if let revenue = report.revenue {
                Text("Forecast at today's prices, not money received: renewals of the next \(revenue.expected.windowDays) days, as WorkTrack counts them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(revenue.expected.renewals.enumerated()), id: \.offset) { _, r in
                    Button {
                        router.go(.worktrackCustomers, request: .worktrackCompany(r.companyId))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: r.name).fontWeight(.medium)
                                Text(verbatim: "\(r.plan) · \(r.term) · \(r.expiresAt)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(r.amountAfn), .afn))).monospacedDigit()
                                Text("in \(r.daysUntilExpiry) days").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the company in WorkTrack customers"))
                }
            }
            if let n = report.counts.graceLicences, n > 0 {
                MoneyNote(String(localized: "\(n) licences are in their grace days after expiry; WorkTrack's forecast leaves them out."))
            }
            Divider()
            MoneyFigureRow(figure: report.figure(.worktrackInvoicesOutstanding))
            MoneyFigureRow(figure: report.figure(.worktrackInvoicesOverdue))
            if !report.openInvoices.isEmpty {
                MoneyInvoiceList(title: String(localized: "Sent, not paid"), rows: report.openInvoices)
            }
            invoiceNotes(report)
            if let console = WorkTrackEnvironment(rawValue: input.worktrack.environment ?? "")?.console {
                Link(destination: console) { Label("Open WorkTrack console", systemImage: "arrow.up.forward.app") }
                    .help(Text(verbatim: console.absoluteString))
            }
        }
    }

    @ViewBuilder
    private func invoiceNotes(_ report: MoneyReport) -> some View {
        let c = report.counts
        if let e = report.invoiceExclusions, e.count > 0 {
            MoneyNote(String(localized: "Left out: \(e.count) paid or sent invoices of TEST or DUPLICATE companies (\(MoneyFormat.text(e)))."))
        }
        if let n = c.invoicesCompanyMissing, n > 0 {
            MoneyNote(String(localized: "\(n) invoices belong to a WorkTrack company that is not in the company list (deleted, or past its limit); they are left out."),
                      symbol: "exclamationmark.triangle", tint: .orange)
        }
        if let n = c.invoicesAccountMissing, n > 0 {
            MoneyNote(String(localized: "\(n) invoices name a CRM account that was not in the list read; they are counted."), symbol: "exclamationmark.triangle", tint: .orange)
        }
        if let n = c.invoicesNotLinked, n > 0 {
            MoneyNote(String(localized: "\(n) invoices belong to CRM accounts not linked to a WorkTrack company; they are counted."))
        }
        if let n = c.sentWithoutDueDate, n > 0 {
            MoneyNote(String(localized: "\(n) sent invoices have no due date."))
        }
        if let n = c.drafts, n > 0 {
            MoneyNote(String(localized: "\(n) drafts are not counted."))
        }
    }

    private func salons(_ report: MoneyReport, input: MoneyInput) -> some View {
        MoneySection(title: MoneyQuestion.owedToSalons.title, symbol: "building.2") {
            MoneyFigureRow(figure: report.figure(.safeBeautyOwedToSalons))
            MoneyFigureRow(figure: report.figure(.safeBeautyOwedBySalons))
            MoneyNote(String(localized: "Never netted: these are different salons."))
            MoneyNote(String(localized: "SafeBeauty has no TEST mark, so every salon balance is counted."))
            FitRow(spacing: 12) {
                if let admin = SafeBeautyEnvironment(rawValue: input.safeBeauty.environment ?? "")?.adminPanel {
                    Link(destination: admin) { Label("Open SafeBeauty admin", systemImage: "arrow.up.forward.app") }
                        .help(Text(verbatim: admin.absoluteString))
                }
                Button {
                    router.operationsTab = .safeBeauty
                    router.go(.operations)
                } label: { Label("Salon list in Operations", systemImage: "tray.full") }
            }
        }
    }

    private func wePay(_ report: MoneyReport) -> some View {
        MoneySection(title: MoneyQuestion.wePay.title, symbol: "creditcard") {
            MoneyFigureRow(figure: report.figure(.accountCosts))
            Text("As each account's bill says: per currency and per billing cycle. Never converted, never turned into a yearly figure.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.costs) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.vendor).fontWeight(.medium)
                        Text(verbatim: row.cost.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: row.cost.text).monospacedDigit()
                        if let day = row.recordedOn {
                            Text("Recorded \(day.description)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let without = report.counts.accountsWithoutCost, let total = report.counts.accountsTotal, without > 0 {
                MoneyNote(String(localized: "\(without) of \(total) accounts have no recorded cost: \(report.accountsWithoutCost.joined(separator: ", "))."))
            }
            Button { router.go(.obligations) } label: { Label("Open Obligations & accounts", systemImage: "calendar.badge.exclamationmark") }
        }
    }

    private func stores(_ report: MoneyReport) -> some View {
        MoneySection(title: MoneyQuestion.storeProceeds.title, symbol: "bag") {
            MoneyFigureRow(figure: report.figure(.appStoreProceeds))
            MoneyFigureRow(figure: report.figure(.googlePlayProceeds))
            Text("Neither WorkTrack nor SafeBeauty sells in-app, and no finance key is on this device: new finance keys are out of scope until the owner decides (roadmap §5).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func methodTitle(_ method: String) -> String {
        switch method {
        case "BANK": String(localized: "Bank")
        case "CASH": String(localized: "Cash")
        case "HAWALA": String(localized: "Hawala")
        case "OTHER": String(localized: "Other")
        case "": String(localized: "No method")
        default: method
        }
    }
}

// MARK: - Parts

/// A soft frosted card with one question's figures, each in its own currency, never added together.
private struct MoneySummaryCard: View {
    let question: MoneyQuestion
    let symbol: String
    let tint: Color
    let figures: [(MoneyFigure, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(verbatim: question.title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(figures.enumerated()), id: \.offset) { _, pair in
                let (figure, label) = pair
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
                    MoneyAmountsText(figure: figure, font: .title3.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }
}

/// A figure's amounts, one line per currency (and per billing cycle for costs), or Unknown. Never a sum across them.
private struct MoneyAmountsText: View {
    let figure: MoneyFigure
    var font: Font = .body.weight(.semibold)

    var body: some View {
        switch figure.value {
        case .known(let totals):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(totals.amounts, id: \.currency) { amount in
                    Text(verbatim: amountText(MoneyFormat.text(amount))).font(font).monospacedDigit()
                }
            }
        case .knownByCycle(let cycles):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(MoneyFormat.byCycle(cycles), id: \.self) { line in
                    Text(verbatim: amountText(line)).font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
        case .unknown:
            ReleaseBadge(text: String(localized: "Unknown"), symbol: "questionmark.circle", color: .gray)
        }
    }

    private func amountText(_ plain: String) -> String {
        switch figure.completeness {
        case .complete: plain
        case .atLeast: String(localized: "At least \(plain)")
        case .partial: String(localized: "\(plain) (incomplete)")
        }
    }
}

/// One figure with its source and read time, its caveat, or its Unknown reason.
private struct MoneyFigureRow: View {
    let figure: MoneyFigure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: figure.id.title).font(.headline)
                if figure.isForecast {
                    ReleaseBadge(text: String(localized: "Forecast"), symbol: "chart.line.uptrend.xyaxis", color: .blue)
                }
                if figure.isKnown, !figure.source.isProduction, let env = figure.source.environment {
                    ReleaseBadge(text: env, symbol: "theatermasks", color: .blue)
                }
                Spacer(minLength: 8)
                if let count = countText { Text(verbatim: count).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            MoneyAmountsText(figure: figure)
            if let reason = figure.unknownReason {
                Text(verbatim: reason.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let caveat = figure.completeness.caveat, figure.isKnown {
                Label { Text(verbatim: caveat) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .font(.caption)
            }
            MoneySourceLine(source: figure.source)
        }
        .accessibilityElement(children: .combine)
    }

    private var countText: String? {
        let n: Int
        switch figure.value {
        case .known(let t): n = t.count
        case .knownByCycle(let cycles): n = cycles.values.reduce(0) { $0 + $1.count }
        case .unknown: return nil
        }
        return switch figure.id {
        case .worktrackHesabPayReceived: String(localized: "\(n) payments")
        case .worktrackRenewalsExpected: String(localized: "\(n) renewals")
        case .safeBeautyOwedToSalons, .safeBeautyOwedBySalons: String(localized: "\(n) salons")
        case .accountCosts: String(localized: "\(n) accounts")
        default: String(localized: "\(n) invoices")
        }
    }
}

/// "WorkTrack · GET /v1/vendor/revenue (earned) · production · read …", or where it would be read from.
private struct MoneySourceLine: View {
    let source: MoneySource

    var body: some View {
        let place = [source.system, source.reference, source.environment].compactMap { $0 }.joined(separator: " · ")
        Group {
            if let at = source.readAt {
                Text("\(place) · read \(at.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("\(place) · never read")
            }
        }
        .font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
    }
}

private struct MoneySection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct MoneyBreakdown: View {
    let title: String
    let rows: [(String, String, Int)]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent {
                        Text(verbatim: "\(row.1) · \(row.2)").monospacedDigit()
                    } label: {
                        Text(verbatim: row.0).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

private struct MoneyInvoiceList: View {
    let title: String
    let rows: [MoneyInvoiceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: r.accountName ?? String(localized: "Account not in the list read")).fontWeight(.medium)
                        Text(verbatim: [r.number, r.paidAt ?? r.dueAt ?? r.issuedAt].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if let days = r.daysPastDue {
                        ReleaseBadge(text: String(localized: "Overdue"), symbol: "exclamationmark.circle.fill", color: .red)
                        Text("\(days) days").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(verbatim: MoneyFormat.text(r.amount)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct MoneyNote: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    init(_ text: String, symbol: String = "info.circle", tint: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.caption).foregroundStyle(.secondary)
    }
}
