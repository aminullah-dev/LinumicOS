import Foundation

// MARK: - Sales (فروش): who to call today
//
// Pure and deterministic: the same input and time give the same report. Rules:
// - Every day rule uses Kabul's Gregorian date, as the WorkTrack server does (`routes/vendor.ts:52-54`): a follow-up is
//   due when its `nextActionAt` is today or earlier, and soon when it is within the next 7 days (`services/crm.ts:252-272`).
//   This device's time zone and calendar never decide a day; they only show it.
// - TEST and DUPLICATE companies are left out (`flags != nil`, the server's own rule, `services/vendor.ts:127`). A CRM
//   account reaches a company only through `companyId`; an account whose company is not in the list is kept, with a
//   caveat, since whether that company was a TEST one is unknown.
// - Unknown is never "none": when accounts were set aside or a limit was reached, whether a company has a CRM account
//   is Unknown with its reason, and a list cut by a limit is "at least".
// - Nothing is written anywhere: the report lives in memory and is rebuilt on every render.

/// A Sales row's stable key: a hash of the CRM's or WorkTrack's own id, never the id itself. It is what Desk ids and
/// the agent brief carry, so no CRM or company id reaches `desk-state.json`, the clipboard or Supabase.
public enum SalesKey {
    public static func account(_ id: String) -> String { DeskHash.of("sales.account", id) }
    public static func company(_ id: String) -> String { DeskHash.of("sales.company", id) }
}

/// A read part of the page, or why it is not known (a sentence, never "none").
public enum SalesRead<T: Sendable>: Sendable {
    case read(T)
    case unknown(String)

    public var value: T? {
        if case .read(let v) = self { v } else { nil }
    }

    public var reason: String? {
        if case .unknown(let r) = self { r } else { nil }
    }
}

/// Rows read, and whether they are all there: false when a server limit was reached, so the count is "at least".
public struct SalesList<T: Sendable>: Sendable {
    public var rows: [T]
    public var isComplete: Bool

    public init(rows: [T], isComplete: Bool) {
        self.rows = rows
        self.isComplete = isComplete
    }
}

/// The WorkTrack company a CRM account is linked to.
public enum SalesLink: Equatable, Sendable {
    /// No `companyId`: a prospect, or a customer handled by hand.
    case prospect
    case listed(WTCompany)
    /// A `companyId` that is not in the company list: deleted, purged (its CRM records stay, `crm.ts:8-11`) or past the
    /// list's limit of 500.
    case notListed

    public var company: WTCompany? {
        if case .listed(let c) = self { c } else { nil }
    }
}

/// When a follow-up is due, by Kabul's day.
public enum SalesDue: Equatable, Sendable {
    /// Today (0) or overdue by this many days.
    case dueNow(overdueDays: Int)
    /// In 1 to 7 days.
    case dueSoon(inDays: Int)
    /// More than 7 days away.
    case later(inDays: Int)
    /// The stored date is not a real day, or not a string (nil): shown, never guessed.
    case dateUnknown(raw: String?)
}

/// One CRM account, as Sales lists it. In memory only.
public struct SalesAccount: Equatable, Sendable, Identifiable {
    /// `SalesKey.account(accountID)`.
    public var key: String
    /// The CRM's id, for the on-demand contacts read. Never shown, never in a Desk id.
    public var accountID: String
    public var name: String
    public var stage: WTAccountStage?
    public var nextActionAt: WTCrmDay
    public var nextAction: String?
    public var company: SalesLink

    public var id: String { key }
}

public struct SalesFollowUp: Equatable, Sendable, Identifiable {
    public var account: SalesAccount
    public var due: SalesDue
    public var id: String { account.key }
}

/// A WorkTrack company with no CRM account that is new or bought a plan itself.
public struct SalesSignup: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// Created on this Kabul day, at most `SalesBuilder.newSignupDays` days ago.
        case newSignup(createdDay: String)
        /// The licence was last written by a HesabPay purchase (`license.source`, `services/billing.ts:386`).
        case selfServe
    }

    /// `SalesKey.company(companyId)`.
    public var key: String
    public var company: WTCompany
    public var reason: Reason
    /// Already on the Desk as a WorkTrack trial or renewal ending (the WorkTrack section's own item): listed on the page,
    /// never a second Desk item.
    public var isOnDeskAsRenewal: Bool
    public var id: String { key }
}

/// A licence ending within 30 days or ended, from the company list. Already a Desk item of the WorkTrack section.
public struct SalesRenewal: Equatable, Sendable, Identifiable {
    public var company: WTCompany
    /// Days from Kabul's today to the last day, counted again now (not the server's count of up to 6 hours ago); nil
    /// for a date that is not a real day.
    public var daysLeft: Int?
    public var id: String { company.companyId }
}

/// The WorkTrack part: follow-ups, accounts with no next step, signups without a CRM account.
public struct SalesWorkTrack: Sendable {
    public var environment: String
    public var accountsReadAt: Date
    public var companiesReadAt: Date
    /// Every account with a next-action date (any stage, as WorkTrack's own dashboard), TEST and DUPLICATE left out.
    public var followUps: [SalesFollowUp]
    /// Open accounts (or of an unknown stage) with no next-action date.
    public var noNextStep: [SalesAccount]
    public var signups: SalesRead<SalesList<SalesSignup>>
    /// Other companies (not TEST or DUPLICATE, not being deleted) with no CRM account.
    public var withoutCRMAccount: SalesRead<SalesList<WTCompany>>
    /// Accounts linked to a TEST or DUPLICATE company that would otherwise be listed.
    public var leftOut: [SalesAccount]
    /// CRM documents the app could not decode.
    public var accountsSkipped: Int
    /// The server sent as many accounts as it sends at most (2000): newer ones may be missing.
    public var accountsAtLimit: Bool
    /// The company list has as many companies as the server lists at most (500).
    public var companiesAtLimit: Bool

    public var isProduction: Bool { environment == WorkTrackEnvironment.production.rawValue }
    /// The vendor console, production only.
    public var console: URL? { isProduction ? WorkTrackEnvironment.production.console : nil }

    /// Due today or overdue, most overdue first, then by name.
    public var callToday: [SalesFollowUp] {
        followUps.compactMap { f in if case .dueNow(let n) = f.due { (f, n) } else { nil } }
            .sorted { ($1.1, $0.0.account.name) < ($0.1, $1.0.account.name) }.map(\.0)
    }

    /// In the next 7 days, soonest first.
    public var thisWeek: [SalesFollowUp] { days { if case .dueSoon(let n) = $0 { n } else { nil } } }

    /// More than 7 days away, soonest first.
    public var later: [SalesFollowUp] { days { if case .later(let n) = $0 { n } else { nil } } }

    public var dateUnknown: [SalesFollowUp] {
        followUps.filter { if case .dateUnknown = $0.due { true } else { false } }.sorted { $0.account.name < $1.account.name }
    }

    /// Follow-ups whose company is not in the list.
    public var notListed: Int { followUps.count { $0.account.company == .notListed } }

    private func days(_ pick: (SalesDue) -> Int?) -> [SalesFollowUp] {
        followUps.compactMap { f in pick(f.due).map { (f, $0) } }.sorted { ($0.1, $0.0.account.name) < ($1.1, $1.0.account.name) }.map(\.0)
    }
}

/// Where the WorkTrack part stands.
public enum SalesWorkTrackPart: Sendable {
    case notSignedIn
    /// The company list failed: the WorkTrack customers section says why.
    case companyListFailed
    case notRead
    case accountsFailed(String)
    case read(SalesWorkTrack)

    public var value: SalesWorkTrack? {
        if case .read(let w) = self { w } else { nil }
    }

    /// Why it is Unknown, as a sentence; nil when it was read.
    public var reason: String? {
        switch self {
        case .notSignedIn: L("Not signed in to WorkTrack, so who to call is unknown.")
        case .companyListFailed: L("The WorkTrack company list could not be read (WorkTrack customers says why), so who to call is unknown.")
        case .notRead: L("Signed in, but the CRM accounts have not been read yet.")
        case .accountsFailed(let m): LF("The CRM accounts could not be read: %@", m)
        case .read: nil
        }
    }
}

public struct SalesSiteMessages: Sendable {
    /// Not marked seen, newest first.
    public var new: [SiteMessage]
    public var earlierSeen: Int
    public var readAt: Date
}

/// Providers waiting for KYC in SafeBeauty: a count, never names.
public struct SalesKYC: Sendable, Equatable {
    /// `role == "PROVIDER"` among the queue read.
    public var providers: Int
    /// The queue read holds every person waiting (its size equals Firestore's count); otherwise "at least".
    public var isExact: Bool
    /// Everyone waiting for KYC, providers or not.
    public var pending: Int
    public var environment: String
    public var readAt: Date
}

public struct SalesReport: Sendable {
    public var builtAt: Date
    /// Kabul's date at `builtAt`, `YYYY-MM-DD`.
    public var kabulToday: String
    public var worktrack: SalesWorkTrackPart
    public var renewals: SalesRead<SalesList<SalesRenewal>>
    public var siteMessages: SalesRead<SalesSiteMessages>
    public var kyc: SalesRead<SalesKYC>
}

public enum SalesBuilder {
    /// A new signup is at most this many Kabul days old: the trial's length (`TRIAL_DAYS`, `services/plans.ts:101`).
    public static let newSignupDays = 14
    /// "Due soon" reaches this many days ahead (`crm.ts:260-262`).
    public static let soonDays = 7
    /// Renewals and trials ending within this many days are listed (the WorkTrack section's window).
    public static let renewalWindow = 30
    /// The role SafeBeauty gives a salon provider (`functions/lib/registration.js:39-41`).
    public static let providerRole = "PROVIDER"

    public static func build(_ input: SalesInput, now: Date) -> SalesReport {
        let today = WorkTrackDates.kabulToday(now)
        return SalesReport(builtAt: now, kabulToday: today, worktrack: worktrack(input.worktrack, today: today),
                           renewals: renewals(input.worktrack, today: today), siteMessages: siteMessages(input.siteMessages),
                           kyc: kyc(input.kyc))
    }

    /// When a follow-up is due by Kabul's `today`; nil when it has no date. For a real day this is the server's own
    /// rule: a zero-padded `YYYY-MM-DD` compares as text exactly as it does as a date, and "within 7 days" is the same
    /// as "on or before today + 7" counted at UTC midnight.
    public static func due(_ day: WTCrmDay, today: String) -> SalesDue? {
        switch day {
        case .none: return nil
        case .unreadable: return .dateUnknown(raw: nil)
        case .notADay(let s): return .dateUnknown(raw: s)
        case .day(let d):
            guard let n = WorkTrackDates.daysBetween(today, d) else { return .dateUnknown(raw: d) }
            if n <= 0 { return .dueNow(overdueDays: -n) }
            return n <= soonDays ? .dueSoon(inDays: n) : .later(inDays: n)
        }
    }

    // MARK: WorkTrack

    public static func worktrack(_ w: MoneyWorkTrackInput, today: String) -> SalesWorkTrackPart {
        guard w.isSignedIn else { return .notSignedIn }
        if w.loadError != nil { return .companyListFailed }
        guard let companiesReadAt = w.companiesReadAt, let accountsRead = w.money?.accounts else { return .notRead }
        if let failure = accountsRead.failure { return .accountsFailed(failure) }
        guard let accounts = accountsRead.value else { return .notRead }

        let companies = Dictionary(w.companies.map { ($0.companyId, $0) }, uniquingKeysWith: { first, _ in first })
        var followUps: [SalesFollowUp] = [], noNextStep: [SalesAccount] = [], leftOut: [SalesAccount] = []
        for a in accounts.rows {
            let link: SalesLink = a.companyId.map { id in companies[id].map(SalesLink.listed) ?? .notListed } ?? .prospect
            let account = SalesAccount(key: SalesKey.account(a.id), accountID: a.id, name: a.name, stage: a.stage,
                                       nextActionAt: a.nextActionAt, nextAction: a.nextAction, company: link)
            let flagged = link.company?.isFlagged == true
            if let due = due(a.nextActionAt, today: today) {
                if flagged { leftOut.append(account) } else { followUps.append(SalesFollowUp(account: account, due: due)) }
            } else if a.stage.map({ $0.isOpen || !$0.isKnown }) ?? true {
                // No date: the owner's next step is missing while the account is still being sold to (or its stage is
                // unknown). WON, LOST and DORMANT need none.
                if flagged { leftOut.append(account) } else { noNextStep.append(account) }
            }
        }
        noNextStep.sort { $0.name < $1.name }
        leftOut.sort { $0.name < $1.name }

        let accountsAtLimit = accounts.rows.count + accounts.skipped >= MoneyBuilder.crmListLimit
        let companiesAtLimit = w.companies.count >= MoneyBuilder.revenueCompanyLimit
        let (signups, without) = signups(w.companies, accounts: accounts, atLimit: accountsAtLimit,
                                         companiesComplete: !companiesAtLimit, today: today)
        return .read(SalesWorkTrack(environment: w.environment ?? "?", accountsReadAt: accountsRead.at, companiesReadAt: companiesReadAt,
                                    followUps: followUps, noNextStep: noNextStep, signups: signups, withoutCRMAccount: without,
                                    leftOut: leftOut, accountsSkipped: accounts.skipped, accountsAtLimit: accountsAtLimit,
                                    companiesAtLimit: companiesAtLimit))
    }

    /// Companies with no CRM account: the new and the self-serve ones, and the rest. Unknown while any account was set
    /// aside or the account limit was reached, since a missing account could be the link.
    static func signups(_ companies: [WTCompany], accounts: WTLossyList<WTCrmAccount>, atLimit: Bool, companiesComplete: Bool,
                        today: String) -> (SalesRead<SalesList<SalesSignup>>, SalesRead<SalesList<WTCompany>>) {
        let why: String? = if accounts.skipped > 0 {
            LF("%ld CRM accounts could not be read, so whether a company has a CRM account is unknown.", accounts.skipped)
        } else if atLimit {
            LF("WorkTrack sent %ld CRM accounts, the most it sends, so whether a company has a CRM account is unknown.", MoneyBuilder.crmListLimit)
        } else { nil }
        if let why { return (.unknown(why), .unknown(why)) }

        let byID = Dictionary(companies.map { ($0.companyId, $0) }, uniquingKeysWith: { first, _ in first })
        var linked: Set<String> = []
        for a in accounts.rows {
            guard let id = a.companyId else { continue }
            // WorkTrack opens a WON account for a company on its first support ticket (`routes/support.ts:49-68`). While
            // the company is still on its trial that is not a sale, so it does not count as "has a CRM account".
            if a.stage == .won, byID[id]?.isTrial == true { continue }
            linked.insert(id)
        }
        let summary = WTCustomersSummary(companies: companies, window: renewalWindow)
        let onDesk = Set((summary.expiringSoon + summary.expired).map(\.companyId))
        var signups: [SalesSignup] = [], without: [WTCompany] = []
        // A company being deleted (only a scheduled deletion is reported, `services/vendor.ts:124-126`) is no one to call.
        for c in companies where !c.isFlagged && c.deletion == nil && !linked.contains(c.companyId) {
            let reason: SalesSignup.Reason?
            if c.license.source == "SELF_SERVE" {
                reason = .selfServe
            } else if let created = WorkTrackDates.instant(c.createdAt).map(WorkTrackDates.kabulToday),
                      let age = WorkTrackDates.daysBetween(created, today), (0...newSignupDays).contains(age) {
                reason = .newSignup(createdDay: created)
            } else {
                reason = nil
            }
            if let reason {
                signups.append(SalesSignup(key: SalesKey.company(c.companyId), company: c, reason: reason,
                                           isOnDeskAsRenewal: onDesk.contains(c.companyId)))
            } else {
                without.append(c)
            }
        }
        signups.sort { a, b in
            switch (a.reason, b.reason) {
            case (.newSignup(let x), .newSignup(let y)): (y, a.company.name) < (x, b.company.name)
            case (.newSignup, .selfServe): true
            case (.selfServe, .newSignup): false
            case (.selfServe, .selfServe): a.company.name < b.company.name
            }
        }
        without.sort { $0.name < $1.name }
        return (.read(SalesList(rows: signups, isComplete: companiesComplete)), .read(SalesList(rows: without, isComplete: companiesComplete)))
    }

    // MARK: Renewals

    /// Licences ending within 30 days (ACTIVE) or ended, TEST and DUPLICATE left out, as the WorkTrack section reads them.
    static func renewals(_ w: MoneyWorkTrackInput, today: String) -> SalesRead<SalesList<SalesRenewal>> {
        guard w.isSignedIn else { return .unknown(L("Not signed in to WorkTrack customers, so renewals are unknown.")) }
        if let error = w.loadError { return .unknown(error) }
        guard w.companiesReadAt != nil else { return .unknown(L("Signed in, but the company list has not been read yet.")) }
        let summary = WTCustomersSummary(companies: w.companies, window: renewalWindow)
        func row(_ c: WTCompany) -> SalesRenewal {
            SalesRenewal(company: c, daysLeft: c.license.expiresAt.flatMap { WorkTrackDates.daysBetween(today, $0) })
        }
        let ended = summary.expired.sorted { ($0.license.expiresAt ?? "", $1.name) > ($1.license.expiresAt ?? "", $0.name) }
        return .read(SalesList(rows: ended.map(row) + summary.expiringSoon.map(row),
                               isComplete: w.companies.count < MoneyBuilder.revenueCompanyLimit))
    }

    // MARK: Website messages and KYC

    static func siteMessages(_ m: BriefSiteMessagesInput?) -> SalesRead<SalesSiteMessages> {
        guard let m, m.isConfigured else {
            return .unknown(L("Not connected. Add a WordPress application password in Settings → Integrations → Website messages."))
        }
        guard let reading = m.reading else {
            if let error = m.loadError { return .unknown(error) }
            return .unknown(L("Connected, not read yet. It is read when the app opens and every 30 minutes."))
        }
        let new = SiteMessagesRules.new(reading.messages, seen: m.seenIDs)
        return .read(SalesSiteMessages(new: new, earlierSeen: reading.messages.count - new.count, readAt: reading.readAt))
    }

    static func kyc(_ k: SalesKYCInput?) -> SalesRead<SalesKYC> {
        guard let k, k.isSignedIn else { return .unknown(L("Not signed in to SafeBeauty, so providers waiting for KYC are unknown.")) }
        guard let pending = k.pendingCount, let roles = k.queueRoles, let readAt = k.readAt else {
            if let error = k.loadError { return .unknown(LF("SafeBeauty could not be read: %@", error)) }
            return .unknown(L("Signed in to SafeBeauty, but its queues have not been read yet."))
        }
        return .read(SalesKYC(providers: roles.count { $0 == providerRole }, isExact: roles.count == pending, pending: pending,
                              environment: k.environment ?? "?", readAt: readAt))
    }
}

// MARK: - Display

public enum SalesFormat {
    /// A stage in the WorkTrack console's own words (`web/src/pages/vendor/strings.ts:240-246`).
    public static func stage(_ stage: WTAccountStage?) -> String {
        guard let stage else { return L("Stage unknown") }
        return switch stage {
        case .lead: L("Lead")
        case .contacted: L("Contacted")
        case .demo: L("Demo stage")
        case .quoted: L("Quoted")
        case .won: L("Won")
        case .lost: L("Lost")
        case .dormant: L("Dormant")
        default: LF("Stage %@ (not one WorkTrack defines)", stage.rawValue)
        }
    }

    /// A WorkTrack day in this device's calendar, the same day in every time zone.
    public static func day(_ text: String) -> String { WorkTrackDates.displayText(text) }
}
