import Foundation

// MARK: - Money in the Daily Brief (and so on the Desk)
//
// Lines are what waits on the owner: salons to pay, invoices past due or unpaid. Their text holds counts only; amounts
// are in the detail, so the morning notification (which prints line texts) never shows one. Line ids are fixed strings
// (`money.…`) that never carry a company, salon, account or invoice id. Every figure that is Unknown becomes a gap, and
// so one Desk item, with its reason; a section that could not be read still names the parts that are unknown whatever
// happens (store proceeds, costs).

extension DailyBriefBuilder {
    static func money(_ input: BriefInput) -> BriefSection {
        MoneyBrief.section(input.money, now: input.now)
    }
}

public enum MoneyBrief {
    public static var source: String { L("Money: WorkTrack vendor API, SafeBeauty Firestore and obligations.json (read-only)") }

    /// Gap keys of the parts a Money line is read from: while one of them is a gap, a mark on a line that is gone is
    /// kept (the line may only be unread, not gone).
    public static func readGapKeys(forLineID id: String) -> Set<String>? {
        if id.hasPrefix("money.worktrack.") { return ["worktrack", "worktrack.invoices"] }
        if id.hasPrefix("money.safebeauty.") { return ["safebeauty", "safebeauty.balances"] }
        return nil
    }

    /// Where a product's money stands, for the section's state.
    enum PartState: Equatable {
        case read, notSignedIn, notRead
        case failed(String)
    }

    public static func section(_ money: MoneyInput?, now: Date) -> BriefSection {
        guard let money else {
            // Not collected on this device; store proceeds and costs are still unknown, each with its own item.
            let gaps = [storesGap, BriefGap(key: "costs", text: MoneyUnknownReason.registerNotBuilt.text)]
            return BriefSection(kind: .money, state: .neverRead(L("Money has not been collected on this device yet.")), readAt: nil,
                                source: source, gaps: gaps)
        }
        let report = MoneyBuilder.build(money, now: now)
        let all = gaps(report, input: money)
        let wt = state(report, [.worktrackHesabPayReceived, .worktrackInvoicesPaid])
        let sb = state(report, [.safeBeautyOwedToSalons])
        guard wt == .read || sb == .read else {
            // Nothing remote was read. The section's own item says why; the part gaps it covers are left out, so one
            // reason is one item.
            func without(_ prefixes: [String]) -> [BriefGap] { all.filter { g in !prefixes.contains { g.key.hasPrefix($0) } } }
            let failures = [wt, sb].compactMap { if case .failed(let m) = $0 { m } else { nil } }
            if !failures.isEmpty {
                let covered = [(wt, "worktrack"), (sb, "safebeauty")].compactMap { if case .failed = $0.0 { $0.1 } else { nil } }
                return BriefSection(kind: .money, state: .unavailable(failures.joined(separator: " ")), readAt: nil, source: source,
                                    gaps: without(covered))
            }
            if wt == .notSignedIn, sb == .notSignedIn {
                return BriefSection(kind: .money, state: .neverRead(L("Not signed in to WorkTrack or SafeBeauty, so revenue and what salons are owed are unknown.")),
                                    readAt: nil, source: source, gaps: without(["worktrack", "safebeauty"]))
            }
            if wt == .notRead, sb == .notRead {
                return BriefSection(kind: .money, state: .neverRead(L("Signed in, but money has not been read yet.")),
                                    readAt: nil, source: source, gaps: without(["worktrack", "safebeauty"]))
            }
            return BriefSection(kind: .money, state: .neverRead(L("Money has not been read yet.")), readAt: nil, source: source, gaps: all)
        }
        let readAt = report.figures.filter { $0.isKnown && $0.id.question != .wePay }.compactMap(\.source.readAt).max()
        let section = DailyBriefBuilder.finish(.money, lines: lines(report, input: money), readAt: readAt, source: source, gaps: all)
        return BriefSection(kind: .money, state: section.state, lines: section.lines, readAt: readAt, source: source,
                            notes: notes(report, input: money), gaps: all)
    }

    static func state(_ report: MoneyReport, _ ids: [MoneyFigureID]) -> PartState {
        let figures = ids.map(report.figure)
        if figures.contains(where: \.isKnown) { return .read }
        let reasons = figures.compactMap(\.unknownReason)
        if reasons.contains(where: { if case .notSignedIn = $0 { true } else { false } }) { return .notSignedIn }
        if reasons.allSatisfy({ if case .notReadYet = $0 { true } else { false } }) { return .notRead }
        var messages: [String] = []
        for r in reasons where !messages.contains(r.text) { messages.append(r.text) }
        return .failed(messages.joined(separator: " "))
    }

    // MARK: Lines

    static func lines(_ report: MoneyReport, input: MoneyInput) -> [BriefLine] {
        var lines: [BriefLine] = []
        let workTrack = MonitorProduct.workTrack.title, safeBeauty = MonitorProduct.safeBeauty.title

        let owed = report.figure(.safeBeautyOwedToSalons)
        if let t = owed.totals, t.count > 0 {
            let admin = owed.source.isProduction ? SafeBeautyEnvironment(rawValue: owed.source.environment ?? "")?.adminPanel : nil
            lines.append(BriefLine(id: "money.safebeauty.owed", kind: .money, severity: owed.source.isProduction ? .normal : .info,
                                   text: LF("SafeBeauty: %ld salons are owed a payout", t.count),
                                   detail: LF("%@ in total, as read. Pay salons in the SafeBeauty admin console; it records the payout.",
                                              MoneyFormat.text(t, owed.completeness)),
                                   source: sourceText(owed), readAt: owed.source.readAt, destination: .money,
                                   links: admin.map { [BriefLink(title: L("Open SafeBeauty admin"), url: $0, symbol: "safari")] } ?? [],
                                   product: safeBeauty, factKey: BriefLine.countBucket(t.count)))
        }
        let owing = report.figure(.safeBeautyOwedBySalons)
        if let t = owing.totals, t.count > 0 {
            lines.append(BriefLine(id: "money.safebeauty.receivable", kind: .money, severity: .info,
                                   text: LF("SafeBeauty: %ld salons owe the platform commission", t.count),
                                   detail: LF("%@ in total. Normal while cash visits are unpaid; a large or growing amount is not.",
                                              MoneyFormat.text(t, owing.completeness)),
                                   source: sourceText(owing), readAt: owing.source.readAt, destination: .money,
                                   product: safeBeauty, factKey: BriefLine.countBucket(t.count)))
        }

        let overdue = report.figure(.worktrackInvoicesOverdue)
        let console = overdue.source.isProduction ? WorkTrackEnvironment(rawValue: overdue.source.environment ?? "")?.console : nil
        let consoleLinks = console.map { [BriefLink(title: L("Open WorkTrack console"), url: $0, symbol: "safari")] } ?? []
        if let t = overdue.totals, t.count > 0 {
            lines.append(BriefLine(id: "money.worktrack.overdue", kind: .money, severity: overdue.source.isProduction ? .normal : .info,
                                   text: LF("WorkTrack: %ld invoices are past due", t.count),
                                   detail: LF("%1$@ in total. Past due: the due date is before today in Kabul (%2$@).",
                                              MoneyFormat.text(t, overdue.completeness), report.kabulToday),
                                   source: sourceText(overdue), readAt: overdue.source.readAt, destination: .money, links: consoleLinks,
                                   product: workTrack, factKey: BriefLine.countBucket(t.count)))
        }
        let outstanding = report.figure(.worktrackInvoicesOutstanding)
        if outstanding.isKnown, let t = report.notYetDue, t.count > 0 {
            lines.append(BriefLine(id: "money.worktrack.unpaid", kind: .money, severity: .info,
                                   text: LF("WorkTrack: %ld invoices sent and not paid yet", t.count),
                                   detail: LF("%@ in total.", MoneyFormat.text(t, outstanding.completeness)),
                                   source: sourceText(outstanding), readAt: outstanding.source.readAt, destination: .money, links: consoleLinks,
                                   product: workTrack, factKey: BriefLine.countBucket(t.count)))
        }
        return lines
    }

    /// "WorkTrack (production): GET /v1/vendor/crm/invoices, …".
    static func sourceText(_ f: MoneyFigure) -> String {
        let env = f.source.environment.map { " (\($0))" } ?? ""
        return "\(f.source.system)\(env): \(f.source.reference)"
    }

    // MARK: Gaps

    /// One gap per Unknown (several figures with the same reason share it), then the caveats only the owner can fix or
    /// accept. Texts carry no times, and counts only where a new count is a new fact, so a dismissal with a reason holds
    /// until the situation changes.
    static func gaps(_ report: MoneyReport, input: MoneyInput) -> [BriefGap] {
        var gaps: [BriefGap] = []
        func add(_ g: BriefGap) { if !gaps.contains(where: { $0.key == g.key }) { gaps.append(g) } }
        let workTrack = MonitorProduct.workTrack.title, safeBeauty = MonitorProduct.safeBeauty.title

        for f in report.figures {
            guard let reason = f.unknownReason else { continue }
            let isSafeBeauty = f.id.product == safeBeauty
            switch reason {
            case .noFinanceKey:
                add(storesGap)
            case _ where f.id == .accountCosts:
                add(BriefGap(key: "costs", text: reason.text))
            case .notSignedIn, .notReadYet:
                // The WorkTrack and Operations sections raise the same sign-in item for their focus product; this copy
                // stays in Later.
                add(BriefGap(key: isSafeBeauty ? "safebeauty" : "worktrack", text: reason.text))
            case .readFailed(let part, _) where part == workTrack:
                // The company list failed: the WorkTrack section already says so in Today.
                add(BriefGap(key: "worktrack", text: reason.text))
            default:
                if isSafeBeauty {
                    add(BriefGap(key: "safebeauty.balances", text: reason.text, product: safeBeauty))
                } else if f.id == .worktrackHesabPayReceived || f.id == .worktrackRenewalsExpected {
                    add(BriefGap(key: "worktrack.revenue", text: reason.text, product: workTrack))
                } else {
                    add(BriefGap(key: "worktrack.invoices", text: reason.text, product: workTrack))
                }
            }
        }

        let costs = report.figure(.accountCosts)
        if case .partial(let why) = costs.completeness { add(BriefGap(key: "costs", text: why)) }

        if let revenue = report.revenue, revenue.excluded.companyCount == 0 {
            add(BriefGap(key: "worktrack.test", text: L("No WorkTrack company is marked TEST or DUPLICATE. If a test company exists, its payments are counted as revenue; mark it in the WorkTrack console, and do not purge one that paid (WorkTrack then counts its orders again)."),
                         product: workTrack))
        }
        if !report.limitsReached.isEmpty {
            add(BriefGap(key: "worktrack.limit", text: report.limitsReached.joined(separator: " "), product: workTrack))
        }
        let wtKnown = [MoneyFigureID.worktrackHesabPayReceived, .worktrackInvoicesPaid].map(report.figure).first(where: \.isKnown)
        if let f = wtKnown, !f.source.isProduction {
            add(BriefGap(key: "worktrack.production", text: LF("Read from the %@ environment, not production.", f.source.environment ?? "?"), product: workTrack))
        }
        let sbKnown = report.figure(.safeBeautyOwedToSalons)
        if sbKnown.isKnown, !sbKnown.source.isProduction {
            add(BriefGap(key: "safebeauty.production", text: LF("Read from the %@ environment, not production.", sbKnown.source.environment ?? "?"), product: safeBeauty))
        }
        // Stores last, whatever else was read.
        if let i = gaps.firstIndex(where: { $0.key == "stores" }) { gaps.append(gaps.remove(at: i)) }
        return gaps
    }

    static var storesGap: BriefGap {
        BriefGap(key: "stores", text: L("App Store and Google Play proceeds are unknown: there is no finance key on this device (new finance keys are out of scope), and neither WorkTrack nor SafeBeauty sells in-app."))
    }

    // MARK: Notes

    /// Information only (never Desk items): what was left out and why a total may not be all of it.
    static func notes(_ report: MoneyReport, input: MoneyInput) -> [String] {
        var notes: [String] = []
        if let revenue = report.revenue {
            if revenue.excluded.companyCount > 0 {
                notes.append(LF("Left out: %lld TEST or DUPLICATE companies (%lld orders, %@).", revenue.excluded.companyCount, revenue.excluded.orderCount,
                                MoneyFormat.text(MoneyAmount(MoneyAmount.decimal(revenue.excluded.amountAfn), CurrencyCode(rawValue: revenue.currency) ?? .afn))))
            }
            notes.append(L("Paid orders of a TEST company that was purged count as earned again: WorkTrack leaves out only companies that still exist. Mark test companies TEST; do not purge one that paid until WorkTrack is fixed."))
            notes.append(L("Pending HesabPay checkouts are not counted: WorkTrack has no route that lists them across companies."))
        }
        if let excluded = report.invoiceExclusions, excluded.count > 0 {
            notes.append(LF("Left out: %lld paid or sent invoices of TEST or DUPLICATE companies (%@).", excluded.count, MoneyFormat.text(excluded)))
        }
        if let n = report.counts.invoicesCompanyMissing, n > 0 {
            notes.append(LF("%lld invoices belong to a WorkTrack company that is not in the company list (deleted, or past its limit); they are left out.", n))
        }
        if let n = report.counts.graceLicences, n > 0 {
            notes.append(LF("%lld licences are in their grace days after expiry; WorkTrack's forecast leaves them out.", n))
        }
        if report.figure(.safeBeautyOwedToSalons).isKnown {
            notes.append(L("SafeBeauty has no TEST mark, so every salon balance is counted."))
        }
        return notes
    }
}
