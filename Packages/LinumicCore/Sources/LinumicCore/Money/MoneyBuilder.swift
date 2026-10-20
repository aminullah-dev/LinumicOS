import Foundation

// MARK: - Building Money
//
// Pure and deterministic: the same input and time give the same report. Rules:
// - Three kinds of WorkTrack money are kept apart and never added: HesabPay settled (earned), renewals expected (a
//   forecast) and CRM invoices typed by hand. WorkTrack's own console does the same (web/src/pages/vendor/Revenue.tsx).
// - TEST and DUPLICATE companies are left out: by the server for HesabPay and renewals, here for CRM invoices (an
//   invoice links to a company only through its CRM account). Without a current company list, or without the
//   accounts, invoices are Unknown, never counted unfiltered.
// - Salons owed and salons owing are two figures, never netted. Costs are per currency and per billing cycle, never
//   converted, never summed across cycles, never turned into a yearly figure.
// - Every day rule uses Kabul's Gregorian date (`WorkTrackDates`), as the server and its console do.

/// One CRM invoice as the Money page lists it. In memory only.
public struct MoneyInvoiceRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var number: String
    /// The CRM account's name; nil when the account was not in the list read.
    public var accountName: String?
    public var amount: MoneyAmount
    public var status: WTInvoiceStatus
    public var issuedAt: String
    public var dueAt: String?
    public var paidAt: String?
    public var method: String?
    /// Whole days since the due day, by Kabul's date; nil when not past due.
    public var daysPastDue: Int?
}

/// An account with a cost recorded from its bill.
public struct MoneyCostRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var vendor: String
    public var cost: AccountCost
    /// The day the cost (or the account with it) was recorded.
    public var recordedOn: KeyDay?
}

/// Invoices paid by hand, by how they were paid.
public struct MoneyMethodTotal: Equatable, Sendable, Identifiable {
    /// BANK, CASH, HAWALA or OTHER as recorded, or "" when no method was recorded.
    public var method: String
    public var totals: MoneyTotals
    public var id: String { method }
}

/// Counts shown as notes beside the figures. Each is nil while its part was not read, so an unread part never reads
/// as "0 drafts" or "0 licences in grace".
public struct MoneyCounts: Equatable, Sendable {
    /// Invoices of a CRM account not linked to a WorkTrack company: counted.
    public var invoicesNotLinked: Int?
    /// Invoices naming a CRM account that was not in the list read: counted, and the figures marked incomplete.
    public var invoicesAccountMissing: Int?
    /// Invoices whose account names a company that is not in the company list (deleted, purged, or past the list's
    /// limit): left out, and the figures marked incomplete, since whether it was a TEST company is unknown.
    public var invoicesCompanyMissing: Int?
    /// A status outside DRAFT, SENT, PAID and VOID.
    public var invoicesUnknownStatus: Int?
    /// Invoice documents that could not be decoded.
    public var invoicesSkipped: Int?
    public var sentWithoutDueDate: Int?
    public var drafts: Int?
    /// Paid licences past their last day but inside WorkTrack's 7 grace days: WorkTrack's forecast leaves them out.
    public var graceLicences: Int?
    public var accountsWithoutCost: Int?
    public var accountsTotal: Int?

    public init() {}
}

public struct MoneyReport: Equatable, Sendable {
    public var builtAt: Date
    /// Kabul's date at `builtAt`, `YYYY-MM-DD`: the day "past due" is counted from.
    public var kabulToday: String
    /// Every `MoneyFigureID` exactly once, in its declared order.
    public var figures: [MoneyFigure]
    /// WorkTrack's revenue answer as read (by Solar Hijri month and plan, the renewals, what the server left out); nil
    /// when it is not known.
    public var revenue: WTRevenue?
    public var paidByMethod: [MoneyMethodTotal] = []
    /// SENT invoices, past due first, then by due day (or issue day).
    public var openInvoices: [MoneyInvoiceRow] = []
    /// PAID invoices, newest first, at most `MoneyBuilder.recentPaidCount`.
    public var recentPaid: [MoneyInvoiceRow] = []
    /// SENT invoices not past due (the outstanding ones less the overdue ones, counted directly); nil when unknown.
    public var notYetDue: MoneyTotals?
    /// PAID or SENT invoices of TEST or DUPLICATE companies, left out; nil when the invoices are unknown.
    public var invoiceExclusions: MoneyTotals?
    public var costs: [MoneyCostRow] = []
    /// Names of the accounts (vendors, not customers) with no recorded cost.
    public var accountsWithoutCost: [String] = []
    public var counts = MoneyCounts()
    /// Each WorkTrack limit that was reached (the server does not say when it stops), as a sentence without counts of
    /// its own, so the Desk item it becomes keeps its id and fact between readings.
    public var limitsReached: [String] = []

    /// `MoneyBuilder.build` puts every figure in, so this always finds one.
    public func figure(_ id: MoneyFigureID) -> MoneyFigure { figures.first { $0.id == id }! }
}

public enum MoneyBuilder {
    /// The server's own limits, none of which it reports: paid orders and companies read for `/revenue`
    /// (`services/vendor.ts:498-499`; the company list has the same 500, `:201`) and every CRM list (`crm.ts:204`).
    public static let revenueOrderLimit = 5000
    public static let revenueCompanyLimit = 500
    public static let crmListLimit = 2000
    public static let recentPaidCount = 10

    static let worktrack = "WorkTrack"
    static let safeBeauty = "SafeBeauty"

    public static func build(_ input: MoneyInput, now: Date) -> MoneyReport {
        let today = WorkTrackDates.kabulToday(now)
        var report = MoneyReport(builtAt: now, kabulToday: today, figures: [])
        var figures: [MoneyFigureID: MoneyFigure] = [:]
        for f in revenueFigures(input.worktrack, report: &report) + invoiceFigures(input.worktrack, today: today, report: &report)
            + balanceFigures(input.safeBeauty) + [costFigure(input.costs, report: &report)] + storeFigures() {
            figures[f.id] = f
        }
        report.figures = MoneyFigureID.allCases.compactMap { figures[$0] }
        let w = input.worktrack
        if w.companiesKnown {
            report.counts.graceLicences = w.companies.count { !$0.isFlagged && !$0.isTrial && $0.standing == .grace }
        }
        return report
    }

    // MARK: WorkTrack

    /// Why a WorkTrack part is unknown, or nil when it was read. A failed company list makes every part unknown: the
    /// model clears what it read before, and nothing older is shown as current.
    static func worktrackUnknown<T>(_ w: MoneyWorkTrackInput, _ part: MoneyRead<T>?, name: String) -> MoneyUnknownReason? {
        guard w.isSignedIn else { return .notSignedIn(product: worktrack) }
        if let error = w.loadError { return .readFailed(part: worktrack, message: error) }
        guard let part else { return .notReadYet(product: worktrack) }
        if let failure = part.failure { return .readFailed(part: name, message: failure) }
        return nil
    }

    static func revenueFigures(_ w: MoneyWorkTrackInput, report: inout MoneyReport) -> [MoneyFigure] {
        let read = w.money?.revenue
        let earnedSource = MoneySource(system: worktrack, reference: "GET /v1/vendor/revenue (earned)", environment: w.environment, readAt: read?.at)
        let expectedSource = MoneySource(system: worktrack, reference: "GET /v1/vendor/revenue (expected)", environment: w.environment, readAt: read?.at)
        func unknown(_ reason: MoneyUnknownReason) -> [MoneyFigure] {
            [MoneyFigure(id: .worktrackHesabPayReceived, value: .unknown(reason), source: earnedSource),
             MoneyFigure(id: .worktrackRenewalsExpected, value: .unknown(reason), source: expectedSource, isForecast: true)]
        }
        if let reason = worktrackUnknown(w, read, name: L("WorkTrack revenue")) { return unknown(reason) }
        guard let revenue = read?.value else { return unknown(.notReadYet(product: worktrack)) }
        guard let code = CurrencyCode(rawValue: revenue.currency) else { return unknown(.unexpectedCurrency(revenue.currency)) }
        report.revenue = revenue
        var earned = MoneyCompleteness.complete
        var expected = MoneyCompleteness.complete
        if revenue.earned.orderCount + revenue.excluded.orderCount >= revenueOrderLimit {
            let limit = LF("WorkTrack reads at most %ld paid orders and this many were read, so revenue may be short.", revenueOrderLimit)
            earned = earned.adding(.atLeast(limit))
            expected = expected.adding(.partial(L("The renewal terms come from the paid orders WorkTrack read, which stopped at its limit.")))
            report.limitsReached.append(limit)
        }
        // Past the company limit the server neither leaves out a TEST company's orders nor forecasts its renewals: the
        // earned total may be wrong either way, the forecast only short.
        if w.companiesKnown, w.companies.count >= revenueCompanyLimit {
            let limit = LF("WorkTrack reads at most %ld companies; a TEST company past that limit is not left out, so revenue may be wrong either way.", revenueCompanyLimit)
            earned = earned.adding(.partial(limit))
            expected = expected.adding(.atLeast(LF("WorkTrack reads at most %ld companies, so renewals of companies past that limit are missing.", revenueCompanyLimit)))
            report.limitsReached.append(limit)
        }
        return [
            MoneyFigure(id: .worktrackHesabPayReceived,
                        value: .known(MoneyTotals(MoneyAmount(MoneyAmount.decimal(revenue.earned.totalAfn), code), count: revenue.earned.orderCount)),
                        source: earnedSource, completeness: earned),
            MoneyFigure(id: .worktrackRenewalsExpected,
                        value: .known(MoneyTotals(MoneyAmount(MoneyAmount.decimal(revenue.expected.totalAfn), code), count: revenue.expected.renewals.count)),
                        source: expectedSource, completeness: expected, isForecast: true),
        ]
    }

    /// Paid by hand, outstanding and past due, from the CRM invoices, with TEST and DUPLICATE companies left out.
    static func invoiceFigures(_ w: MoneyWorkTrackInput, today: String, report: inout MoneyReport) -> [MoneyFigure] {
        let invoicesRead = w.money?.invoices
        let accountsRead = w.money?.accounts
        let source = MoneySource(system: worktrack, reference: "GET /v1/vendor/crm/invoices, /v1/vendor/crm/accounts, /v1/vendor/companies",
                                 environment: w.environment, readAt: invoicesRead?.at)
        let ids: [MoneyFigureID] = [.worktrackInvoicesPaid, .worktrackInvoicesOutstanding, .worktrackInvoicesOverdue]
        func unknown(_ reason: MoneyUnknownReason) -> [MoneyFigure] { ids.map { MoneyFigure(id: $0, value: .unknown(reason), source: source) } }

        if let reason = worktrackUnknown(w, invoicesRead, name: L("WorkTrack invoices")) { return unknown(reason) }
        guard let invoices = invoicesRead?.value else { return unknown(.notReadYet(product: worktrack)) }
        guard w.companiesKnown else {
            return unknown(.dependencyFailed(L("The WorkTrack company list was not read, so TEST companies can't be left out of invoices.")))
        }
        if let failure = accountsRead?.failure {
            return unknown(.dependencyFailed(LF("WorkTrack CRM accounts could not be read (%@), so TEST companies can't be left out of invoices.", failure)))
        }
        guard let accounts = accountsRead?.value else {
            return unknown(.dependencyFailed(L("WorkTrack CRM accounts were not read, so TEST companies can't be left out of invoices.")))
        }

        let accountsByID = Dictionary(accounts.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let companiesByID = Dictionary(w.companies.map { ($0.companyId, $0) }, uniquingKeysWith: { first, _ in first })
        var paid = MoneyTotals(zeroIn: .afn), outstanding = MoneyTotals(zeroIn: .afn), overdue = MoneyTotals(zeroIn: .afn)
        var notYetDue = MoneyTotals(zeroIn: .afn), excluded = MoneyTotals(zeroIn: .afn)
        var byMethod: [String: MoneyTotals] = [:]
        var completeness: [MoneyFigureID: MoneyCompleteness] = [:]
        func caveat(_ figures: [MoneyFigureID], _ c: MoneyCompleteness) {
            for f in figures { completeness[f] = (completeness[f] ?? .complete).adding(c) }
        }
        var notLinked = 0, accountMissing = 0, companyMissing = 0, unknownStatus = 0, withoutDue = 0, drafts = 0
        var accountMissingFigures: Set<MoneyFigureID> = [], companyMissingFigures: Set<MoneyFigureID> = []
        var open: [MoneyInvoiceRow] = [], paidRows: [MoneyInvoiceRow] = []

        for inv in invoices.rows {
            let amount = MoneyAmount(inv.amountAfn, .afn)
            let dueValid = inv.dueAt.map(WorkTrackDates.isValid) == true
            let isOverdue = inv.status == .sent && dueValid && inv.dueAt! < today
            // The figures this invoice would count in.
            let counts: [MoneyFigureID] = switch inv.status {
            case .paid: [.worktrackInvoicesPaid]
            case .sent: isOverdue ? [.worktrackInvoicesOutstanding, .worktrackInvoicesOverdue] : [.worktrackInvoicesOutstanding]
            default: []
            }
            let account = accountsByID[inv.accountId]
            if let account {
                if let companyID = account.companyId {
                    guard let company = companiesByID[companyID] else {
                        // Gone (deleted, or a purged TEST company: its CRM records survive), or past the list's limit.
                        // Whether it was a TEST company is unknown, so it is not counted.
                        if !counts.isEmpty { companyMissing += 1; companyMissingFigures.formUnion(counts) }
                        continue
                    }
                    // The server's own rule: any mark (TEST, DUPLICATE, or a kind added later) leaves the company out.
                    if company.flags != nil {
                        if !counts.isEmpty { excluded.add(amount) }
                        continue
                    }
                } else if !counts.isEmpty {
                    notLinked += 1
                }
            } else if !counts.isEmpty {
                accountMissing += 1
                accountMissingFigures.formUnion(counts)
            }
            let row = MoneyInvoiceRow(id: inv.id, number: inv.number, accountName: account?.name, amount: amount, status: inv.status,
                                      issuedAt: inv.issuedAt, dueAt: inv.dueAt, paidAt: inv.paidAt, method: inv.method,
                                      daysPastDue: isOverdue ? WorkTrackDates.daysBetween(inv.dueAt!, today) : nil)
            switch inv.status {
            case .paid:
                paid.add(amount)
                byMethod[inv.method ?? "", default: MoneyTotals(zeroIn: .afn)].add(amount)
                paidRows.append(row)
            case .sent:
                outstanding.add(amount)
                if isOverdue { overdue.add(amount) } else { notYetDue.add(amount) }
                if !dueValid { withoutDue += 1 }
                open.append(row)
            case .draft:
                drafts += 1
            case .void:
                break
            default:
                unknownStatus += 1
            }
        }

        if accountMissing > 0 {
            caveat(Array(accountMissingFigures), .partial(LF("%ld invoices name a CRM account that was not in the list read; they are counted, and whether one is a TEST company's is unknown.", accountMissing)))
        }
        if companyMissing > 0 {
            caveat(Array(companyMissingFigures), .partial(LF("%ld invoices belong to a WorkTrack company that is not in the company list (deleted, or past its limit); they are left out.", companyMissing)))
        }
        if unknownStatus > 0 {
            caveat(ids, .partial(LF("%ld invoices have a status WorkTrack does not define; they are not counted.", unknownStatus)))
        }
        if invoices.skipped > 0 {
            caveat(ids, .partial(LF("%ld invoices could not be read; they are not counted.", invoices.skipped)))
        }
        if invoices.rows.count + invoices.skipped >= crmListLimit {
            let limit = LF("WorkTrack returned %ld invoices, the most it sends, so invoice totals may be short.", crmListLimit)
            caveat(ids, .atLeast(limit))
            report.limitsReached.append(limit)
        }
        if accounts.rows.count + accounts.skipped >= crmListLimit {
            let limit = LF("WorkTrack returned %ld CRM accounts, the most it sends; invoices of accounts past that limit are counted unfiltered.", crmListLimit)
            caveat(ids, .partial(limit))
            report.limitsReached.append(limit)
        }

        report.paidByMethod = byMethod.keys.sorted { a, b in
            // Recorded methods first in WorkTrack's order, then none.
            let order = ["BANK", "CASH", "HAWALA", "OTHER"]
            return (order.firstIndex(of: a) ?? (a.isEmpty ? 99 : 98), a) < (order.firstIndex(of: b) ?? (b.isEmpty ? 99 : 98), b)
        }.map { MoneyMethodTotal(method: $0, totals: byMethod[$0]!) }
        report.openInvoices = open.sorted { a, b in
            if (a.daysPastDue != nil) != (b.daysPastDue != nil) { return a.daysPastDue != nil }
            return (a.dueAt ?? a.issuedAt, a.number) < (b.dueAt ?? b.issuedAt, b.number)
        }
        report.recentPaid = Array(paidRows.sorted { ($0.paidAt ?? $0.issuedAt, $0.number) > ($1.paidAt ?? $1.issuedAt, $1.number) }.prefix(recentPaidCount))
        report.notYetDue = notYetDue
        report.invoiceExclusions = excluded
        report.counts.invoicesNotLinked = notLinked
        report.counts.invoicesAccountMissing = accountMissing
        report.counts.invoicesCompanyMissing = companyMissing
        report.counts.invoicesUnknownStatus = unknownStatus
        report.counts.invoicesSkipped = invoices.skipped
        report.counts.sentWithoutDueDate = withoutDue
        report.counts.drafts = drafts

        return [
            MoneyFigure(id: .worktrackInvoicesPaid, value: .known(paid), source: source, completeness: completeness[.worktrackInvoicesPaid] ?? .complete),
            MoneyFigure(id: .worktrackInvoicesOutstanding, value: .known(outstanding), source: source,
                        completeness: completeness[.worktrackInvoicesOutstanding] ?? .complete),
            MoneyFigure(id: .worktrackInvoicesOverdue, value: .known(overdue), source: source,
                        completeness: completeness[.worktrackInvoicesOverdue] ?? .complete),
        ]
    }

    // MARK: SafeBeauty

    static func balanceFigures(_ s: MoneySafeBeautyInput) -> [MoneyFigure] {
        let read = s.balances
        let readAt = read?.value.map { $0.readTime ?? $0.readAt } ?? read?.at
        let owedSource = MoneySource(system: safeBeauty, reference: "Firestore provider_balances: count() and sum(owedAmount) where owedAmount > 0",
                                     environment: s.environment, readAt: readAt)
        let owingSource = MoneySource(system: safeBeauty, reference: "Firestore provider_balances: count() and sum(owedAmount) where owedAmount < 0",
                                      environment: s.environment, readAt: readAt)
        let reason: MoneyUnknownReason? = if !s.isSignedIn { .notSignedIn(product: safeBeauty) }
            else if let read { read.failure.map { .readFailed(part: L("SafeBeauty balances"), message: $0) } }
            else { .notReadYet(product: safeBeauty) }
        guard reason == nil, let totals = read?.value else {
            let r = reason ?? .notReadYet(product: safeBeauty)
            return [MoneyFigure(id: .safeBeautyOwedToSalons, value: .unknown(r), source: owedSource),
                    MoneyFigure(id: .safeBeautyOwedBySalons, value: .unknown(r), source: owingSource)]
        }
        // Whole AFN (SafeBeauty functions/lib/money.js:7). The second is a size: salons owe this much, never subtracted.
        return [MoneyFigure(id: .safeBeautyOwedToSalons, value: .known(MoneyTotals(MoneyAmount(totals.owedToSalons, .afn), count: totals.owedToSalonsCount)),
                            source: owedSource),
                MoneyFigure(id: .safeBeautyOwedBySalons, value: .known(MoneyTotals(MoneyAmount(totals.owedBySalons, .afn), count: totals.owedBySalonsCount)),
                            source: owingSource)]
    }

    // MARK: What we pay

    static func costFigure(_ input: MoneyCostsInput?, report: inout MoneyReport) -> MoneyFigure {
        let source = MoneySource(system: "obligations.json", reference: L("Obligations & accounts: each account's cost, as recorded from its bill"),
                                 readAt: input?.builtAt)
        guard let input else { return MoneyFigure(id: .accountCosts, value: .unknown(.registerNotBuilt), source: source) }
        // Without the owner's file only the seed is there, and seed accounts carry no cost: unknown, not "none".
        if let error = input.loadError { return MoneyFigure(id: .accountCosts, value: .unknown(.obligationsUnreadable(error)), source: source) }
        var byCycle: [BillingCycle: MoneyTotals] = [:]
        var rows: [MoneyCostRow] = []
        var without: [String] = []
        for a in input.accounts {
            guard let cost = a.cost, let code = CurrencyCode(rawValue: cost.currency) else {
                without.append(a.name)
                continue
            }
            byCycle[cost.cycle, default: MoneyTotals()].add(MoneyAmount(cost.amount, code))
            rows.append(MoneyCostRow(id: a.id, vendor: a.name, cost: cost, recordedOn: a.costRecordedOn ?? a.recordedOn))
        }
        report.costs = rows.sorted { ($0.cost.currency, $0.cost.cycle.rawValue, $0.vendor) < ($1.cost.currency, $1.cost.cycle.rawValue, $1.vendor) }
        report.accountsWithoutCost = without
        report.counts.accountsWithoutCost = without.count
        report.counts.accountsTotal = input.accounts.count
        guard !rows.isEmpty else {
            return MoneyFigure(id: .accountCosts, value: .unknown(.noCostRecorded(accounts: input.accounts.count)), source: source)
        }
        let completeness: MoneyCompleteness = without.isEmpty ? .complete
            : .partial(LF("%1$ld of %2$ld accounts have no recorded cost, so what we pay is incomplete.", without.count, input.accounts.count))
        return MoneyFigure(id: .accountCosts, value: .knownByCycle(byCycle), source: source, completeness: completeness)
    }

    // MARK: Stores

    /// Always Unknown in v1: no finance key is on this device, and new finance keys are out of scope (roadmap §5).
    static func storeFigures() -> [MoneyFigure] {
        [MoneyFigure(id: .appStoreProceeds, value: .unknown(.noFinanceKey(store: "App Store")),
                     source: MoneySource(system: "App Store Connect", reference: L("Sales and finance reports (no finance key)"))),
         MoneyFigure(id: .googlePlayProceeds, value: .unknown(.noFinanceKey(store: "Google Play")),
                     source: MoneySource(system: "Google Play Console", reference: L("Financial reports (no finance key)")))]
    }
}
