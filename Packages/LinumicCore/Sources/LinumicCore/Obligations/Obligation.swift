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
    /// What it costs, when a bill says so. Nil: unknown, never estimated.
    public var cost: AccountCost?
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
    public var renewalObligationID: String { "account.\(id).renewal" }
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

    public var id: String {
        switch self {
        case .noSource(let i): "noSource.\(i)"
        case .doneWithoutEvidence(let i): "done.\(i)"
        case .duplicateID(let i): "duplicate.\(i)"
        case .valueWithoutSource(let i): "value.\(i)"
        case .noTitle(let i): "title.\(i)"
        }
    }

    public var text: String {
        switch self {
        case .noSource(let i): LF("%@ has no source or no day it was recorded.", i)
        case .doneWithoutEvidence(let i): LF("%@ is marked done without evidence.", i)
        case .duplicateID(let i): LF("Two rows have the id %@.", i)
        case .valueWithoutSource(let i): LF("A value of %@ was set without a source.", i)
        case .noTitle(let i): LF("%@ has no title.", i)
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
