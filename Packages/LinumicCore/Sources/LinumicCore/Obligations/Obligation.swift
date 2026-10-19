import Foundation

// MARK: - Obligations and accounts (تعهدات و حساب‌ها)
//
// The dated things no system reminds the company of: a certificate that ends, a post schedule that shifts when US
// daylight time ends, an account that renews. Each obligation says what is due, when (or that the date is unknown),
// what happens if it is missed, and where that fact comes from and on which day it was recorded. Live dates the app
// already reads (the Monitor's RDAP and TLS readings, the licence ledger, the Keys & Backups registry, the continuity
// export log) become obligations by themselves; the rest is a seed in code, where every row cites its source, plus what
// the owner adds. Nothing is invented: a value with no source is refused, and Done needs evidence.

/// What an obligation is about. Titles are English; the app localizes them.
public enum ObligationArea: String, Codable, CaseIterable, Sendable, Identifiable {
    case signing, stores, domains, licences, keys, continuity, marketing, accounts, company, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .signing: L("Signing")
        case .stores: L("Stores")
        case .domains: L("Domains and certificates")
        case .licences: L("Licences")
        case .keys: L("Keys and backups")
        case .continuity: L("Continuity")
        case .marketing: L("Marketing")
        case .accounts: L("Accounts")
        case .company: L("Company")
        case .other: L("Other")
        }
    }
}

/// Where an obligation comes from.
public enum ObligationOrigin: String, Codable, Sendable, Hashable {
    /// Recorded with its source in the repository docs, a PRIORITIES file or a memory note (`ObligationSeed`).
    case seed
    /// Added by the owner in the app, with a source.
    case owner
    /// The Monitor's RDAP reading of a domain.
    case domain
    /// The Monitor's TLS reading of a host.
    case certificate
    /// The licence ledger.
    case licence
    /// The Keys & Backups registry (restore tests, the second copy).
    case keys
    /// The continuity export log.
    case continuity
    /// An account's renewal.
    case account

    /// Read from a source the app keeps up to date by itself, so it is never edited here.
    public var isLive: Bool {
        switch self {
        case .domain, .certificate, .licence, .keys, .continuity: true
        case .seed, .owner, .account: false
        }
    }

    /// Its due day is set on the Obligations screen (with a source). A live row takes its day from its own source, and
    /// an account's renewal from the account's card, so each day is entered in one place only.
    public var takesDateHere: Bool { self == .seed || self == .owner }

    /// Done with evidence closes it. A live row closes only through its source (a verified export, a restore test, a
    /// renewal the next reading shows): a sentence typed here never stands in for what the app reads itself.
    public var takesDoneHere: Bool { !isLive }
}

/// The owner's Done, with what proves it. Keyed by the obligation and the due day it closes, so a renewed licence or
/// a new date opens the obligation again.
public struct ObligationCompletion: Codable, Hashable, Sendable {
    public var obligationID: String
    /// The due day it closes; nil for an obligation whose date was unknown.
    public var due: KeyDay?
    /// The day it was done.
    public var on: KeyDay
    /// What proves it (a receipt number, a screenshot's name, a store page), as the owner wrote it. Never empty.
    public var evidence: String
    public var enteredAt: Date

    public init(obligationID: String, due: KeyDay?, on: KeyDay, evidence: String, enteredAt: Date) {
        self.obligationID = obligationID
        self.due = due
        self.on = on
        self.evidence = evidence
        self.enteredAt = enteredAt
    }
}

public struct Obligation: Codable, Identifiable, Hashable, Sendable {
    public static let defaultLeadDays = [30, 14, 7, 1]

    /// Lead days the register can use: at least one, each a day from 1 to a year. Anything else (an empty list written
    /// by hand) would keep a row from ever being brought forward, so the defaults are used instead.
    public static func usableLeadDays(_ days: [Int]) -> [Int] {
        !days.isEmpty && days.allSatisfy({ (1...366).contains($0) }) ? days : defaultLeadDays
    }

    public var id: String
    /// English for the seed and live rows (localized when shown); the owner's own words for the rows he adds.
    public var title: String
    /// The product, as a name of record ("WorkTrack", "Linumic OS"), or nil for the company as a whole.
    public var product: String?
    public var area: ObligationArea
    /// Nil: the date is unknown, which is itself something to find out.
    public var due: KeyDay?
    /// What happens if it is missed, as the source says it. Nil when no source says.
    public var consequence: String?
    /// Where the fact comes from: a file and line, a URL, a reading. Never empty.
    public var source: String
    /// The day the fact was recorded in that source (or read). Nil is refused by `validate`.
    public var recordedOn: KeyDay?
    /// For a live row, when its source was read.
    public var readAt: Date?
    /// Days before the due day at which it is brought forward (30, 14, 7 and 1).
    public var leadDays: [Int]
    public var origin: ObligationOrigin
    /// What a live row is about inside its source (a licence id, a host), for opening it.
    public var subject: String?
    /// Filled in when the register is built: the owner's Done for this due day.
    public var completion: ObligationCompletion?
    /// Filled in when the register is built: where an owner-set date came from.
    public var dueSource: String?

    public init(id: String, title: String, product: String? = nil, area: ObligationArea, due: KeyDay?, consequence: String? = nil,
                source: String, recordedOn: KeyDay?, readAt: Date? = nil, leadDays: [Int] = Obligation.defaultLeadDays,
                origin: ObligationOrigin, subject: String? = nil, completion: ObligationCompletion? = nil, dueSource: String? = nil) {
        self.id = id
        self.title = title
        self.product = product
        self.area = area
        self.due = due
        self.consequence = consequence
        self.source = source
        self.recordedOn = recordedOn
        self.readAt = readAt
        self.leadDays = leadDays
        self.origin = origin
        self.subject = subject
        self.completion = completion
        self.dueSource = dueSource
    }

    /// The title to show: the owner's words as written, everything else in the app's language.
    public var displayTitle: String { origin == .owner ? title : L(title) }
    public var displayConsequence: String? { consequence.map { origin == .owner ? $0 : L($0) } }

    public var isClosed: Bool { completion != nil }

    /// The screen that holds the thing itself.
    public var destination: BriefDestination {
        switch origin {
        case .domain, .certificate: .monitor
        case .licence: subject.map(BriefDestination.licence) ?? .licences
        case .keys: .keys
        case .continuity: .continuity
        case .seed, .owner, .account: .obligation(id)
        }
    }
}

// MARK: - Accounts

/// Whose name an account is in: the owner's own, or the company's. After the company is registered this list is the
/// checklist of what to move.
public enum AccountHolder: String, Codable, CaseIterable, Sendable, Identifiable {
    case personal, company

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .personal: L("Personal")
        case .company: L("Company")
        }
    }
}

/// How often a cost is paid, as the bill says.
public enum BillingCycle: String, Codable, CaseIterable, Sendable, Identifiable {
    case monthly, yearly, once

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monthly: L("per month")
        case .yearly: L("per year")
        case .once: L("once")
        }
    }
}

/// What an account costs, as the owner read it on a bill: an amount in one currency (never converted, never added to
/// another currency), how often, and where it was read.
public struct AccountCost: Codable, Hashable, Sendable {
    public var amount: Decimal
    /// ISO 4217 code ("USD", "CAD", "AFN").
    public var currency: String
    public var cycle: BillingCycle
    public var source: String

    public init(amount: Decimal, currency: String, cycle: BillingCycle, source: String) {
        self.amount = amount
        self.currency = currency
        self.cycle = cycle
        self.source = source
    }

    /// "99 USD per year".
    public var text: String { LF("%@ %@ %@", amount.formatted(), currency, cycle.title) }

    /// The cost as it may be recorded: an amount above zero and a three-letter code (upper-cased), with its bill. Nil
    /// for anything else, whether typed in the account sheet or written into obligations.json by hand.
    public var checked: AccountCost? {
        guard let source = ObligationsFile.clean(source) else { return nil }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard amount > 0, code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return AccountCost(amount: amount, currency: code, cycle: cycle, source: source)
    }
}

/// An account the company depends on (a store, a host, a registrar). Never a password or card: the Vault holds
/// sign-ins, and this holds only what the account is, whose it is, when it renews and what it costs (when known).
public struct VendorAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// The vendor's name of record.
    public var name: String
    /// What the company uses it for. English for the seed (localized when shown).
    public var purpose: String
    /// Nil: not recorded.
    public var holder: AccountHolder?
    public var holderSource: String?
    /// The next renewal, when known.
    public var renewal: KeyDay?
    public var renewalSource: String?
    /// The day the renewal was recorded with its source (the owner's entry), when it was not recorded with the account.
    public var renewalRecordedOn: KeyDay?
    /// What it costs, when a bill says so. Nil: unknown, never estimated.
    public var cost: AccountCost?
    /// The day the cost was recorded with its bill, when it was not recorded with the account.
    public var costRecordedOn: KeyDay?
    /// Where the account itself is recorded. Never empty.
    public var source: String
    public var recordedOn: KeyDay?
    public var origin: ObligationOrigin
    public var note: String?

    public init(id: String, name: String, purpose: String, holder: AccountHolder? = nil, holderSource: String? = nil,
                renewal: KeyDay? = nil, renewalSource: String? = nil, cost: AccountCost? = nil, source: String, recordedOn: KeyDay?,
                origin: ObligationOrigin, note: String? = nil) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.holder = holder
        self.holderSource = holderSource
        self.renewal = renewal
        self.renewalSource = renewalSource
        self.cost = cost
        self.source = source
        self.recordedOn = recordedOn
        self.origin = origin
        self.note = note
    }

    public var displayPurpose: String { origin == .owner ? purpose : L(purpose) }
    public var displayNote: String? { note.map { origin == .owner ? $0 : L($0) } }

    /// The obligation for its renewal (dated, or "date unknown").
    public var renewalObligationID: String { Self.renewalObligationID(id) }

    public static func renewalObligationID(_ accountID: String) -> String { "account.\(accountID).renewal" }

    /// A renewal is known to exist: its day is recorded, or a bill says the account is paid monthly or yearly. Only
    /// then is its renewal an obligation; otherwise the account card says "renewal: not recorded" and nothing presumes
    /// that the account renews at all (a free plan, an ad account).
    public var hasRecordedTerm: Bool {
        renewal != nil || (cost.map { $0.cycle != .once } ?? false)
    }
}

// MARK: - Problems

/// What `validate` refuses.
public enum ObligationIssue: Hashable, Sendable, Identifiable {
    /// An obligation or account without a source, or without the day it was recorded.
    case noSource(String)
    /// A Done without evidence.
    case doneWithoutEvidence(String)
    /// Two rows with one id.
    case duplicateID(String)
    /// A date or holder set without saying where it came from.
    case valueWithoutSource(String)
    /// An obligation without a title.
    case noTitle(String)
    /// A row or account in obligations.json that the app's own forms would not have written (its origin is not the
    /// owner's, or its id does not start with "owner."): it could stand in for a seed or live row, so it is left out.
    case notOwners(String)
    /// A date in obligations.json for a row that takes its date from its own source (a live row, or an account's
    /// renewal, whose day is recorded on the account's card), or for a row that is not in the register: it is not
    /// applied.
    case dateNotApplied(String)
    /// A Done in obligations.json for a live row: it closes only through its source, so it is not applied.
    case doneNotApplied(String)
    /// A cost written into obligations.json that the account sheet would refuse (an amount of zero or less, a currency
    /// that is not a three-letter code): it is not applied.
    case badValue(String)
    /// Facts recorded in obligations.json for an account that is not in the register: they are not applied.
    case unknownAccount(String)

    public var id: String {
        switch self {
        case .noSource(let i): "noSource.\(i)"
        case .doneWithoutEvidence(let i): "done.\(i)"
        case .duplicateID(let i): "duplicate.\(i)"
        case .valueWithoutSource(let i): "value.\(i)"
        case .noTitle(let i): "title.\(i)"
        case .notOwners(let i): "notOwners.\(i)"
        case .dateNotApplied(let i): "dateNotApplied.\(i)"
        case .doneNotApplied(let i): "doneNotApplied.\(i)"
        case .badValue(let i): "badValue.\(i)"
        case .unknownAccount(let i): "unknownAccount.\(i)"
        }
    }

    public var text: String {
        switch self {
        case .noSource(let i): LF("%@ has no source or no day it was recorded.", i)
        case .doneWithoutEvidence(let i): LF("%@ is marked done without evidence.", i)
        case .duplicateID(let i): LF("Two rows have the id %@.", i)
        case .valueWithoutSource(let i): LF("A value of %@ was set without a source.", i)
        case .noTitle(let i): LF("%@ has no title.", i)
        case .notOwners(let i): LF("%@ in obligations.json is not a row you added in the app, so it is left out.", i)
        case .dateNotApplied(let i): LF("The date set for %@ is not applied: that row takes its date from its own source (a reading, or the account's card), or it is not in the register.", i)
        case .doneNotApplied(let i): LF("The Done recorded for %@ is not applied: that row closes only when its own source says so (an export, a restore test, a new reading).", i)
        case .badValue(let i): LF("A cost of %@ is not applied: the amount must be above zero and the currency a three-letter code.", i)
        case .unknownAccount(let i): LF("What was recorded for the account %@ is not applied: no account with that id is in the register.", i)
        }
    }
}

/// Why a change was refused (the owner's form says it before anything is saved).
public enum ObligationError: LocalizedError, Equatable {
    case missingTitle
    case missingSource
    case missingEvidence
    case duplicateID(String)
    case unknownID(String)
    case futureDay
    case badAmount

    public var errorDescription: String? {
        switch self {
        case .missingTitle: L("Write what is due.")
        case .missingSource: L("Say where this comes from (a file and line, a page, a receipt). Nothing is saved without a source.")
        case .missingEvidence: L("Say what proves it is done. Done is not saved without evidence.")
        case .duplicateID(let id): LF("An obligation with the id %@ already exists.", id)
        case .unknownID(let id): LF("Nothing with the id %@ is in the register.", id)
        case .futureDay: L("The day it was done can't be in the future.")
        case .badAmount: L("Write the amount as a number above zero, and the currency as its three-letter code (USD, CAD, AFN).")
        }
    }
}
