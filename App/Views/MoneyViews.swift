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
    @State private var isReading = false

    var body: some View {
        let input = MoneyInput.collect(worktrack: worktrack, safeBeauty: operations.safeBeauty, obligations: obligations)
        MoneyPage(input: input, report: MoneyBuilder.build(input, now: .now), isReading: isReading, readNow: readNow)
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
}

/// The page itself, from a report and the input it was built from: no model, so a preview can show it.
struct MoneyPage: View {
    let input: MoneyInput
    let report: MoneyReport
    var isReading = false
    var readNow: () async -> Void = {}

    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                summary
                received
                onTheWay
                salons
                wePay
                stores
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

    // MARK: Header and summary

    private var header: some View {
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

    /// One row of four on a wide pane (about 900 pt and up: four cards of at least 206 pt and the page's padding), two
    /// by two below that. The cards of a row share its height.
    private var summary: some View {
        let received = MoneySummaryCard(question: .received, symbol: "arrow.down.circle", tint: .green,
                                        figures: [(report.figure(.worktrackHesabPayReceived), String(localized: "HesabPay")),
                                                  (report.figure(.worktrackInvoicesPaid), String(localized: "By hand"))])
        let onTheWay = MoneySummaryCard(question: .onTheWay, symbol: "clock.arrow.circlepath", tint: .blue,
                                        figures: [(report.figure(.worktrackRenewalsExpected), String(localized: "Renewals (forecast)")),
                                                  (report.figure(.worktrackInvoicesOutstanding), String(localized: "Invoices sent"))])
        let salons = MoneySummaryCard(question: .owedToSalons, symbol: "building.2", tint: .orange,
                                      figures: [(report.figure(.safeBeautyOwedToSalons), String(localized: "We owe")),
                                                (report.figure(.safeBeautyOwedBySalons), String(localized: "They owe us"))])
        let wePay = MoneySummaryCard(question: .wePay, symbol: "creditcard", tint: .purple,
                                     figures: [(report.figure(.accountCosts), String(localized: "As each bill says"))])
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array([received, onTheWay, salons, wePay].enumerated()), id: \.offset) { _, card in
                    card.frame(minWidth: 206, idealWidth: 206, maxWidth: .infinity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { received; onTheWay }
                GridRow { salons; wePay }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sections

    private var received: some View {
        MoneySection(title: MoneyQuestion.received.title, symbol: "arrow.down.circle") {
            MoneyFigureRow(figure: report.figure(.worktrackHesabPayReceived))
            // The breakdowns in the currency WorkTrack named for the whole answer, like the figure above them.
            if let revenue = report.revenue, let code = report.revenueCurrency {
                MoneyBreakdown(title: String(localized: "By Solar Hijri month (Kabul)"),
                               rows: revenue.earned.byMonth.prefix(6).map { m in
                                   MoneyBreakdownRow(label: Self.solarHijriMonth(year: m.year, month: m.month),
                                                     amount: MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(m.totalAfn), code)),
                                                     count: String(localized: "\(m.orderCount) orders"))
                               })
                MoneyBreakdown(title: String(localized: "By plan"),
                               rows: revenue.earned.byPlan.map {
                                   MoneyBreakdownRow(label: $0.plan, amount: MoneyFormat.text(MoneyAmount(MoneyAmount.decimal($0.totalAfn), code)),
                                                     count: String(localized: "\($0.orderCount) orders"))
                               })
                if revenue.excluded.companyCount > 0 {
                    let amount = MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(revenue.excluded.amountAfn), code))
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
                               rows: report.paidByMethod.map {
                                   MoneyBreakdownRow(label: methodTitle($0.method), amount: MoneyFormat.text($0.totals),
                                                     count: String(localized: "\($0.totals.count) invoices"))
                               })
            }
            if !report.recentPaid.isEmpty {
                MoneyInvoiceList(title: String(localized: "Paid most recently"), rows: report.recentPaid)
            }
        }
    }

    private var onTheWay: some View {
        MoneySection(title: MoneyQuestion.onTheWay.title, symbol: "clock.arrow.circlepath") {
            MoneyFigureRow(figure: report.figure(.worktrackRenewalsExpected))
            if let revenue = report.revenue, let code = report.revenueCurrency {
                Text("Forecast at today's prices, not money received: renewals of the next \(revenue.expected.windowDays) days, as WorkTrack counts them.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(revenue.expected.renewals.enumerated()), id: \.offset) { _, r in
                    let expires = String(localized: "Expires \(workTrackDay(r.expiresAt))")
                    Button {
                        router.go(.worktrackCustomers, request: .worktrackCompany(r.companyId))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: r.name).fontWeight(.medium)
                                Text(verbatim: "\(isolated(r.plan)) · \(isolated(r.term)) · \(expires)").font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: Self.basisText(r.basis)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(r.amountAfn), code))).monospacedDigit().fixedSize()
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
            invoiceNotes
            if let console = WorkTrackEnvironment(rawValue: input.worktrack.environment ?? "")?.console {
                Link(destination: console) { Label("Open WorkTrack console", systemImage: "arrow.up.forward.app") }
                    .help(Text(verbatim: console.absoluteString))
            }
        }
    }

    @ViewBuilder
    private var invoiceNotes: some View {
        let c = report.counts
        // Paid and sent are different questions (received, on the way): two notes, never one sum.
        if let e = report.excludedPaid, e.count > 0 {
            MoneyNote(String(localized: "Left out: \(e.count) paid invoices of TEST or DUPLICATE companies (\(MoneyFormat.text(e)))."))
        }
        if let e = report.excludedSent, e.count > 0 {
            MoneyNote(String(localized: "Left out: \(e.count) sent invoices of TEST or DUPLICATE companies (\(MoneyFormat.text(e)))."))
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

    private var salons: some View {
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

    private var wePay: some View {
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
                            Text("Recorded \(day.start().formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let without = report.counts.accountsWithoutCost, let total = report.counts.accountsTotal, without > 0 {
                MoneyNote(String(localized: "\(without) of \(total) accounts have no recorded cost: \(report.accountsWithoutCost.formatted(.list(type: .and)))."))
            }
            Button { router.go(.obligations) } label: { Label("Open Obligations & accounts", systemImage: "calendar.badge.exclamationmark") }
        }
    }

    private var stores: some View {
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

    /// WorkTrack's month is Solar Hijri in Kabul whatever this device's calendar is, so it is named in that calendar.
    static func solarHijriMonth(year: Int, month: Int) -> String {
        var calendar = Calendar(identifier: .persian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kabul") ?? .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) else { return "\(year)/\(month)" }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).year().month(.wide))
    }

    /// Where WorkTrack took a renewal's term from, in its console's words (`vendorInsights.ts`, `strings.ts`).
    static func basisText(_ basis: String) -> String {
        switch basis {
        case "LAST_PAID_TERM": String(localized: "last term paid")
        case "MONTHLY_PRICE": String(localized: "one month (never paid online)")
        default: basis
        }
    }
}

// MARK: - Parts

/// A code or number in Latin script ("INV-103", "SILVER") set apart for the bidi algorithm, so a Dari line that starts
/// with one still reads right to left (a first strong letter inside an isolate does not set the line's direction).
private func isolated(_ text: String) -> String {
    text.isEmpty ? text : "\u{2068}\(text)\u{2069}"
}

/// A soft frosted card with one question's figures, each in its own currency, never added together. An Unknown shows
/// its reason under the pill.
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
                    if let reason = figure.unknownReason {
                        Text(verbatim: reason.text).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            .help(Text(verbatim: reason.text))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
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
                        .lineLimit(1).minimumScaleFactor(0.6)
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
            MoneySourceLine(source: figure.source, isKnown: figure.isKnown)
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

/// "WorkTrack · GET /v1/vendor/revenue (earned) · production · read …", or where it would be read from. An Unknown
/// figure's time is when a read was tried, not a read: it says "tried".
private struct MoneySourceLine: View {
    let source: MoneySource
    let isKnown: Bool

    var body: some View {
        let place = [source.system, source.reference, source.environment].compactMap { $0 }.joined(separator: " · ")
        Group {
            if let at = source.readAt {
                let time = at.formatted(date: .abbreviated, time: .shortened)
                if isKnown { Text("\(place) · read \(time)") } else { Text("\(place) · tried \(time)") }
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

/// One line of a breakdown: what (a month, a plan, a method), the amount, and what was counted ("3 orders").
private struct MoneyBreakdownRow {
    let label: String
    let amount: String
    let count: String
}

private struct MoneyBreakdown: View {
    let title: String
    let rows: [MoneyBreakdownRow]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: row.amount).monospacedDigit()
                            Text(verbatim: row.count).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } label: {
                        Text(verbatim: row.label).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
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
                        Text(verbatim: ([isolated(r.number)] + [Self.dateText(r)].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        // Under the name, not beside the amount: on iPhone the name keeps the row's width.
                        if let days = r.daysPastDue {
                            HStack(spacing: 6) {
                                ReleaseBadge(text: String(localized: "Overdue"), symbol: "exclamationmark.circle.fill", color: .red)
                                Text("\(days) days").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: MoneyFormat.text(r.amount)).monospacedDigit().fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The one date that answers the row's question, said for what it is: a paid invoice's payment day, a sent one's
    /// due day, or its issue day when it has no due day. Never one in place of another: a paid invoice without a
    /// payment day shows none.
    static func dateText(_ r: MoneyInvoiceRow) -> String? {
        if r.status == .paid {
            return r.paidAt.map { String(localized: "Paid \(workTrackDay($0))") }
        }
        if let due = r.dueAt, WorkTrackDates.isValid(due) { return String(localized: "Due \(workTrackDay(due))") }
        return r.issuedAt.isEmpty ? nil : String(localized: "Issued \(workTrackDay(r.issuedAt)), no due date")
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

// MARK: - Preview

#if DEBUG
/// Made-up figures (SAMPLE) for the preview: no model, no session, no request.
enum MoneyPreviewData {
    static let now = Date.now
    /// Marks every made-up text; a constant, so the catalog check does not take it for a UI string.
    static let sample = "SAMPLE"

    static var read: MoneyInput {
        let revenue = try? JSONDecoder().decode(WTRevenue.self, from: Data("""
            {"currency": "AFN",
             "earned": {"totalAfn": 42000, "orderCount": 6,
                        "byMonth": [{"year": 1405, "month": 7, "totalAfn": 24500, "orderCount": 3},
                                    {"year": 1405, "month": 6, "totalAfn": 17500, "orderCount": 3}],
                        "byPlan": [{"plan": "SILVER", "totalAfn": 21000, "orderCount": 3}, {"plan": "GOLD", "totalAfn": 21000, "orderCount": 3}]},
             "expected": {"windowDays": 30, "totalAfn": 10500,
                          "renewals": [{"companyId": "sample_1", "name": "SAMPLE Herat Trading", "plan": "SILVER", "expiresAt": "2026-10-29",
                                        "daysUntilExpiry": 10, "term": "QUARTERLY", "months": 3, "amountAfn": 10500, "basis": "LAST_PAID_TERM"}]},
             "excluded": {"companyCount": 1, "orderCount": 2, "amountAfn": 7000}}
            """.utf8))
        let accounts = WTLossyList(rows: [WTCrmAccount(id: "a1", name: "SAMPLE Kabul Clinic"), WTCrmAccount(id: "a2", name: "SAMPLE Mazar Foods")])
        let invoices = WTLossyList(rows: [
            WTCrmInvoice(id: "i1", accountId: "a1", number: "INV-101", status: .paid, amountAfn: 3500, issuedAt: "2026-10-01",
                         dueAt: "2026-10-08", paidAt: "2026-10-07", method: "BANK"),
            WTCrmInvoice(id: "i2", accountId: "a2", number: "INV-102", status: .paid, amountAfn: 2000, issuedAt: "2026-10-03", method: "CASH"),
            WTCrmInvoice(id: "i3", accountId: "a1", number: "INV-103", status: .sent, amountAfn: 3000, issuedAt: "2026-09-20", dueAt: "2026-10-05"),
            WTCrmInvoice(id: "i4", accountId: "a2", number: "INV-104", status: .sent, amountAfn: 1200, issuedAt: "2026-10-15"),
        ])
        let money = WorkTrackMoneyRead(revenue: revenue.map { .read($0, at: now) } ?? .failed("preview data", at: now, needsSignIn: false),
                                       accounts: .read(accounts, at: now), invoices: .read(invoices, at: now))
        let balances = SafeBeautyBalanceTotals(owedToSalonsCount: 3, owedToSalons: 4500, owedBySalonsCount: 1, owedBySalons: 300,
                                               readTime: now, readAt: now)
        let costs = [
            VendorAccount(id: "apple", name: "Apple Developer", purpose: sample, cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "\(sample) bill"),
                          source: sample, recordedOn: KeyDay(now), origin: .owner),
            VendorAccount(id: "host", name: "SAMPLE Hosting", purpose: sample, cost: AccountCost(amount: 10, currency: "CAD", cycle: .monthly, source: "\(sample) bill"),
                          source: sample, recordedOn: KeyDay(now), origin: .owner),
            VendorAccount(id: "github", name: "GitHub", purpose: sample, source: sample, recordedOn: nil, origin: .owner),
        ]
        return MoneyInput(worktrack: MoneyWorkTrackInput(isSignedIn: true, environment: "production", companiesReadAt: now, money: money),
                          safeBeauty: MoneySafeBeautyInput(isSignedIn: true, environment: "production", balances: .read(balances, at: now)),
                          costs: MoneyCostsInput(accounts: costs, builtAt: now))
    }

    /// WorkTrack's revenue read failed, SafeBeauty is signed out, obligations.json could not be read.
    static var unknown: MoneyInput {
        var input = read
        input.worktrack.money?.revenue = .failed("HTTP 500", at: now, needsSignIn: false)
        input.safeBeauty = MoneySafeBeautyInput(isSignedIn: false, environment: nil)
        input.costs?.loadError = "The data couldn't be read because it isn't in the correct format."
        return input
    }
}

#Preview("Money, read") {
    NavigationStack {
        MoneyPage(input: MoneyPreviewData.read, report: MoneyBuilder.build(MoneyPreviewData.read, now: MoneyPreviewData.now))
    }
    .environment(Router())
}

#Preview("Money, Unknown") {
    NavigationStack {
        MoneyPage(input: MoneyPreviewData.unknown, report: MoneyBuilder.build(MoneyPreviewData.unknown, now: MoneyPreviewData.now))
    }
    .environment(Router())
}
#endif
