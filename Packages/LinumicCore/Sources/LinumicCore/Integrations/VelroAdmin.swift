import Foundation

// VELRO operations API (`/api/v1`), read-only, signed in as staff with a phone OTP.
//
// Source of every route and schema: the Velro repository at main @ b9891a3 (2026-10-09),
//   backend/ui/api/routers/auth.py + schemas/auth.py   otp/request (audience "staff"), otp/verify, refresh
//   backend/application/use_cases/authenticate.py      RefreshSession: rotate on every use; a replayed (already
//                                                      rotated) token revokes every session of that user
//   backend/shared/config.py                           access token 900 s, refresh token 180 days
//   backend/ui/api/deps.py:544-579                     require_staff / require_admin / require_operations
//   backend/ui/api/errors.py                           {success,data,message,meta} / {success:false,error:{code,…}}
//   backend/ui/api/routers/admin.py                    dashboard, drivers, trips, stations, routes, settings
//   backend/ui/api/opscentre.py:229-510                the dashboard snapshot's sections
//   backend/ui/api/routers/documents.py:311-322        a driver's document checklist (statuses only, no files)
//   backend/infrastructure/services/settings.py:24     commission.rate_basis_points, default 1000 (10 %)
//
// Why a port and not a dependency on VELRO's own `ios/VelroCore` package: VelroCore lives in another private
// repository with no licence file and no published package, so depending on it would tie Linumic OS's build to a
// checkout of the Velro repository at a fixed path. Its `APIClient` is bound to URLSession (no injectable transport
// for this app's fixture tests), its `KeychainSessionStore` uses its own Keychain service with AfterFirstUnlock and a
// "first launch wipes" marker, and the package exposes every write (approve, suspend, settings PATCH, delete
// account). This file ports only the read calls and VelroCore's single-refresh rule (APIClient.swift
// RefreshCoordinator), so the read-only promise holds by construction. Never wired: DELETE /auth/me, any POST or
// PATCH under /admin.

// MARK: - Environment

public enum VelroEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The only deployed backend: VELRO has no staging (every deploy is production).
    case production
    /// A backend on this Mac (`backend/scripts/dev-api.sh`, port 8000). Offered in debug builds only.
    case localBackend

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .production: L("Production")
        case .localBackend: L("Local backend")
        }
    }

    public var isProduction: Bool { self == .production }

    public static func offered(includeLocal: Bool) -> [VelroEnvironment] {
        includeLocal ? allCases : [.production]
    }

    /// Production: deploy/Caddyfile and the research live check (`/healthz` 200 on 2026-10-09).
    /// Local: README "Getting started" (`dev-api.sh`, the API on :8000), VelroOps Debug (`ios/project.yml:259`).
    public var apiBase: URL {
        switch self {
        case .production: URL(string: "https://api.velro.linumic.com/api/v1")!
        case .localBackend: URL(string: "http://127.0.0.1:8000/api/v1")!
        }
    }

    /// The staff web console (deploy/Caddyfile), for every action; answered 200 on 2026-10-09.
    public var adminPanel: URL? {
        switch self {
        case .production: URL(string: "https://admin.velro.linumic.com")!
        case .localBackend: nil
        }
    }
}

// MARK: - Roles

public enum VelroRoles {
    /// `domain/identity.py` STAFF_ROLES.
    public static let staff: Set<String> = ["SUPER_ADMIN", "ADMIN", "OPERATIONS_MANAGER", "DISPATCHER", "FINANCE_MANAGER", "SUPPORT_AGENT"]
    /// `require_admin`: needed for GET /admin/settings (the commission).
    public static let admin: Set<String> = ["SUPER_ADMIN", "ADMIN"]
    /// `require_operations`: needed for a driver's document checklist.
    public static let operations: Set<String> = ["SUPER_ADMIN", "ADMIN", "OPERATIONS_MANAGER", "DISPATCHER"]

    public static func isStaff(_ roles: [String]) -> Bool { !staff.isDisjoint(with: roles) }
}

// MARK: - Models

/// `POST /auth/otp/request` (schemas/auth.py RequestOtpOut).
public struct VelroOtpSent: Decodable, Equatable, Sendable {
    public var expiresInSeconds: Int
    public var resendAfterSeconds: Int
    /// What actually carried the code (sms, telegram or email).
    public var channel: String?
    /// Only a development backend with echo on sends this; production never does.
    public var debugCode: String?
}

/// `SessionOut` from verify and refresh.
struct VelroSessionReply: Decodable, Sendable {
    let userId: String
    let accessToken: String
    let refreshToken: String
    let roles: [String]
    let isNewUser: Bool?
    let expiresInSeconds: Int?
}

/// `GET /admin/dashboard`: only the sections Linumic OS shows (opscentre.snapshot).
public struct VelroDashboard: Decodable, Equatable, Sendable {
    public struct Live: Decodable, Equatable, Sendable { public var onTheWay: Int; public var atTheStation: Int; public var moving: Int; public var departingSoon: Int }
    public struct Attention: Decodable, Equatable, Sendable {
        public var unassignedTrips: Int
        public var overdueTrips: Int
        public var pendingDrivers: Int
        public var pendingVehicles: Int
        public var pendingDocuments: Int
        public var expiringDocuments: Int
        public var openTickets: Int
    }
    public struct Today: Decodable, Equatable, Sendable {
        public var trips: Int
        public var bookings: Int
        public var completedTrips: Int
        public var cancellations: Int
        public var seatsCapacity: Int
        public var seatsSold: Int
        public var utilisationPercent: Int?
    }
    public struct Drivers: Decodable, Equatable, Sendable { public var online: Int; public var onTrip: Int; public var offline: Int; public var pending: Int; public var suspended: Int; public var total: Int }
    public struct Finance: Decodable, Equatable, Sendable {
        public var currency: String
        public var revenueTodayMinor: Int
        public var commissionTodayMinor: Int
        public var cashOwedMinor: Int
        public var payoutsDueMinor: Int
        public var settlementsOpen: Int
    }
    public struct Network: Decodable, Equatable, Sendable { public var routesActive: Int; public var stations: Int; public var villages: Int; public var stationsWithoutRoutes: Int }

    public var generatedAt: String?
    public var live: Live
    public var attention: Attention
    public var today: Today
    public var drivers: Drivers
    public var finance: Finance
    public var network: Network

    /// Trips assigned and under way right now (opscentre ON_THE_WAY + AT_THE_STATION + MOVING).
    public var activeTrips: Int { live.onTheWay + live.atTheStation + live.moving }
}

/// A driver from `GET /admin/drivers` (DriverAdminOut). The phone number the API also returns is not decoded.
public struct VelroDriver: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var fullName: String?
    public var approvalStatus: String
    public var availability: String?
    public var completedTrips: Int?
    public var plateNumber: String?
    public var vehicleStatus: String?
}

/// `GET /admin/drivers/{id}/documents`: which documents are verified, missing or waiting. Never the files.
public struct VelroDocumentChecklist: Decodable, Equatable, Sendable {
    public struct Document: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var documentTypeCode: String
        public var status: String
        public var expiresOn: String?
        public var rejectionReason: String?
        public var uploadedAt: String?
        public var isCurrent: Bool?
    }
    public var required: [String]
    public var missing: [String]
    public var documents: [Document]
    public var approvalStatus: String
    public var canWork: Bool
}

/// A trip from `GET /admin/trips` (TripAdminOut). The driver's phone is not decoded.
public struct VelroTrip: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var number: String
    public var status: String
    public var rideKind: String?
    public var scheduledDepartureAt: String
    public var originStationName: String
    public var destinationName: String
    public var driverName: String?
    public var plateNumber: String?
    public var seatCapacity: Int
    public var bookedSeats: Int

    public var departure: Date? { VelroDates.instant(scheduledDepartureAt) }
}

/// A station from `GET /admin/stations` (StationAdminOut).
public struct VelroStation: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var code: String
    public var name: String
    public var villageName: String?
    public var districtName: String?
    public var isPrimary: Bool?
    public var status: String
}

/// A route from `GET /admin/routes`. VELRO has no "corridor" entity; routes (generated from route templates) are
/// the closest thing, station to destination with today's shared fare.
public struct VelroRoute: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var code: String
    public var routeType: String?
    public var originStationName: String
    public var destinationName: String
    public var distanceM: Int?
    public var durationMinutes: Int?
    public var status: String
    public var fareMinor: Int?
    public var fareCurrency: String?
}

/// A page from a list endpoint: the rows and `meta.total`.
public struct VelroPage<T: Sendable & Equatable>: Sendable, Equatable {
    public var items: [T]
    public var total: Int
}

/// `commission.rate_basis_points` from `GET /admin/settings` (admin only). Basis points: 1000 = 10 %.
public struct VelroCommission: Equatable, Sendable {
    public var basisPoints: Int?
    public static let settingKey = "commission.rate_basis_points"
    public static let defaultBasisPoints = 1000

    public init(basisPoints: Int?) { self.basisPoints = basisPoints }

    public var percent: Double? { basisPoints.map { Double($0) / 100 } }
    /// The domain refuses a rate outside 0–10000 at every trip completion (domain/fare.py); flag it if stored.
    public var isOutOfRange: Bool { basisPoints.map { !(0...10_000).contains($0) } ?? false }
}

/// VELRO money is integer minor units, 100 to the afghani (VelroCore Numerals.swift minorDigits AFN: 2).
public enum VelroMoney {
    public static func format(_ minor: Int, currency: String) -> String {
        "\((Double(minor) / 100).formatted(.number.precision(.fractionLength(0)))) \(currency)"
    }
}

public enum VelroDates {
    /// ISO 8601 with any number of fractional digits and any offset (`2026-10-09T05:35:53.695335Z`, `…-04:00`).
    public static func instant(_ text: String?) -> Date? {
        guard var text else { return nil }
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = text[text.index(after: dot)..<end]
            text = String(text[..<dot]) + "." + String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + text[end...]
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

// MARK: - Errors

public enum VelroError: Error, LocalizedError, Equatable {
    case notSignedIn
    /// Signed in, but the account holds no staff role (verify makes any unknown number a passenger).
    case notStaff
    case otpInvalid
    case otpExpired
    case otpAttemptsExceeded
    case otpRateLimited
    /// The refresh token was refused (expired, revoked, or replayed); every session may have been revoked.
    case sessionEnded(code: String)
    /// A refresh was sent but its answer never came back, so the server may already have rotated the token.
    /// Replaying the old one would sign the owner out everywhere, so the local session is dropped instead.
    case refreshOutcomeUnknown
    /// 403 PERMISSION_DENIED: this staff role can't read that (e.g. settings need ADMIN).
    case permissionDenied
    case server(status: Int, code: String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Not signed in to VELRO.")
        case .notStaff: L("This number signed in, but it holds no VELRO staff role. Roles are granted only on the server with scripts/grant-admin.py.")
        case .otpInvalid: L("That code is wrong. Check it and try again.")
        case .otpExpired: L("That code has expired (codes last 5 minutes). Ask for a new one.")
        case .otpAttemptsExceeded: L("Too many wrong codes for this one. Ask for a new code.")
        case .otpRateLimited: L("VELRO sends at most 3 codes a minute to a number. Wait a minute and ask again.")
        case .sessionEnded(let code): LF("VELRO ended the session (%@). Sign in again with a new code.", code)
        case .refreshOutcomeUnknown: L("The connection dropped while renewing the VELRO session, so it isn't known whether VELRO already replaced the token. To avoid replaying an old token (which would sign you out of every device, the web console included), this device's session was removed. Sign in again with a new code.")
        case .permissionDenied: L("Your VELRO staff role can't read this (403). Settings, including the commission, need ADMIN or SUPER_ADMIN.")
        case .server(let status, let code): LF("VELRO returned HTTP %1$ld (%2$@).", status, code)
        case .network(let m): LF("Couldn't reach VELRO: %@", m)
        case .decoding(let m): LF("VELRO answered in a form this app doesn't understand: %@", m)
        }
    }

    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .sessionEnded, .refreshOutcomeUnknown: true
        default: false
        }
    }

    struct Envelope: Decodable { struct Inner: Decodable { let code: String? }; let error: Inner? }

    static func code(in data: Data) -> String? { (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.code }

    static func from(status: Int, data: Data) -> VelroError {
        let code = code(in: data) ?? ""
        switch code {
        case "OTP_INVALID": return .otpInvalid
        case "OTP_EXPIRED", "OTP_ALREADY_CONSUMED": return .otpExpired
        case "OTP_ATTEMPTS_EXCEEDED": return .otpAttemptsExceeded
        case "OTP_RATE_LIMITED": return .otpRateLimited
        case "PERMISSION_DENIED": return .permissionDenied
        default: break
        }
        if status == 403 { return .permissionDenied }
        if status == 429 { return .otpRateLimited }
        return .server(status: status, code: code.isEmpty ? "HTTP \(status)" : code)
    }
}

// MARK: - Session and client

/// The staff session kept on this device (Keychain): the rotating refresh token, the user id, the roles and a
/// per-install device id. Never the phone number, never the access token.
public struct VelroStoredSession: Codable, Equatable, Sendable {
    public var environment: VelroEnvironment
    public var userID: String
    public var roles: [String]
    public var refreshToken: String
    public var deviceID: String

    public init(environment: VelroEnvironment, userID: String, roles: [String], refreshToken: String, deviceID: String) {
        self.environment = environment
        self.userID = userID
        self.roles = roles
        self.refreshToken = refreshToken
        self.deviceID = deviceID
    }

    public var canReadSettings: Bool { !VelroRoles.admin.isDisjoint(with: roles) }
    public var canReadDocuments: Bool { !VelroRoles.operations.isDisjoint(with: roles) }
}

/// Talks to one VELRO backend as staff.
///
/// **Refresh rotation.** VELRO replaces the refresh token on every use and treats a replayed one as theft
/// (revoking every session of the user, the web console included). So:
/// - only one refresh is ever in flight (concurrent requests wait for it, as VelroCore's RefreshCoordinator does);
/// - the new refresh token is handed to `persist` (the Keychain) **before** anything uses the new access token,
///   and only after the server answered 200 — a failed refresh never overwrites the stored token;
/// - a refresh whose answer was lost (timeout, dropped connection, 502/504 from the proxy) may already have rotated
///   the token on the server; the old one is then never sent again: the session is dropped locally
///   (`persist(nil)`) and the owner signs in again;
/// - a refresh that provably never left this device (no network, host not found) keeps the session.
public actor VelroStaffClient {
    public nonisolated let environment: VelroEnvironment
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let persist: @Sendable (VelroStoredSession?) -> Void
    private var session: VelroStoredSession?
    private var accessToken: String?
    private var accessExpiry: Date?
    private var inFlight: Task<String, Error>?

    public init(environment: VelroEnvironment, transport: HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { .now }, persist: @escaping @Sendable (VelroStoredSession?) -> Void) {
        self.environment = environment
        self.transport = transport
        self.now = now
        self.persist = persist
    }

    public var current: VelroStoredSession? { session }

    private static func encode(_ body: [String: String?]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 }, options: [.sortedKeys])
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct Meta: Decodable { let total: Int? }
    private struct PagedEnvelope<T: Decodable>: Decodable { let data: T; let meta: Meta? }

    private func post(_ path: String, _ body: [String: String?], token: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: environment.apiBase.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try Self.encode(body)
        return try await transport.send(request)
    }

    /// Asks VELRO to send a sign-in code. `audience: "staff"`: VELRO answers the same for any number but only sends a
    /// code to one that already holds a staff role (authenticate.py RequestOtp). The phone number is sent, not kept.
    public func requestCode(phone: String, locale: String = "en", channel: String = "sms") async throws -> VelroOtpSent {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await post("auth/otp/request", ["phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                   "locale": locale, "channel": channel, "audience": "staff"])
        } catch let e as URLError { throw VelroError.network(e.localizedDescription) }
        guard (200..<300).contains(response.statusCode) else { throw VelroError.from(status: response.statusCode, data: data) }
        do { return try Self.decoder.decode(Envelope<VelroOtpSent>.self, from: data).data } catch {
            throw VelroError.decoding(String(describing: error).prefix(300).description)
        }
    }

    /// Exchanges the code for a session. Refuses (and doesn't keep) a session without a staff role.
    public func verify(phone: String, code: String, deviceID: String, locale: String = "en") async throws -> VelroStoredSession {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await post("auth/otp/verify", ["phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                  "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                  "device_id": deviceID, "locale": locale])
        } catch let e as URLError { throw VelroError.network(e.localizedDescription) }
        guard (200..<300).contains(response.statusCode) else { throw VelroError.from(status: response.statusCode, data: data) }
        let reply: VelroSessionReply
        do { reply = try Self.decoder.decode(Envelope<VelroSessionReply>.self, from: data).data } catch {
            throw VelroError.decoding(String(describing: error).prefix(300).description)
        }
        guard VelroRoles.isStaff(reply.roles) else { throw VelroError.notStaff }
        let s = VelroStoredSession(environment: environment, userID: reply.userId, roles: reply.roles, refreshToken: reply.refreshToken, deviceID: deviceID)
        persist(s)
        session = s
        setAccess(reply)
        return s
    }

    /// Resumes a stored session. The first request exchanges (and rotates) the refresh token.
    public func restore(_ stored: VelroStoredSession) {
        session = stored
        accessToken = nil
        accessExpiry = nil
    }

    /// Forgets the session on this device. The server-side token simply expires (nothing is sent).
    public func signOut() {
        inFlight?.cancel()
        inFlight = nil
        session = nil
        accessToken = nil
        accessExpiry = nil
        persist(nil)
    }

    private func setAccess(_ reply: VelroSessionReply) {
        accessToken = reply.accessToken
        if let exp = JWTClaims.payload(reply.accessToken)?["exp"] as? Double {
            accessExpiry = Date(timeIntervalSince1970: exp)
        } else {
            accessExpiry = now().addingTimeInterval(TimeInterval(reply.expiresInSeconds ?? 900))
        }
    }

    private func endSession() {
        session = nil
        accessToken = nil
        accessExpiry = nil
        persist(nil)
    }

    /// A valid access token (more than a minute left), refreshing once if needed. Concurrent callers share one refresh.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, let accessExpiry, accessExpiry.timeIntervalSince(now()) > 60 { return accessToken }
        if let inFlight { return try await inFlight.value }
        guard session != nil else { throw VelroError.notSignedIn }
        let task = Task { try await self.performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// URL errors that mean the request never reached the server, so the refresh token is still unused.
    static func neverSent(_ e: URLError) -> Bool {
        [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
         .dataNotAllowed, .callIsActive, .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed].contains(e.code)
    }

    private func performRefresh() async throws -> String {
        guard let s = session else { throw VelroError.notSignedIn }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await post("auth/refresh", ["refresh_token": s.refreshToken, "device_id": s.deviceID])
        } catch let e as URLError {
            if Self.neverSent(e) { throw VelroError.network(e.localizedDescription) }
            endSession()
            throw VelroError.refreshOutcomeUnknown
        }
        switch response.statusCode {
        case 200..<300:
            guard let reply = try? Self.decoder.decode(Envelope<VelroSessionReply>.self, from: data).data else {
                // 200 but unreadable: the server rotated and we can't read the new token. Never replay the old one.
                endSession()
                throw VelroError.refreshOutcomeUnknown
            }
            let rotated = VelroStoredSession(environment: environment, userID: reply.userId, roles: reply.roles,
                                             refreshToken: reply.refreshToken, deviceID: s.deviceID)
            // Keychain first, then memory, then use.
            persist(rotated)
            session = rotated
            setAccess(reply)
            return reply.accessToken
        case 401:
            endSession()
            throw VelroError.sessionEnded(code: VelroError.code(in: data) ?? "TOKEN_INVALID")
        case 502, 504:
            // The proxy answered, the backend may have finished: outcome unknown.
            endSession()
            throw VelroError.refreshOutcomeUnknown
        default:
            // The backend itself refused (rolled back): the stored token is still the current one.
            throw VelroError.from(status: response.statusCode, data: data)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> (T, Int?) {
        var token = try await validAccessToken()
        var attempt = 0
        while true {
            var url = environment.apiBase.appending(path: path)
            if !query.isEmpty { url.append(queryItems: query) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.send(request) } catch let e as URLError { throw VelroError.network(e.localizedDescription) }
            if (200..<300).contains(response.statusCode) {
                do {
                    let page = try Self.decoder.decode(PagedEnvelope<T>.self, from: data)
                    return (page.data, page.meta?.total)
                } catch { throw VelroError.decoding(String(describing: error).prefix(300).description) }
            }
            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                token = try await validAccessToken(forceRefresh: true)
                continue
            }
            if response.statusCode == 401 {
                endSession()
                throw VelroError.sessionEnded(code: VelroError.code(in: data) ?? "TOKEN_INVALID")
            }
            throw VelroError.from(status: response.statusCode, data: data)
        }
    }

    // MARK: Reads (GET only)

    public func dashboard() async throws -> VelroDashboard { try await get("admin/dashboard", as: VelroDashboard.self).0 }

    public func pendingDrivers() async throws -> VelroPage<VelroDriver> {
        let (items, total) = try await get("admin/drivers", query: [URLQueryItem(name: "approval_status", value: "PENDING"), URLQueryItem(name: "limit", value: "200")],
                                           as: [VelroDriver].self)
        return VelroPage(items: items, total: total ?? items.count)
    }

    public func documents(driverID: String) async throws -> VelroDocumentChecklist {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let id = driverID.addingPercentEncoding(withAllowedCharacters: allowed) ?? driverID
        return try await get("admin/drivers/\(id)/documents", as: VelroDocumentChecklist.self).0
    }

    public func activeTrips() async throws -> VelroPage<VelroTrip> {
        let (items, total) = try await get("admin/trips", query: [URLQueryItem(name: "active_only", value: "true"), URLQueryItem(name: "limit", value: "50")],
                                           as: [VelroTrip].self)
        return VelroPage(items: items, total: total ?? items.count)
    }

    /// Trips departing in the next `hours` (1–72), soonest first.
    public func upcomingTrips(hours: Int = 24) async throws -> VelroPage<VelroTrip> {
        let (items, total) = try await get("admin/trips", query: [URLQueryItem(name: "departing_within_hours", value: String(min(max(hours, 1), 72))),
                                                                  URLQueryItem(name: "limit", value: "50")], as: [VelroTrip].self)
        return VelroPage(items: items, total: total ?? items.count)
    }

    public func stations() async throws -> VelroPage<VelroStation> {
        let (items, total) = try await get("admin/stations", query: [URLQueryItem(name: "limit", value: "200")], as: [VelroStation].self)
        return VelroPage(items: items, total: total ?? items.count)
    }

    public func routes() async throws -> VelroPage<VelroRoute> {
        let (items, total) = try await get("admin/routes", query: [URLQueryItem(name: "limit", value: "200")], as: [VelroRoute].self)
        return VelroPage(items: items, total: total ?? items.count)
    }

    /// `commission.rate_basis_points` from `GET /admin/settings` (ADMIN or SUPER_ADMIN). Read only.
    public func commission() async throws -> VelroCommission {
        struct Setting: Decodable { let key: String; let value: JSONNumberOrOther? }
        let (settings, _) = try await get("admin/settings", as: [Setting].self)
        guard let s = settings.first(where: { $0.key == VelroCommission.settingKey }) else { return VelroCommission(basisPoints: nil) }
        return VelroCommission(basisPoints: s.value?.int)
    }
}

/// A setting's value: an integer when it is one, anything else ignored.
struct JSONNumberOrOther: Decodable, Sendable {
    let int: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { int = i } else if let d = try? c.decode(Double.self), d.rounded() == d { int = Int(d) } else { int = nil }
    }
}
