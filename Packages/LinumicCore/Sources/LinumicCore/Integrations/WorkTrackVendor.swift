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
// Only fields the app shows are decoded; unknown fields are ignored.

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

    public init(environment: WorkTrackEnvironment, transport: HTTPTransport = URLSessionTransport(),
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

    private func send(_ method: String, _ path: [String], body: Data? = nil, retryOn401: Bool) async throws -> Data {
        var token = try await idToken()
        var attempt = 0
        while true {
            var request = URLRequest(url: Self.url(environment.apiBase, path))
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

    private func get<T: Decodable>(_ path: String..., as: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, retryOn401: true)
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

    // MARK: Write

    /// `PUT /vendor/companies/:id/license`. Sent once, never retried. Returns the licence the server stored.
    public func putLicense(companyID: String, _ write: WTLicenseWrite) async throws -> WTLicense {
        let body = try JSONEncoder().encode(write)
        let data = try await send("PUT", ["vendor", "companies", companyID, "license"], body: body, retryOn401: false)
        return try decode(WTLicense.self, from: data)
    }

    /// `base` plus each component as exactly one path segment (a "/" inside a company id is escaped).
    static func url(_ base: URL, _ components: [String]) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let path = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        return URL(string: base.absoluteString + "/" + path)!
    }
}
