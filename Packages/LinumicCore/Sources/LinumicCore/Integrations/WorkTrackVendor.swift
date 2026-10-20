import Foundation

// WorkTrack vendor console API (`/v1/vendor/*`), read and licence write.
//
// Source of every route and schema: the WorkTrack repository at main @ f2a9d2c (2026-10-09),
//   backend/functions/src/routes/vendor.ts        routes, audit, `today` in Asia/Kabul
//   backend/functions/src/middleware/vendor.ts    vendor claim, no cid/eid, verified email, revocation check
//   backend/functions/src/services/license.ts     License, licenseWriteSchema, setLicense
//   backend/functions/src/services/plans.ts       PlanDef, feature keys
//   backend/functions/src/services/billing.ts     OrderDto
//   backend/functions/src/services/vendor.ts      CompanySummary, CompanyDetail, TimelineEvent
//   backend/functions/src/services/vendorInsights.ts  flags, attention, RevenueSummary
//   backend/functions/src/lib/errors.ts           problem+json errors
// and, for Money, at origin/main @ 0403fd0 (2026-10-19; the files above are unchanged since f2a9d2c):
//   backend/functions/src/routes/vendor.ts:308-345  the CRM routes; GET /crm/{accounts,invoices} -> {data: [...]}
//   backend/functions/src/services/crm.ts:36-51     accountWriteSchema (companyId links an account to a tenant)
//   backend/functions/src/services/crm.ts:99-114    invoiceWriteSchema (status, amountAfn, issuedAt, dueAt, paidAt, method)
//   backend/functions/src/services/crm.ts:147-155   shape(): the stored document plus id, createdAt, updatedAt
//   backend/functions/src/services/crm.ts:198-206   list(): limit(2000), no order, no cursor
//   backend/functions/src/services/crm.ts:25-33     ACCOUNT_STAGES; :48-49 nextActionAt (regex only) and nextAction (Sales)
//   backend/functions/src/services/crm.ts:56-66     contactWriteSchema (Sales reads one account's contacts on demand)
// Only fields the app shows are decoded; unknown fields are ignored. Money and Sales never call a CRM write.

// MARK: - Environment

/// Which WorkTrack backend Linumic OS talks to. Production holds real customers.
public enum WorkTrackEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case production
    case demo
    /// The Firebase Emulator Suite on this Mac (`--project demo-worktrack`). Offered in debug builds only.
    case localEmulator

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .production: L("Production")
        case .demo: L("Demo")
        case .localEmulator: L("Local emulator")
        }
    }

    public var isProduction: Bool { self == .production }

    /// The environments the app offers. The emulator only when the caller says so (debug builds).
    public static func offered(includeEmulator: Bool) -> [WorkTrackEnvironment] {
        includeEmulator ? allCases : [.production, .demo]
    }

    /// `…/v1`. Hosting rewrites `/v1/**` to the `api` function (WorkTrack `firebase.json`).
    public var apiBase: URL {
        switch self {
        case .production: URL(string: "https://worktrack-prod.web.app/v1")!
        case .demo: URL(string: "https://worktrack-demo-af.web.app/v1")!
        // WorkTrack web/.env.emulator: VITE_API_BASE_URL
        case .localEmulator: URL(string: "http://127.0.0.1:5001/demo-worktrack/us-central1/api/v1")!
        }
    }

    /// The vendor console, where invoices, flags and the CRM are edited (WorkTrack `web/src/console/consoleHost.ts:13`).
    /// Production only.
    public var console: URL? {
        switch self {
        case .production: URL(string: "https://console.linumic.com/")!
        case .demo, .localEmulator: nil
        }
    }

    /// Public Firebase Web API keys. Source: WorkTrack `web/.env.production:18` and `web/.env.demo:20`
    /// (`VITE_FIREBASE_API_KEY`; the same values are in `ios/WorkTrack/Core/Environment.swift:48-49`).
    /// They identify the Firebase project and are shipped in every WorkTrack client; they are not secrets.
    /// The Auth emulator accepts any key; `demo-key` is the one in `web/.env.emulator`.
    public var auth: FirebaseAuthEndpoints {
        switch self {
        case .production: .google(apiKey: "AIzaSyBhGGgbBqhdsJYpM9FpQld28jyhvEfqWPA")
        case .demo: .google(apiKey: "AIzaSyA1Kb5qR8UKXLTkpR3o0Qz7xPUT9i7wAxo")
        case .localEmulator: .emulator(host: "127.0.0.1", port: 9099, apiKey: "demo-key")
        }
    }
}

// MARK: - Models

/// A string-backed value from the server that the app knows some values of, without failing on others.
public protocol WorkTrackCode: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {}

public struct WTPlan: WorkTrackCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let trial = WTPlan(rawValue: "TRIAL")
    public static let bronze = WTPlan(rawValue: "BRONZE")
    public static let silver = WTPlan(rawValue: "SILVER")
    public static let gold = WTPlan(rawValue: "GOLD")
    /// `plans.ts` PLAN_IDS, in order.
    public static let all: [WTPlan] = [.trial, .bronze, .silver, .gold]
    public var isKnown: Bool { Self.all.contains(self) }
}

public struct WTLicenseStatus: WorkTrackCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let active = WTLicenseStatus(rawValue: "ACTIVE")
    public static let suspended = WTLicenseStatus(rawValue: "SUSPENDED")
    public static let expired = WTLicenseStatus(rawValue: "EXPIRED")
    /// What `licenseWriteSchema` accepts. A stored value outside this list (written by hand) can be read, not sent back.
    public static let writable: [WTLicenseStatus] = [.active, .suspended, .expired]
}

/// `License` (`services/license.ts:49-63`). `expiresAt` nil = perpetual.
public struct WTLicense: Codable, Equatable, Sendable {
    public var plan: WTPlan
    public var deviceLimit: Int
    public var status: WTLicenseStatus
    /// `YYYY-MM-DD` (last day in force), or nil for a perpetual licence.
    public var expiresAt: String?
    public var enforceDevices: Bool
    public var enforcePlan: Bool
    /// nil = the plan's own cap.
    public var employeeLimit: Int?
    public var extraFeatures: [String]
    /// `VENDOR` or `SELF_SERVE`.
    public var source: String

    public init(plan: WTPlan, deviceLimit: Int, status: WTLicenseStatus, expiresAt: String?, enforceDevices: Bool,
                enforcePlan: Bool, employeeLimit: Int?, extraFeatures: [String], source: String) {
        self.plan = plan
        self.deviceLimit = deviceLimit
        self.status = status
        self.expiresAt = expiresAt
        self.enforceDevices = enforceDevices
        self.enforcePlan = enforcePlan
        self.employeeLimit = employeeLimit
        self.extraFeatures = extraFeatures
        self.source = source
    }

    /// Tolerant of documents written before a field existed, the same way `normalizeLicense` fills them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(WTPlan.self, forKey: .plan) ?? .bronze
        deviceLimit = try c.decodeIfPresent(Int.self, forKey: .deviceLimit) ?? 5
        status = try c.decodeIfPresent(WTLicenseStatus.self, forKey: .status) ?? .active
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        enforceDevices = try c.decodeIfPresent(Bool.self, forKey: .enforceDevices) ?? false
        enforcePlan = try c.decodeIfPresent(Bool.self, forKey: .enforcePlan) ?? false
        employeeLimit = try c.decodeIfPresent(Int.self, forKey: .employeeLimit)
        extraFeatures = try c.decodeIfPresent([String].self, forKey: .extraFeatures) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "VENDOR"
    }
}

/// The vendor's own mark (`vendorInsights.ts` CompanyFlags).
public struct WTFlags: Codable, Equatable, Sendable {
    public var kind: String
    public var duplicateOf: String?
    public var note: String?
    public var at: String?
    public var by: String?

    public var isTest: Bool { kind == "TEST" }
    public var isDuplicate: Bool { kind == "DUPLICATE" }
}

public struct WTAttention: Codable, Equatable, Sendable, Hashable {
    public var code: String
    /// high, medium, low, info
    public var severity: String
}

public struct WTDuplicateMatch: Codable, Equatable, Sendable {
    public var companyId: String
    public var name: String
    public var reasons: [String]
}

public struct WTDeletion: Codable, Equatable, Sendable {
    public var status: String
    public var purgeAfter: String?
}

/// `CompanySummary` (`services/vendor.ts:44-69`).
public struct WTCompany: Codable, Equatable, Sendable, Identifiable {
    public var companyId: String
    public var name: String
    public var status: String
    public var license: WTLicense
    public var devicesInUse: Int
    public var employeeCount: Int
    public var employeesCounted: Int
    public var employeeCap: Int
    /// Computed by the server with today's date in Asia/Kabul; nil = perpetual.
    public var daysUntilExpiry: Int?
    public var createdAt: String?
    public var lastActivityAt: String?
    public var deletion: WTDeletion?
    public var flags: WTFlags?
    public var duplicates: [WTDuplicateMatch]
    public var attention: [WTAttention]

    public var id: String { companyId }
}

public struct WTCrmAccountRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var stage: String
}

public struct WTCrmContactRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var accountId: String
    public var name: String
    public var role: String?
    public var phone: String?
    public var email: String?
    public var primary: Bool
}

/// `TimelineEvent` (`services/vendor.ts:289-317`), newest first.
public enum WTTimelineEvent: Decodable, Equatable, Sendable {
    case signup(at: String)
    case licence(at: String, by: String?, before: WTLicense?, after: WTLicense?)
    case flags(at: String, by: String?, after: WTFlags?)
    case order(at: String, orderId: String, status: String, plan: String, term: String, months: Int, amountAfn: Double, transactionId: String?)
    case ticket(at: String, ticketId: String, subject: String, status: String, priority: String, resolvedAt: String?)
    /// A kind this version of the app doesn't know.
    case other(kind: String, at: String)

    private enum Keys: String, CodingKey {
        case kind, at, by, before, after, orderId, status, plan, term, months, amountAfn, transactionId, ticketId, subject, priority, resolvedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        switch kind {
        case "SIGNUP": self = .signup(at: at)
        case "LICENCE":
            self = .licence(at: at, by: try c.decodeIfPresent(String.self, forKey: .by),
                            before: try c.decodeIfPresent(WTLicense.self, forKey: .before),
                            after: try c.decodeIfPresent(WTLicense.self, forKey: .after))
        case "FLAGS":
            self = .flags(at: at, by: try c.decodeIfPresent(String.self, forKey: .by), after: try c.decodeIfPresent(WTFlags.self, forKey: .after))
        case "ORDER":
            self = .order(at: at, orderId: try c.decode(String.self, forKey: .orderId), status: try c.decode(String.self, forKey: .status),
                          plan: try c.decode(String.self, forKey: .plan), term: try c.decode(String.self, forKey: .term),
                          months: try c.decodeIfPresent(Int.self, forKey: .months) ?? 0,
                          amountAfn: try c.decodeIfPresent(Double.self, forKey: .amountAfn) ?? 0,
                          transactionId: try c.decodeIfPresent(String.self, forKey: .transactionId))
        case "TICKET":
            self = .ticket(at: at, ticketId: try c.decode(String.self, forKey: .ticketId), subject: try c.decodeIfPresent(String.self, forKey: .subject) ?? "",
                           status: try c.decodeIfPresent(String.self, forKey: .status) ?? "", priority: try c.decodeIfPresent(String.self, forKey: .priority) ?? "",
                           resolvedAt: try c.decodeIfPresent(String.self, forKey: .resolvedAt))
        default: self = .other(kind: kind, at: at)
        }
    }

    public var at: String {
        switch self {
        case .signup(let at), .licence(let at, _, _, _), .flags(let at, _, _), .order(let at, _, _, _, _, _, _, _),
             .ticket(let at, _, _, _, _, _), .other(_, let at): at
        }
    }
}

/// `CompanyDetail` (`services/vendor.ts:337-344`).
public struct WTCompanyDetail: Decodable, Equatable, Sendable {
    public var company: WTCompany
    public var crmAccounts: [WTCrmAccountRef]
    public var contacts: [WTCrmContactRef]
    public var timeline: [WTTimelineEvent]
}

/// `OrderDto` (`services/billing.ts:98-110`).
public struct WTOrder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var companyId: String
    public var plan: String
    /// MONTHLY or YEARLY
    public var term: String
    public var months: Int
    public var amountAfn: Double
    /// PENDING, PAID or FAILED
    public var status: String
    public var createdAt: String?
    public var paidAt: String?
    public var transactionId: String?
    public var checkoutUrl: String?
}

/// `RevenueSummary` (`services/vendorInsights.ts:370-388`).
public struct WTRevenue: Codable, Equatable, Sendable {
    public struct Month: Codable, Equatable, Sendable { public var year: Int; public var month: Int; public var totalAfn: Double; public var orderCount: Int }
    public struct PlanTotal: Codable, Equatable, Sendable { public var plan: String; public var totalAfn: Double; public var orderCount: Int }
    public struct Earned: Codable, Equatable, Sendable { public var totalAfn: Double; public var orderCount: Int; public var byMonth: [Month]; public var byPlan: [PlanTotal] }
    public struct Renewal: Codable, Equatable, Sendable {
        public var companyId: String
        public var name: String
        public var plan: String
        public var expiresAt: String
        public var daysUntilExpiry: Int
        public var term: String
        public var months: Int
        public var amountAfn: Double
        /// LAST_PAID_TERM or MONTHLY_PRICE
        public var basis: String
    }
    public struct Expected: Codable, Equatable, Sendable { public var windowDays: Int; public var totalAfn: Double; public var renewals: [Renewal] }
    public struct Excluded: Codable, Equatable, Sendable { public var companyCount: Int; public var orderCount: Int; public var amountAfn: Double }

    public var currency: String
    public var earned: Earned
    public var expected: Expected
    public var excluded: Excluded
}

// MARK: - CRM (read-only, for Money)

/// `INVOICE_STATUSES` (`services/crm.ts:99`). A stored value outside the list is kept, not refused.
public struct WTInvoiceStatus: WorkTrackCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let draft = WTInvoiceStatus(rawValue: "DRAFT")
    public static let sent = WTInvoiceStatus(rawValue: "SENT")
    public static let paid = WTInvoiceStatus(rawValue: "PAID")
    public static let void = WTInvoiceStatus(rawValue: "VOID")
    public static let all: [WTInvoiceStatus] = [.draft, .sent, .paid, .void]
    public var isKnown: Bool { Self.all.contains(self) }
}

/// A CRM invoice as `GET /vendor/crm/invoices` returns it (`invoiceWriteSchema`, `services/crm.ts:102-113`, plus
/// `shape()`). Typed by hand in the WorkTrack console; not a HesabPay payment. `period`, `notes`, `createdBy` and
/// `updatedBy` cross the wire (the API has no field mask) but are not decoded, so they are never held.
public struct WTCrmInvoice: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var accountId: String
    public var number: String
    public var status: WTInvoiceStatus
    /// AFN (the field's name and the server's own sum, `crm.ts:106, 248-249`). A JSON number, not required to be whole.
    public var amountAfn: Decimal
    /// `YYYY-MM-DD`.
    public var issuedAt: String
    /// `YYYY-MM-DD`, or nil when absent or null (`nullish`).
    public var dueAt: String?
    public var paidAt: String?
    /// BANK, CASH, HAWALA or OTHER; nil when absent or null.
    public var method: String?

    public init(id: String, accountId: String, number: String, status: WTInvoiceStatus, amountAfn: Decimal, issuedAt: String,
                dueAt: String? = nil, paidAt: String? = nil, method: String? = nil) {
        self.id = id
        self.accountId = accountId
        self.number = number
        self.status = status
        self.amountAfn = amountAfn
        self.issuedAt = issuedAt
        self.dueAt = dueAt
        self.paidAt = paidAt
        self.method = method
    }

    private enum Keys: String, CodingKey { case id, accountId, number, status, amountAfn, issuedAt, dueAt, paidAt, method }

    /// The id, the account, the status and the amount are required: an invoice without them can't be counted, so it is
    /// set aside (and counted as such by `WTLossyList`), never read as 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        accountId = try c.decode(String.self, forKey: .accountId)
        number = try c.decodeIfPresent(String.self, forKey: .number) ?? ""
        status = try c.decode(WTInvoiceStatus.self, forKey: .status)
        // Through the number's shortest decimal text, so 1500.5 stays 1500.5 (Decimal's own decoding is not exact on
        // every Foundation).
        amountAfn = MoneyAmount.decimal(try c.decode(Double.self, forKey: .amountAfn))
        issuedAt = try c.decodeIfPresent(String.self, forKey: .issuedAt) ?? ""
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt)
        paidAt = try c.decodeIfPresent(String.self, forKey: .paidAt)
        method = try c.decodeIfPresent(String.self, forKey: .method)
    }
}

/// `ACCOUNT_STAGES` (`services/crm.ts:25-33`). A stored value outside the list is kept, not refused.
public struct WTAccountStage: WorkTrackCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let lead = WTAccountStage(rawValue: "LEAD")
    public static let contacted = WTAccountStage(rawValue: "CONTACTED")
    public static let demo = WTAccountStage(rawValue: "DEMO")
    public static let quoted = WTAccountStage(rawValue: "QUOTED")
    public static let won = WTAccountStage(rawValue: "WON")
    public static let lost = WTAccountStage(rawValue: "LOST")
    public static let dormant = WTAccountStage(rawValue: "DORMANT")
    /// In the server's order.
    public static let all: [WTAccountStage] = [.lead, .contacted, .demo, .quoted, .won, .lost, .dormant]
    public var isKnown: Bool { Self.all.contains(self) }
    /// Still being sold to: a missing next step is the owner's work.
    public var isOpen: Bool { [.lead, .contacted, .demo, .quoted].contains(self) }
}

/// `nextActionAt` as the server stores it. Its write schema checks only `^\d{4}-\d{2}-\d{2}$` (`crm.ts:48`), so
/// "2026-02-31" can be stored; a hand edit can store anything.
public enum WTCrmDay: Hashable, Sendable {
    /// Absent or null: no next step.
    case none
    /// A real Gregorian day, `YYYY-MM-DD` (`WorkTrackDates.parse`).
    case day(String)
    /// A string that is not a real day ("2026-02-31", "2026-1-5"): shown as it is, never guessed.
    case notADay(String)
    /// Present, but not a string.
    case unreadable

    public init(text: String) {
        self = WorkTrackDates.isValid(text) ? .day(text) : .notADay(text)
    }
}

/// A CRM account (`accountWriteSchema`, `services/crm.ts:36-51`): what links an invoice to a WorkTrack company (Money),
/// and the stage and next step Sales follows up on. `notes`, `city`, `industry`, `source`, `employeesEstimate`,
/// `createdBy`, `updatedBy`, `createdAt` and `updatedAt` cross the wire but are not decoded, so they are never held.
public struct WTCrmAccount: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The live tenant this account became (`crm.ts:39-40`); nil for a prospect or a customer handled by hand.
    public var companyId: String?
    /// Nil when absent, null or not a string ("stage unknown"); a string outside `ACCOUNT_STAGES` is kept.
    public var stage: WTAccountStage?
    public var nextActionAt: WTCrmDay
    /// The owner's own note for the next step (at most 200 characters, `crm.ts:49`), trimmed; nil when empty.
    public var nextAction: String?

    public init(id: String, name: String, companyId: String? = nil, stage: WTAccountStage? = nil, nextActionAt: WTCrmDay = .none,
                nextAction: String? = nil) {
        self.id = id
        self.name = name
        self.companyId = companyId
        self.stage = stage
        self.nextActionAt = nextActionAt
        self.nextAction = nextAction
    }

    private enum Keys: String, CodingKey { case id, name, companyId, stage, nextActionAt, nextAction }

    /// The id is required (a row without one is set aside and counted). Sales' fields never set a row aside: a value of
    /// the wrong type is "unknown" for that field only, so Money's count of rows set aside does not change.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let company = try c.decodeIfPresent(String.self, forKey: .companyId)?.trimmingCharacters(in: .whitespaces)
        companyId = company?.isEmpty == false ? company : nil
        stage = (try? c.decodeIfPresent(String.self, forKey: .stage)).map(WTAccountStage.init(rawValue:))
        if !c.contains(.nextActionAt) || ((try? c.decodeNil(forKey: .nextActionAt)) ?? false) {
            nextActionAt = .none
        } else if let text = try? c.decode(String.self, forKey: .nextActionAt) {
            nextActionAt = WTCrmDay(text: text)
        } else {
            nextActionAt = .unreadable
        }
        let note = (try? c.decodeIfPresent(String.self, forKey: .nextAction))?.trimmingCharacters(in: .whitespacesAndNewlines)
        nextAction = note?.isEmpty == false ? note : nil
    }
}

/// A list decoded one element at a time: a malformed document is counted in `skipped` instead of failing the whole read.
public struct WTLossyList<T: Decodable & Sendable>: Decodable, Sendable {
    public var rows: [T]
    public var skipped: Int

    public init(rows: [T], skipped: Int = 0) {
        self.rows = rows
        self.skipped = skipped
    }

    /// Decodes nothing, so a failed element can be stepped over.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var rows: [T] = []
        var skipped = 0
        while !c.isAtEnd {
            if let row = try? c.decode(T.self) {
                rows.append(row)
            } else {
                _ = try c.decode(Skip.self)
                skipped += 1
            }
        }
        self.rows = rows
        self.skipped = skipped
    }
}

extension WTLossyList: Equatable where T: Equatable {}

/// `PlanDef` (`services/plans.ts:40-51`), code defaults with stored price/cap overrides.
public struct WTPlanDef: Codable, Equatable, Sendable {
    public var id: WTPlan
    public var priceAfn: Double
    public var employeeLimit: Int
    public var deviceLimit: Int
    public var features: [String]
    public var purchasable: Bool
}

/// `GET /vendor/me`.
public struct WTVendorMe: Codable, Equatable, Sendable {
    public var uid: String
    public var email: String?
    public var vendor: Bool
}

/// Arbitrary JSON, for audit before/after values.
public enum WTJSON: Decodable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([WTJSON]), object([String: WTJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([WTJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: WTJSON].self)) }
    }

    /// Compact one-line rendering for display.
    public var compact: String {
        switch self {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): s
        case .array(let a): "[" + a.map(\.compact).joined(separator: ", ") + "]"
        case .object(let o): "{" + o.keys.sorted().map { "\($0): \(o[$0]!.compact)" }.joined(separator: ", ") + "}"
        }
    }

    /// Re-decodes this value as a licence, when it is one.
    public var asLicense: WTLicense? {
        guard case .object = self, let data = try? JSONEncoder().encode(EncodableJSON(self)) else { return nil }
        return try? JSONDecoder().decode(WTLicense.self, from: data)
    }

    private struct EncodableJSON: Encodable {
        let value: WTJSON
        init(_ v: WTJSON) { value = v }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch value {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): if n.rounded() == n && abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a.map(EncodableJSON.init))
            case .object(let o): try c.encode(o.mapValues(EncodableJSON.init))
            }
        }
    }
}

/// One `vendorAuditLogs` entry (`routes/vendor.ts:264-287`).
public struct WTAuditEntry: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var actorEmail: String?
    public var action: String
    public var companyId: String?
    public var before: WTJSON?
    public var after: WTJSON?
    public var at: String?
}

// MARK: - Licence write

/// The body of `PUT /vendor/companies/:id/license` (`licenseWriteSchema`, `services/license.ts:75-89`).
///
/// **Every key is always encoded**, `expiresAt` included. The server treats an omitted `expiresAt` (and an
/// explicit null) as *perpetual* (`setLicense` writes `input.expiresAt ?? null`, `license.ts:191`), so a body that
/// dropped the key would silently turn a renewal into a licence that never ends. The optional fields
/// (`enforcePlan`, `employeeLimit`, `extraFeatures`) are sent too, with the current values, so nothing depends on
/// the server's "omitted keeps current" rule. Build it only through `WorkTrackRenewal.makeWrite`.
public struct WTLicenseWrite: Encodable, Equatable, Sendable {
    public let plan: WTPlan
    public let deviceLimit: Int
    public let status: WTLicenseStatus
    /// nil only after an explicit, separately confirmed perpetual choice.
    public let expiresAt: String?
    public let enforceDevices: Bool
    public let enforcePlan: Bool
    public let employeeLimit: Int?
    public let extraFeatures: [String]

    init(plan: WTPlan, deviceLimit: Int, status: WTLicenseStatus, expiresAt: String?, enforceDevices: Bool,
         enforcePlan: Bool, employeeLimit: Int?, extraFeatures: [String]) {
        self.plan = plan
        self.deviceLimit = deviceLimit
        self.status = status
        self.expiresAt = expiresAt
        self.enforceDevices = enforceDevices
        self.enforcePlan = enforcePlan
        self.employeeLimit = employeeLimit
        self.extraFeatures = extraFeatures
    }

    private enum CodingKeys: String, CodingKey {
        case plan, deviceLimit, status, expiresAt, enforceDevices, enforcePlan, employeeLimit, extraFeatures
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(plan, forKey: .plan)
        try c.encode(deviceLimit, forKey: .deviceLimit)
        try c.encode(status, forKey: .status)
        // Never encodeIfPresent: the key must be in the body even for a perpetual licence.
        if let expiresAt { try c.encode(expiresAt, forKey: .expiresAt) } else { try c.encodeNil(forKey: .expiresAt) }
        try c.encode(enforceDevices, forKey: .enforceDevices)
        try c.encode(enforcePlan, forKey: .enforcePlan)
        if let employeeLimit { try c.encode(employeeLimit, forKey: .employeeLimit) } else { try c.encodeNil(forKey: .employeeLimit) }
        try c.encode(extraFeatures, forKey: .extraFeatures)
    }

    /// The licence the server should store after this write (`setLicense` with every field present).
    public var expectedLicense: WTLicense {
        WTLicense(plan: plan, deviceLimit: deviceLimit, status: status, expiresAt: expiresAt, enforceDevices: enforceDevices,
                  enforcePlan: enforcePlan, employeeLimit: employeeLimit, extraFeatures: extraFeatures, source: "VENDOR")
    }
}

// MARK: - Errors

public enum WorkTrackError: Error, LocalizedError, Equatable {
    case notSignedIn
    case auth(FirebaseAuthError)
    /// 401 from the API: token invalid, expired or revoked.
    case unauthenticated(String)
    /// 403 "Not permitted": the account has no `vendor` claim, or also carries a customer's claims.
    case notVendor
    /// 403 "Verify your email address first".
    case emailNotVerified
    case notFound(String)
    case validation(detail: String, fieldErrors: [String: String])
    case rateLimited
    case server(status: Int, code: String, detail: String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Not signed in to WorkTrack.")
        case .auth(let e): e.errorDescription
        case .unauthenticated: L("WorkTrack rejected the session (401): the token is invalid, expired or revoked. Sign in again.")
        case .notVendor: L("Signed in, but this account isn't a WorkTrack vendor account (403). The `vendor` claim is granted only with scripts/grant-vendor.ts, and a vendor account must not belong to any customer company.")
        case .emailNotVerified: L("WorkTrack requires a verified email for vendor access (403). grant-vendor.ts marks the address verified; run it for this account.")
        case .notFound(let detail): LF("Not found in WorkTrack (404): %@", detail)
        case .validation(let detail, let fields):
            fields.isEmpty ? LF("WorkTrack refused the request: %@", detail)
                : LF("WorkTrack refused the request: %1$@ (%2$@)", detail, fields.keys.sorted().map { "\($0): \(fields[$0]!)" }.joined(separator: "; "))
        case .rateLimited: L("WorkTrack is rate limiting requests. Wait a minute and try again.")
        case .server(let status, let code, let detail): LF("WorkTrack returned HTTP %1$ld %2$@: %3$@", status, code, detail)
        case .network(let message): LF("Couldn't reach WorkTrack: %@", message)
        case .decoding(let message): LF("WorkTrack answered in a form this app doesn't understand: %@", message)
        }
    }

    /// Whether signing in again is the fix.
    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .unauthenticated, .auth(.sessionExpired): true
        default: false
        }
    }

    /// RFC 7807 problem+json `{type, title, status, code, detail, fieldErrors?}` (`lib/errors.ts:75-91`).
    static func from(status: Int, data: Data) -> WorkTrackError {
        struct Problem: Decodable { let code: String?; let detail: String?; let fieldErrors: [String: String]? }
        let p = try? JSONDecoder().decode(Problem.self, from: data)
        let detail = p?.detail ?? (String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "")
        switch status {
        case 401: return .unauthenticated(detail)
        case 403: return detail.localizedCaseInsensitiveContains("verify your email") ? .emailNotVerified : .notVendor
        case 404: return .notFound(detail)
        case 400, 422: return .validation(detail: detail, fieldErrors: p?.fieldErrors ?? [:])
        case 429: return .rateLimited
        default: return .server(status: status, code: p?.code ?? "", detail: detail)
        }
    }
}

// MARK: - Client

/// The signed-in vendor session, as kept on this device: the refresh token only (Keychain), never the password
/// or the ID token. `environment` and `email` are kept beside it so the app knows what it is signed in to.
public struct WorkTrackStoredSession: Codable, Equatable, Sendable {
    public var environment: WorkTrackEnvironment
    public var email: String
    public var refreshToken: String

    public init(environment: WorkTrackEnvironment, email: String, refreshToken: String) {
        self.environment = environment
        self.email = email
        self.refreshToken = refreshToken
    }
}

/// Talks to one WorkTrack environment as the vendor. Holds the ID token in memory and refreshes it from the
/// refresh token. GET requests are retried once after a 401 (with a fresh token); the licence PUT never is.
public actor WorkTrackVendorClient {
    public nonisolated let environment: WorkTrackEnvironment
    private let auth: FirebaseAuthREST
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var tokens: FirebaseTokens?
    private var refreshToken: String?

    /// The default transport keeps nothing on disk: the CRM answers carry whole customer records (`notes`, names), and
    /// the shared URL cache would otherwise be free to store them.
    public init(environment: WorkTrackEnvironment, transport: HTTPTransport = URLSessionTransport(session: URLSessionTransport.uncached),
                now: @escaping @Sendable () -> Date = { .now }) {
        self.environment = environment
        self.transport = transport
        self.now = now
        self.auth = FirebaseAuthREST(endpoints: environment.auth, transport: transport, now: now)
    }

    /// Signs in with email and password. The password is not kept anywhere, including this actor.
    public func signIn(email: String, password: String) async throws -> WorkTrackStoredSession {
        do {
            let t = try await auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            tokens = t
            refreshToken = t.refreshToken
            return WorkTrackStoredSession(environment: environment, email: t.email ?? email, refreshToken: t.refreshToken)
        } catch let e as FirebaseAuthError { throw WorkTrackError.auth(e) }
        catch let e as URLError { throw WorkTrackError.network(e.localizedDescription) }
    }

    /// Resumes a stored session; the first request exchanges the refresh token for an ID token.
    public func restore(refreshToken: String) {
        self.refreshToken = refreshToken
        tokens = nil
    }

    /// The refresh token now in use (Firebase may hand back a new one on refresh).
    public var currentRefreshToken: String? { refreshToken }

    public func signOut() {
        tokens = nil
        refreshToken = nil
    }

    private func idToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = tokens, t.expiresAt.timeIntervalSince(now()) > 300 { return t.idToken }
        guard let refreshToken else { throw WorkTrackError.notSignedIn }
        do {
            let t = try await auth.refresh(refreshToken)
            tokens = t
            self.refreshToken = t.refreshToken
            return t.idToken
        } catch let e as FirebaseAuthError {
            if e == .sessionExpired { tokens = nil; self.refreshToken = nil }
            throw WorkTrackError.auth(e)
        } catch let e as URLError { throw WorkTrackError.network(e.localizedDescription) }
    }

    private func send(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil, retryOn401: Bool) async throws -> Data {
        var token = try await idToken()
        var attempt = 0
        while true {
            var request = URLRequest(url: Self.url(environment.apiBase, path, query: query))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 60
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) } catch let e as URLError {
                throw WorkTrackError.network(e.localizedDescription)
            }
            if (200..<300).contains(response.statusCode) { return data }
            if response.statusCode == 401, retryOn401, attempt == 0 {
                attempt += 1
                token = try await idToken(forceRefresh: true)
                continue
            }
            throw WorkTrackError.from(status: response.statusCode, data: data)
        }
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private func get<T: Decodable>(_ path: String..., query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, query: query, retryOn401: true)
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(Envelope<T>.self, from: data).data } catch let e as DecodingError {
            throw WorkTrackError.decoding(String(describing: e).prefix(300).description)
        }
    }

    // MARK: Reads (GET only)

    public func me() async throws -> WTVendorMe { try await get("vendor", "me") }
    public func companies() async throws -> [WTCompany] { try await get("vendor", "companies") }
    public func company(_ id: String) async throws -> WTCompany { try await get("vendor", "companies", id) }
    public func detail(_ id: String) async throws -> WTCompanyDetail { try await get("vendor", "companies", id, "detail") }
    public func orders(_ id: String) async throws -> [WTOrder] { try await get("vendor", "companies", id, "orders") }
    public func revenue() async throws -> WTRevenue { try await get("vendor", "revenue") }
    public func plans() async throws -> [String: WTPlanDef] { try await get("vendor", "plans") }
    public func audit() async throws -> [WTAuditEntry] { try await get("vendor", "audit") }
    /// `GET /vendor/crm/accounts`, every account (at most 2000, `crm.ts:204`), no `accountId` filter.
    public func crmAccounts() async throws -> WTLossyList<WTCrmAccount> { try await get("vendor", "crm", "accounts") }
    /// `GET /vendor/crm/invoices`, every invoice (at most 2000, no order, no cursor), no `accountId` filter.
    public func crmInvoices() async throws -> WTLossyList<WTCrmInvoice> { try await get("vendor", "crm", "invoices") }
    /// `GET /vendor/crm/contacts?accountId=<id>`: one account's contacts (`routes/vendor.ts:339-345`, `crm.ts:198-206`).
    /// An empty id is refused here, before any request: the server reads an empty `accountId` as no filter and would
    /// answer every contact of every account.
    public func crmContacts(accountId: String) async throws -> WTLossyList<WTCrmContactRef> {
        let id = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw WorkTrackError.validation(detail: L("No CRM account was given, so no contacts were asked for."), fieldErrors: [:])
        }
        return try await get("vendor", "crm", "contacts", query: [URLQueryItem(name: "accountId", value: id)])
    }
    /// The same `GET /vendor/crm/accounts`, kept only as key names, JSON types and counts (`WTShapeReport`): every value
    /// is dropped here. The owner's one check of what the server really sends.
    public func crmAccountsShape() async throws -> WTShapeReport {
        let rows: [WTJSON] = try await get("vendor", "crm", "accounts")
        return WTShapeReport(rows: rows, readAt: now())
    }

    // MARK: Write

    /// `PUT /vendor/companies/:id/license`. Sent once, never retried. Returns the licence the server stored.
    public func putLicense(companyID: String, _ write: WTLicenseWrite) async throws -> WTLicense {
        let body = try JSONEncoder().encode(write)
        let data = try await send("PUT", ["vendor", "companies", companyID, "license"], body: body, retryOn401: false)
        return try decode(WTLicense.self, from: data)
    }

    /// `base` plus each component as exactly one path segment (a "/" inside a company id is escaped), and the query with
    /// every value percent-encoded except ASCII letters, digits and `-._~`: a `+`, `&`, `=` or `/` in an id can't change
    /// the query (Express would read a raw `+` as a space).
    static func url(_ base: URL, _ components: [String], query: [URLQueryItem] = []) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let path = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let text = query.map { item in
            [item.name, item.value ?? ""].map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }.joined(separator: "=")
        }.joined(separator: "&")
        return URL(string: base.absoluteString + "/" + path + (text.isEmpty ? "" : "?" + text))!
    }
}

// MARK: - Money reads

/// Everything Money asks WorkTrack for: three GETs. `putLicense` and every CRM write are deliberately not here, so code
/// handed this protocol can only read.
public protocol WorkTrackMoneyReading: Sendable {
    func revenue() async throws -> WTRevenue
    func crmAccounts() async throws -> WTLossyList<WTCrmAccount>
    func crmInvoices() async throws -> WTLossyList<WTCrmInvoice>
}

extension WorkTrackVendorClient: WorkTrackMoneyReading {}

// MARK: - Sales reads

/// What Sales asks WorkTrack for beyond Money's reading (which it reuses): two GETs, each made only when the owner asks.
/// No write and no other CRM route, so code handed this protocol can only read.
public protocol WorkTrackSalesReading: Sendable {
    func crmContacts(accountId: String) async throws -> WTLossyList<WTCrmContactRef>
    func crmAccountsShape() async throws -> WTShapeReport
}

extension WorkTrackVendorClient: WorkTrackSalesReading {}

/// One reading of WorkTrack's money: each part with its own time or its own failure.
public struct WorkTrackMoneyRead: Sendable, Equatable {
    public var revenue: MoneyRead<WTRevenue>
    public var accounts: MoneyRead<WTLossyList<WTCrmAccount>>
    public var invoices: MoneyRead<WTLossyList<WTCrmInvoice>>

    public init(revenue: MoneyRead<WTRevenue>, accounts: MoneyRead<WTLossyList<WTCrmAccount>>, invoices: MoneyRead<WTLossyList<WTCrmInvoice>>) {
        self.revenue = revenue
        self.accounts = accounts
        self.invoices = invoices
    }

    /// WorkTrack no longer accepts the session: signing in again is the fix.
    public var needsSignIn: Bool { revenue.needsSignIn || accounts.needsSignIn || invoices.needsSignIn }

    /// The failed parts, for the automation run note; nil when all three were read.
    public var failure: String? {
        let parts = [(L("revenue"), revenue.failure), (L("CRM accounts"), accounts.failure), (L("CRM invoices"), invoices.failure)]
            .compactMap { name, message in message.map { "\(name): \($0)" } }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

public enum WorkTrackMoneyReader {
    /// Revenue, then the CRM accounts, then the invoices, one at a time: concurrent calls could race the client's token
    /// refresh (actor methods interleave at `await`). Each part keeps its own failure. Once WorkTrack refuses the session,
    /// the parts after it are not requested; they carry the same failure.
    public static func read(_ source: some WorkTrackMoneyReading, now: () -> Date = { .now }) async -> WorkTrackMoneyRead {
        var refused: (message: String, at: Date)?
        func part<T: Sendable>(_ call: () async throws -> T) async -> MoneyRead<T> {
            if let refused { return .failed(refused.message, at: refused.at, needsSignIn: true) }
            do {
                let value = try await call()
                return .read(value, at: now())
            } catch {
                let needsSignIn = (error as? WorkTrackError)?.needsSignIn ?? false
                let at = now()
                if needsSignIn { refused = (error.localizedDescription, at) }
                return .failed(error.localizedDescription, at: at, needsSignIn: needsSignIn)
            }
        }
        let revenue = await part { try await source.revenue() }
        let accounts = await part { try await source.crmAccounts() }
        let invoices = await part { try await source.crmInvoices() }
        return WorkTrackMoneyRead(revenue: revenue, accounts: accounts, invoices: invoices)
    }
}
