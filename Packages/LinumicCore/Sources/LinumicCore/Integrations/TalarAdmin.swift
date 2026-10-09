import Foundation

// Talar platform admin API (`/v1/admin/*`), read-only, plus the one audited write the owner may send from here:
// approve or reject a hall in the review queue.
//
// Source of every route and schema: the Talar repository at origin/main @ 7989747 (2026-10-09; main = production),
//   backend/functions/src/index.ts                 routes under /v1, admin router at /v1/admin
//   backend/functions/src/modules/admin/routes.ts  dashboard, halls/pending, halls/:id/review (audited), reviews
//   backend/functions/src/lib/auth.ts              custom claim role == "admin", checkRevoked on the admin router
//   backend/functions/src/lib/errors.ts            {"error":{code,message,details,requestId}}
//   backend/functions/src/lib/audit.ts             auditLogs entry per admin write (best-effort, failures swallowed)
//   backend/functions/src/modules/halls/routes.ts  hall fields (hallSchema)
//   backend/functions/src/modules/payments/routes.ts + payouts.ts  GET /orgs/:orgId/payments/payouts, payout fields
//   backend/firestore.rules                        admins may read organizations (used to list them for payouts)
//   web/.env.production, web/.env.demo             public Firebase Web API keys and project ids
// Never called from here: payouts/run, payouts/:org/:id/mark-paid (they move money and are not idempotent),
// reviews/moderate, cities, coupons, featured, bootstrap.

// MARK: - Environment

public enum TalarEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case production
    /// `talar-demo-af`, the public demo sandbox. It runs older code than production (research 2026-10-08).
    case demo
    /// The Firebase Emulator Suite on this Mac (`--project demo-talar`). Offered in debug builds only.
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

    public static func offered(includeEmulator: Bool) -> [TalarEnvironment] {
        includeEmulator ? allCases : [.production, .demo]
    }

    /// `…/api/v1`. Source: `VITE_API_BASE_URL` in web/.env.production and web/.env.demo; region asia-south1 (index.ts).
    public var apiBase: URL {
        switch self {
        case .production: URL(string: "https://asia-south1-talar-af-prod.cloudfunctions.net/api/v1")!
        case .demo: URL(string: "https://asia-south1-talar-demo-af.cloudfunctions.net/api/v1")!
        case .localEmulator: URL(string: "http://127.0.0.1:5001/demo-talar/asia-south1/api/v1")!
        }
    }

    /// Public Web API keys (`VITE_FIREBASE_API_KEY`, web/.env.production:2 and web/.env.demo:4). Not secrets.
    /// Emulator ports from backend/firebase.json (auth 9099, firestore 8080).
    public var auth: FirebaseAuthEndpoints {
        switch self {
        case .production: .google(apiKey: "AIzaSyAGmrTJdgilhXlqtcCvxkh021NDLYBgoAs")
        case .demo: .google(apiKey: "AIzaSyAANADfJ2OkZaQvOXvmPLawWjoU2sFCyic")
        case .localEmulator: .emulator(host: "127.0.0.1", port: 9099, apiKey: "demo-key")
        }
    }

    public var firestore: FirestoreEndpoint {
        switch self {
        case .production: .google(project: "talar-af-prod")
        case .demo: .google(project: "talar-demo-af")
        case .localEmulator: .emulator(host: "127.0.0.1", port: 8080, project: "demo-talar")
        }
    }

    /// The web panel's admin page, for every action. Production: desktop/main.js PANEL_URL + the `/admin` route
    /// (web/src/App.tsx); answered 200 on 2026-10-09. The demo project's Hosting answered 404, so no link.
    public var adminPanel: URL? {
        switch self {
        case .production: URL(string: "https://talar-af-prod.web.app/admin")!
        case .demo, .localEmulator: nil
        }
    }
}

// MARK: - Models

/// A Firestore Timestamp as Express serialises it (`{"_seconds","_nanoseconds"}`), or an ISO string, or null.
public struct TalarTimestamp: Decodable, Equatable, Sendable {
    public let date: Date

    public init(date: Date) { self.date = date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        struct Raw: Decodable { let _seconds: Double; let _nanoseconds: Double? }
        if let raw = try? c.decode(Raw.self) {
            date = Date(timeIntervalSince1970: raw._seconds + (raw._nanoseconds ?? 0) / 1e9)
        } else if let text = try? c.decode(String.self), let d = FirestoreValue.parseTimestamp(text) {
            date = d
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a timestamp")
        }
    }
}

/// `{fa, ps, en, ar}` names. Shows the language asked for, then Dari, English, Pashto.
public struct TalarLocalized: Decodable, Equatable, Sendable {
    public let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public init(from decoder: Decoder) throws {
        values = (try? decoder.singleValueContainer().decode([String: String].self)) ?? [:]
    }

    public func best(preferring language: String? = Locale.current.language.languageCode?.identifier) -> String {
        for key in [language, "fa", "en", "ps", "ar"].compactMap({ $0 }) {
            if let v = values[key], !v.isEmpty { return v }
        }
        return values.values.first ?? ""
    }
}

/// `GET /admin/dashboard` (admin/routes.ts:69-85).
public struct TalarDashboard: Codable, Equatable, Sendable {
    public var publishedHalls: Int
    public var hallsAwaitingReview: Int
    public var confirmedBookings: Int
    public var openTickets: Int
}

/// A hall from `GET /admin/halls/pending` (`{id, …hallDoc}`; fields from halls/routes.ts hallSchema).
public struct TalarHall: Decodable, Equatable, Sendable, Identifiable {
    public struct Capacity: Decodable, Equatable, Sendable { public var total: Int; public var mens: Int?; public var womens: Int? }
    public struct RefundRule: Decodable, Equatable, Sendable { public var minDaysBefore: Int; public var refundPct: Int }

    public var id: String
    public var name: TalarLocalized
    public var status: String
    public var cityId: String?
    public var district: String?
    public var hallType: String?
    public var capacity: Capacity?
    public var shifts: [String]
    public var amenities: [String]
    public var hallFeeMinor: Int?
    public var currency: String?
    public var depositPct: Int?
    public var instantBooking: Bool?
    public var refundRules: [RefundRule]
    public var orgId: String?
    public var createdAt: TalarTimestamp?

    private enum Keys: String, CodingKey {
        case id, name, status, cityId, district, hallType, capacity, shifts, amenities, hallFeeMinor, currency, depositPct, instantBooking, refundRules, orgId, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(TalarLocalized.self, forKey: .name) ?? TalarLocalized([:])
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        cityId = try c.decodeIfPresent(String.self, forKey: .cityId)
        district = try c.decodeIfPresent(String.self, forKey: .district)
        hallType = try c.decodeIfPresent(String.self, forKey: .hallType)
        capacity = try? c.decodeIfPresent(Capacity.self, forKey: .capacity)
        shifts = (try? c.decodeIfPresent([String].self, forKey: .shifts)) ?? []
        amenities = (try? c.decodeIfPresent([String].self, forKey: .amenities)) ?? []
        hallFeeMinor = try? c.decodeIfPresent(Int.self, forKey: .hallFeeMinor)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        depositPct = try? c.decodeIfPresent(Int.self, forKey: .depositPct)
        instantBooking = try? c.decodeIfPresent(Bool.self, forKey: .instantBooking)
        refundRules = (try? c.decodeIfPresent([RefundRule].self, forKey: .refundRules)) ?? []
        orgId = try c.decodeIfPresent(String.self, forKey: .orgId)
        createdAt = try? c.decodeIfPresent(TalarTimestamp.self, forKey: .createdAt)
    }
}

/// A review from `GET /admin/reviews` (admin/routes.ts:220-237): pending, newest first, up to 50.
public struct TalarReview: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var hallId: String?
    public var rating: Int
    public var aspects: [String: Int]
    public var text: String?
    public var status: String
    public var createdAt: TalarTimestamp?

    private enum Keys: String, CodingKey { case id, hallId, rating, aspects, text, status, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        hallId = try c.decodeIfPresent(String.self, forKey: .hallId)
        rating = (try? c.decodeIfPresent(Int.self, forKey: .rating)) ?? 0
        aspects = (try? c.decodeIfPresent([String: Int].self, forKey: .aspects)) ?? [:]
        text = try c.decodeIfPresent(String.self, forKey: .text)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try? c.decodeIfPresent(TalarTimestamp.self, forKey: .createdAt)
    }
}

/// An organisation (hall owner), from Firestore `organizations` (users/routes.ts:94-103).
public struct TalarOrganization: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var status: String
    public var commissionPct: Double?

    public init(id: String, name: String, status: String, commissionPct: Double?) {
        self.id = id
        self.name = name
        self.status = status
        self.commissionPct = commissionPct
    }

    init(_ doc: FirestoreDocument) {
        self.init(id: doc.id, name: doc["name"]?.string ?? doc.id, status: doc["status"]?.string ?? "", commissionPct: doc["commissionPct"]?.number)
    }
}

/// A settlement from `GET /orgs/:orgId/payments/payouts` (payouts.ts runSettlementForOrg / markPayoutPaid).
public struct TalarPayout: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var periodTo: String?
    public var grossMinor: Int
    public var commissionMinor: Int
    public var commissionPct: Double?
    public var netMinor: Int
    public var currency: String
    public var paymentCount: Int
    /// `pending` or `paid`.
    public var status: String
    public var createdAt: TalarTimestamp?
    public var paidAt: TalarTimestamp?

    private enum Keys: String, CodingKey { case id, periodTo, grossMinor, commissionMinor, commissionPct, netMinor, currency, paymentIds, status, createdAt, paidAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        periodTo = try c.decodeIfPresent(String.self, forKey: .periodTo)
        grossMinor = (try? c.decodeIfPresent(Int.self, forKey: .grossMinor)) ?? 0
        commissionMinor = (try? c.decodeIfPresent(Int.self, forKey: .commissionMinor)) ?? 0
        commissionPct = try? c.decodeIfPresent(Double.self, forKey: .commissionPct)
        netMinor = (try? c.decodeIfPresent(Int.self, forKey: .netMinor)) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "AFN"
        paymentCount = ((try? c.decodeIfPresent([String].self, forKey: .paymentIds)) ?? []).count
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try? c.decodeIfPresent(TalarTimestamp.self, forKey: .createdAt)
        paidAt = try? c.decodeIfPresent(TalarTimestamp.self, forKey: .paidAt)
    }

    public var isPending: Bool { status == "pending" }
}

/// One organisation's settlements, as read.
public struct TalarOrgPayouts: Equatable, Sendable, Identifiable {
    public var organization: TalarOrganization
    public var payouts: [TalarPayout]
    /// Set when this organisation's list couldn't be read (the others still show).
    public var error: String?
    public var id: String { organization.id }

    public init(organization: TalarOrganization, payouts: [TalarPayout], error: String? = nil) {
        self.organization = organization
        self.payouts = payouts
        self.error = error
    }

    public var pending: [TalarPayout] { payouts.filter(\.isPending) }
}

/// Settlement status across organisations.
public struct TalarPayoutSummary: Equatable, Sendable {
    public let pendingCount: Int
    public let pendingNetMinor: Int
    public let organizationsWithPending: Int
    public let organizationsRead: Int
    public let organizationsFailed: Int
    /// More active organisations exist than were read (the list is capped).
    public let truncated: Bool

    public init(_ rows: [TalarOrgPayouts], truncated: Bool) {
        pendingCount = rows.reduce(0) { $0 + $1.pending.count }
        pendingNetMinor = rows.reduce(0) { $0 + $1.pending.reduce(0) { $0 + $1.netMinor } }
        organizationsWithPending = rows.filter { !$0.pending.isEmpty }.count
        organizationsRead = rows.filter { $0.error == nil }.count
        organizationsFailed = rows.filter { $0.error != nil }.count
        self.truncated = truncated
    }
}

/// Talar money is integer minor units, 100 to the afghani/dollar (web/src/lib/format.ts formatMoney).
public enum TalarMoney {
    public static func format(_ minor: Int, currency: String) -> String {
        let major = (Double(minor) / 100).formatted(.number.precision(.fractionLength(0)))
        return currency == "USD" ? "$\(major)" : "\(major) AFN"
    }
}

// MARK: - Hall review (the one write)

public enum TalarHallDecision: String, Codable, Sendable, CaseIterable, Identifiable {
    case approve, reject
    public var id: String { rawValue }
}

/// The body of `POST /admin/halls/:hallId/review` (`{decision, reason?: ≤500}`, strict).
public struct TalarHallReviewWrite: Encodable, Equatable, Sendable {
    public let decision: TalarHallDecision
    public let reason: String?

    public static let maxReason = 500

    /// Trims the reason, drops it when empty, refuses one over 500 characters (the server's limit).
    public static func make(decision: TalarHallDecision, reason: String) throws -> TalarHallReviewWrite {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.count <= maxReason else { throw TalarError.validation(LF("The reason is %ld characters; Talar accepts at most 500.", r.count)) }
        return TalarHallReviewWrite(decision: decision, reason: r.isEmpty ? nil : r)
    }

    private enum CodingKeys: String, CodingKey { case decision, reason }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(decision, forKey: .decision)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

// MARK: - Errors

public enum TalarError: Error, LocalizedError, Equatable {
    case notSignedIn
    case auth(FirebaseAuthError)
    /// 401: token invalid, expired or revoked.
    case unauthenticated
    /// 403, or the token has no `role: "admin"` claim.
    case notAdmin
    case notFound(String)
    /// 409, e.g. "Hall is not awaiting review".
    case conflict(String)
    case validation(String)
    case rateLimited
    case server(status: Int, code: String, message: String)
    case network(String)
    case decoding(String)
    case firestore(FirestoreError)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Not signed in to Talar.")
        case .auth(let e): e.errorDescription
        case .unauthenticated: L("Talar rejected the session (401): the token is invalid, expired or revoked. Sign in again.")
        case .notAdmin: L("Signed in, but this account isn't a Talar platform admin (no role \"admin\" claim, or 403). The claim is set once by /v1/admin/bootstrap or an Admin SDK script; an account that owns or joins an organisation loses it.")
        case .notFound(let m): LF("Not found in Talar (404): %@", m)
        case .conflict(let m): LF("Talar refused it (409): %@", m)
        case .validation(let m): LF("Talar refused the request: %@", m)
        case .rateLimited: L("Talar is rate limiting requests. Wait a minute and try again.")
        case .server(let status, let code, let m): LF("Talar returned HTTP %1$ld %2$@: %3$@", status, code, m)
        case .network(let m): LF("Couldn't reach Talar: %@", m)
        case .decoding(let m): LF("Talar answered in a form this app doesn't understand: %@", m)
        case .firestore(let e): e.errorDescription
        }
    }

    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .unauthenticated, .auth(.sessionExpired), .firestore(.unauthenticated): true
        default: false
        }
    }

    /// `{"error":{"code","message","details","requestId"}}` (lib/errors.ts:80-91).
    static func from(status: Int, data: Data) -> TalarError {
        struct Envelope: Decodable { struct Inner: Decodable { let code: String?; let message: String? }; let error: Inner? }
        let e = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let message = e?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch status {
        case 401: return .unauthenticated
        case 403: return .notAdmin
        case 404: return .notFound(message)
        case 409: return .conflict(message)
        case 400, 422: return .validation(message)
        case 429: return .rateLimited
        default: return .server(status: status, code: e?.code ?? "", message: message)
        }
    }
}

// MARK: - Client

/// The admin session kept on this device: the refresh token only (Keychain), never the password or the ID token.
public struct TalarStoredSession: Codable, Equatable, Sendable {
    public var environment: TalarEnvironment
    public var email: String
    public var refreshToken: String

    public init(environment: TalarEnvironment, email: String, refreshToken: String) {
        self.environment = environment
        self.email = email
        self.refreshToken = refreshToken
    }
}

public actor TalarAdminClient {
    public nonisolated let environment: TalarEnvironment
    private let session: FirebaseSession
    private let firestore: FirestoreREST
    private let transport: HTTPTransport
    /// At most this many organisations are read for the settlement overview (one request each).
    public static let organizationLimit = 50

    public init(environment: TalarEnvironment, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.environment = environment
        self.transport = transport
        session = FirebaseSession(auth: FirebaseAuthREST(endpoints: environment.auth, transport: transport, now: now), now: now)
        firestore = FirestoreREST(endpoint: environment.firestore, transport: transport)
    }

    /// Signs in and checks the ID token carries `role: "admin"` (lib/auth.ts). The password is not kept.
    public func signIn(email: String, password: String) async throws -> TalarStoredSession {
        let tokens: FirebaseTokens
        do { tokens = try await session.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
        catch let e as FirebaseAuthError { throw TalarError.auth(e) }
        catch let e as URLError { throw TalarError.network(e.localizedDescription) }
        guard Self.isAdmin(idToken: tokens.idToken) else {
            await session.signOut()
            throw TalarError.notAdmin
        }
        return TalarStoredSession(environment: environment, email: tokens.email ?? email, refreshToken: tokens.refreshToken)
    }

    /// `role == "admin"` in the token payload. The server checks this itself on every request.
    public static func isAdmin(idToken: String) -> Bool {
        (JWTClaims.payload(idToken)?["role"] as? String) == "admin"
    }

    public func restore(refreshToken: String) async { await session.restore(refreshToken: refreshToken) }
    public func signOut() async { await session.signOut() }
    public var currentRefreshToken: String? { get async { await session.currentRefreshToken } }

    private func token(forceRefresh: Bool = false) async throws -> String {
        do { return try await session.idToken(forceRefresh: forceRefresh) }
        catch let e as FirebaseAuthError { throw TalarError.auth(e) }
        catch let e as URLError { throw TalarError.network(e.localizedDescription) }
    }

    private func send(_ method: String, _ path: [String], body: Data? = nil, retryOn401: Bool) async throws -> Data {
        var token = try await token()
        var attempt = 0
        while true {
            var request = URLRequest(url: WorkTrackVendorClient.url(environment.apiBase, path))
            request.httpMethod = method
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) } catch let e as URLError { throw TalarError.network(e.localizedDescription) }
            if (200..<300).contains(response.statusCode) { return data }
            if response.statusCode == 401, retryOn401, attempt == 0 {
                attempt += 1
                token = try await self.token(forceRefresh: true)
                continue
            }
            throw TalarError.from(status: response.statusCode, data: data)
        }
    }

    private func get<T: Decodable>(_ path: String..., as: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, retryOn401: true)
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw TalarError.decoding(String(describing: error).prefix(300).description)
        }
    }

    private struct Items<T: Decodable>: Decodable { let items: [T] }

    // MARK: Reads

    public func dashboard() async throws -> TalarDashboard { try await get("admin", "dashboard") }
    public func pendingHalls() async throws -> [TalarHall] { try await get("admin", "halls", "pending", as: Items<TalarHall>.self).items }
    public func pendingReviews() async throws -> [TalarReview] { try await get("admin", "reviews", as: Items<TalarReview>.self).items }
    public func payouts(organizationID: String) async throws -> [TalarPayout] {
        try await get("orgs", organizationID, "payments", "payouts", as: Items<TalarPayout>.self).items
    }

    /// Organisations from Firestore (admins may read them, firestore.rules `organizations`), one page of up to 300.
    public func organizations() async throws -> [TalarOrganization] {
        let token = try await token()
        do {
            return try await firestore.list("organizations", mask: ["name", "status", "commissionPct"], pageSize: 300, token: token)
                .map(TalarOrganization.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let e as FirestoreError { throw TalarError.firestore(e) }
    }

    /// Every active organisation's settlements (capped at `organizationLimit`). One organisation failing doesn't
    /// hide the others; it is reported on its row.
    public func payoutOverview() async throws -> (rows: [TalarOrgPayouts], truncated: Bool) {
        let active = try await organizations().filter { $0.status == "active" }
        var rows: [TalarOrgPayouts] = []
        for org in active.prefix(Self.organizationLimit) {
            do { rows.append(TalarOrgPayouts(organization: org, payouts: try await payouts(organizationID: org.id))) }
            catch let e as TalarError where e.needsSignIn { throw e }
            catch { rows.append(TalarOrgPayouts(organization: org, payouts: [], error: error.localizedDescription)) }
        }
        return (rows, active.count > Self.organizationLimit)
    }

    // MARK: The one write

    /// `POST /admin/halls/:hallId/review`. Sent once and never retried, not even after a 401. Talar refuses it
    /// with 409 unless the hall is still `pending_review`, and writes `hall.review_approve|reject` to auditLogs.
    public func reviewHall(_ hallID: String, _ write: TalarHallReviewWrite) async throws {
        let body = try JSONEncoder().encode(write)
        _ = try await send("POST", ["admin", "halls", hallID, "review"], body: body, retryOn401: false)
    }
}
