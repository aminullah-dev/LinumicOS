import Foundation

// MARK: - Sales in the Daily Brief (and so on the Desk)
//
// Lines are who to call: follow-ups due today or overdue (Today), in the next 7 days (This week), a next-action date
// that could not be read, open accounts with no next step, and new or self-serve companies with no CRM account. Their
// day rule is Kabul's, so a line carries a `horizon`, never a `due` the Desk would compare with this device's day.
// Line ids carry a `SalesKey` hash, never a CRM or company id. Renewals, website messages and the KYC queue are Desk
// items of their own sections already; Sales lists them on its page only. A part that was not read is one item in the
// shared group (Later); a limit or the environment, which Money and WorkTrack customers already raise, is a note that
// keeps marks but makes no second item.

extension DailyBriefBuilder {
    static func sales(_ input: BriefInput) -> BriefSection {
        SalesBrief.section(input.money?.worktrack, now: input.now)
    }
}

public enum SalesBrief {
    public static var source: String { L("Sales: WorkTrack CRM accounts and company list (read-only)") }

    static let followUpPrefix = "sales.followup."
    static let signupPrefix = "sales.signup."
    public static let noDateID = "sales.nodate"
    public static let noCRMID = "sales.nocrm"
    static let skippedKey = "worktrack.accounts.skipped"
    static let accountsLimitKey = "worktrack.accounts.limit"
    static let companiesLimitKey = "worktrack.companies.limit"
    static let productionKey = "worktrack.production"

    /// A follow-up due today or overdue, by Kabul's day, that needs the owner: what the morning notification counts as a
    /// follow-up. Not a date that could not be read, not an account with no next step, not a signup.
    public static func isFollowUpDue(_ line: BriefLine) -> Bool {
        line.kind == .sales && line.id.hasPrefix(followUpPrefix) && line.horizon == .today && line.severity <= .normal
    }

    /// Gap keys of the parts a Sales line is read from: while one of them is a gap (accounts set aside, a limit
    /// reached), a mark on a line that is gone is kept, since the line may only be unread. Not production is not one.
    public static func readGapKeys(forLineID id: String) -> Set<String>? {
        if id.hasPrefix(followUpPrefix) || id == noDateID { return [skippedKey, accountsLimitKey] }
        if id.hasPrefix(signupPrefix) || id == noCRMID { return [skippedKey, accountsLimitKey, companiesLimitKey] }
        return nil
    }

    public static func section(_ w: MoneyWorkTrackInput?, now: Date) -> BriefSection {
        guard let w else {
            return BriefSection(kind: .sales, state: .neverRead(L("Sales has not been collected on this device yet.")), readAt: nil, source: source)
        }
        let today = WorkTrackDates.kabulToday(now)
        let part = SalesBuilder.worktrack(w, today: today)
        guard let wt = part.value else {
            // One item, in the shared group: not signed in and a failed company list are the WorkTrack section's own
            // items in Today already.
            if case .accountsFailed = part {
                return BriefSection(kind: .sales, state: .unavailable(part.reason ?? ""), readAt: nil, source: source)
            }
            return BriefSection(kind: .sales, state: .neverRead(part.reason ?? ""), readAt: nil, source: source)
        }
        let read = sourceText(wt)
        let section = DailyBriefBuilder.finish(.sales, lines: lines(wt, today: today), readAt: wt.accountsReadAt, source: read,
                                               gaps: gaps(wt))
        return BriefSection(kind: .sales, state: section.state, lines: section.lines, readAt: wt.accountsReadAt, source: read,
                            notes: notes(wt), gaps: section.gaps)
    }

    static func sourceText(_ wt: SalesWorkTrack) -> String {
        LF("WorkTrack vendor API (%@), /vendor/crm/accounts and /vendor/companies", wt.environment)
    }

    // MARK: Lines

    static func lines(_ wt: SalesWorkTrack, today: String) -> [BriefLine] {
        let product = MonitorProduct.workTrack.title
        let production = wt.isProduction
        let links = wt.console.map { [BriefLink(title: L("Open WorkTrack console"), url: $0, symbol: "safari")] } ?? []
        let accountsSource = "WorkTrack (\(wt.environment)): GET /v1/vendor/crm/accounts"
        let companiesSource = "WorkTrack (\(wt.environment)): GET /v1/vendor/companies, /v1/vendor/crm/accounts"
        let companiesReadAt = max(wt.accountsReadAt, wt.companiesReadAt)
        var lines: [BriefLine] = []

        for f in wt.followUps {
            let a = f.account
            // A follow-up whose company is not in the list may belong to a purged TEST company: it stays (on the page,
            // and on the Desk by its day), but not in the morning notification.
            let counts = production && a.company != .notListed
            let line: (text: String, severity: BriefSeverity, horizon: DeskHorizon?, fact: String)
            switch f.due {
            case .dueNow(let n):
                line = (n == 0 ? LF("Call today: %@", a.name) : LF("Follow-up overdue: %1$@ (due %2$@)", a.name, SalesFormat.day(raw(a))),
                        counts ? .normal : .info, production ? .today : nil, raw(a))
            case .dueSoon:
                line = (LF("Follow up with %1$@ on %2$@", a.name, SalesFormat.day(raw(a))), .info, production ? .thisWeek : nil, raw(a))
            case .dateUnknown(let text):
                line = (text.map { LF("The next-action date of %1$@ could not be read (%2$@)", a.name, $0) }
                            ?? LF("The next-action date of %@ could not be read", a.name),
                        counts ? .normal : .info, nil, "bad:" + (text ?? "?"))
            case .later:
                continue  // the Sales page only
            }
            lines.append(BriefLine(id: followUpPrefix + a.key, kind: .sales, severity: line.severity, text: line.text,
                                   detail: detail(a), source: accountsSource, readAt: wt.accountsReadAt, destination: .sales(a.key),
                                   links: links, product: product, factKey: line.fact, horizon: line.horizon))
        }

        if !wt.noNextStep.isEmpty {
            lines.append(BriefLine(id: noDateID, kind: .sales, severity: production ? .normal : .info,
                                   text: LF("%ld open CRM accounts have no next-action date", wt.noNextStep.count),
                                   detail: L("A lead with no next-action date is not on WorkTrack's own Today tab either. Set the date and the next action in the WorkTrack console; the Sales page lists them."),
                                   source: accountsSource, readAt: wt.accountsReadAt, destination: .sales(nil), links: links,
                                   product: product, factKey: DeskHash.of(wt.noNextStep.map(\.key).sorted())))
        }

        if let signups = wt.signups.value {
            // A new trial is already on the Desk as a WorkTrack trial ending: one company, one item.
            for s in signups.rows where !s.isOnDeskAsRenewal {
                let (why, fact): (String, String) = switch s.reason {
                case .newSignup(let day): (LF("signed up %@", SalesFormat.day(day)), "new:" + day)
                case .selfServe: (L("bought a plan itself"), "selfServe")
                }
                lines.append(BriefLine(id: signupPrefix + s.key, kind: .sales, severity: production ? .normal : .info,
                                       text: LF("New signup with no CRM account: %1$@ (%2$@)", s.company.name, why),
                                       detail: L("No CRM account is linked to this WorkTrack company. Add one in the WorkTrack console to follow it up."),
                                       source: companiesSource, readAt: companiesReadAt, destination: .sales(s.key), links: links,
                                       product: product, factKey: fact))
            }
        }
        if let without = wt.withoutCRMAccount.value, !without.rows.isEmpty {
            let n = without.rows.count
            lines.append(BriefLine(id: noCRMID, kind: .sales, severity: .info,
                                   text: without.isComplete ? LF("%ld WorkTrack companies have no CRM account", n)
                                                            : LF("At least %ld WorkTrack companies have no CRM account", n),
                                   source: companiesSource, readAt: companiesReadAt, destination: .sales(nil), links: links,
                                   product: product, factKey: DeskHash.of(without.rows.map { SalesKey.company($0.companyId) }.sorted())))
        }
        return lines
    }

    /// The stored text of the next-action date ("" when none).
    static func raw(_ a: SalesAccount) -> String {
        switch a.nextActionAt {
        case .day(let d), .notADay(let d): d
        case .none, .unreadable: ""
        }
    }

    /// Stays on this device: shown on the Brief and the Desk, never in the notification, the agent brief or the cloud.
    static func detail(_ a: SalesAccount) -> String {
        var parts = [LF("Stage: %@", SalesFormat.stage(a.stage))]
        if let note = a.nextAction { parts.append(LF("Next action: %@", note)) }
        switch a.company {
        case .prospect:
            parts.append(L("Not linked to a WorkTrack company (a prospect)."))
        case .listed(let c):
            let end = c.license.expiresAt.map(SalesFormat.day) ?? L("no end date")
            parts.append(LF("WorkTrack company %1$@: %2$@ licence, last day %3$@.", c.name, c.license.plan.rawValue, end))
        case .notListed:
            parts.append(L("The linked company is not in the company list (deleted, or past its limit), so whether it is a TEST company is unknown."))
        }
        parts.append(L("Done here does not change the CRM: move the date or the stage in the WorkTrack console."))
        return parts.joined(separator: "\n")
    }

    // MARK: Gaps and notes

    /// The caveats and parts not read of a WorkTrack reading, as the Brief notes them (for the page's Unknown card).
    public static func caveats(_ wt: SalesWorkTrack) -> [String] { gaps(wt).map(\.text) }

    static func gaps(_ wt: SalesWorkTrack) -> [BriefGap] {
        var gaps: [BriefGap] = []
        if wt.accountsSkipped > 0 {
            gaps.append(BriefGap(key: skippedKey, text: LF("%ld CRM accounts could not be read; their follow-ups, and whether a company has a CRM account, are unknown.", wt.accountsSkipped)))
        }
        // Money raises the account limit and the company limit, and WorkTrack customers the environment, as Desk items of
        // their own: here they are notes that keep marks.
        if wt.accountsAtLimit {
            gaps.append(BriefGap(key: accountsLimitKey, text: LF("WorkTrack sent %ld CRM accounts, the most it sends; newer accounts past that, and their follow-ups, are unknown.", MoneyBuilder.crmListLimit),
                                 isCaveat: true, isDeskItem: false))
        }
        if wt.companiesAtLimit {
            gaps.append(BriefGap(key: companiesLimitKey, text: LF("WorkTrack reads at most %ld companies; signups past that are unknown.", MoneyBuilder.revenueCompanyLimit),
                                 isCaveat: true, isDeskItem: false))
        }
        if !wt.isProduction {
            gaps.append(BriefGap(key: productionKey, text: LF("Read from the %@ environment, not production.", wt.environment),
                                 isCaveat: true, isDeskItem: false))
        }
        return gaps
    }

    /// Information only (never Desk items).
    static func notes(_ wt: SalesWorkTrack) -> [String] {
        var notes: [String] = []
        if !wt.leftOut.isEmpty { notes.append(LF("Left out: %ld CRM accounts of TEST or DUPLICATE companies.", wt.leftOut.count)) }
        if wt.notListed > 0 {
            notes.append(LF("%ld follow-ups belong to a WorkTrack company that is not in the company list (deleted, or past its limit); whether it is a TEST company is unknown, so they are listed but not counted in the morning notification.", wt.notListed))
        }
        if !wt.later.isEmpty { notes.append(LF("%ld follow-ups are more than 7 days away; the Sales page lists them.", wt.later.count)) }
        if let n = wt.signups.value?.rows.count(where: \.isOnDeskAsRenewal), n > 0 {
            notes.append(LF("%ld new signups are on the Desk as WorkTrack trials ending; the Sales page lists them.", n))
        }
        notes.append(L("Renewals, website messages and SafeBeauty's KYC queue are on the Desk from their own sections; the Sales page lists them too."))
        return notes
    }
}
