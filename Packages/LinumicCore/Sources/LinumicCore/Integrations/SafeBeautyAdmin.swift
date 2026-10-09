import CommonCrypto
import Foundation

// SafeBeauty platform admin, read-only. SafeBeauty has no admin REST API: its web console signs in through two
// callables and then reads Firestore directly under the security rules. Linumic OS does the same, read-only.
//
// Source of every step, callable and field: the SafeBeauty repository at origin/main @ efe5bdf (2026-10-09),
//   public/admin/index.html:382-399     normalizeForLogin, deriveAuthPassword (PBKDF2-SHA256, "AUTH:" + password)
//   public/admin/index.html:1082-1107   doLogin: authenticateWithPassword -> signInWithEmailAndPassword -> syncUidMap
//   public/admin/index.html:1203-1236   the stats counts; :1349-1402 the approval and KYC queues; :3424-3497 money
//   functions/domains/identity.js:55-156  authenticateWithPassword (returns mode/role/firebaseEmail/salt), syncUidMap
//   functions/shared.js:374-377         pbkdf2Hash; :114-121 assertAdmin (users/{appUid}.role == "ADMIN")
//   functions/domains/payments.js:39-79 getCommissionPercent: platform_config/general.commissionPercent, else 10
//   firestore.rules                     isAdmin() via uid_map; users list admin-only; provider_balances, refund_requests
//   ios/SafeBeautyCore/.../Security/PinHasher.swift and Util/PhoneUtils.swift  the tested Swift ports reused below
// Nothing here writes to Firestore or calls an admin callable. The only callables used are the two sign-in steps.

// MARK: - Environment

public enum SafeBeautyEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case production
    /// `safebeauty-staging` (the Android demo flavour). Whether its functions are deployed is unverified.
    case staging
    /// The Firebase Emulator Suite on this Mac (`--project demo-safebeauty`). Offered in debug builds only.
    case localEmulator

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .production: L("Production")
        case .staging: L("Staging")
        case .localEmulator: L("Local emulator")
        }
    }

    public var isProduction: Bool { self == .production }

    public static func offered(includeEmulator: Bool) -> [SafeBeautyEnvironment] {
        includeEmulator ? allCases : [.production, .staging]
    }

    var project: String {
        switch self {
        case .production: "safebeauty"
        case .staging: "safebeauty-staging"
        case .localEmulator: "demo-safebeauty"
        }
    }

    /// Callables live at `…/<name>` (us-central1, functions/domains/*.js `onCall({region: "us-central1"})`).
    public var functionsBase: URL {
        switch self {
        case .production, .staging: URL(string: "https://us-central1-\(project).cloudfunctions.net")!
        case .localEmulator: URL(string: "http://127.0.0.1:5001/demo-safebeauty/us-central1")!
        }
    }

    /// Public Web API keys: production `public/admin/index.html:368`, staging `app/src/demo/google-services.json`
    /// (`current_key`). Not secrets. The emulator accepts any key.
    public var auth: FirebaseAuthEndpoints {
        switch self {
        case .production: .google(apiKey: "AIzaSyBZG_ltbYVsaZkPyGQ_NozOQvo3JeuO2mQ")
        case .staging: .google(apiKey: "AIzaSyBL-72Iklw1avxbeb5fRtdij4nGdFg5NPE")
        case .localEmulator: .emulator(host: "127.0.0.1", port: 9099, apiKey: "demo-key")
        }
    }

    public var firestore: FirestoreEndpoint {
        switch self {
        case .production, .staging: .google(project: project)
        case .localEmulator: .emulator(host: "127.0.0.1", port: 8080, project: project)
        }
    }

    /// The web admin console, for every action. `safebeauty.web.app/admin` is the documented, permanent path
    /// (DEPLOY.md "Hosting: three sites"; hardcoded in desktop/main.js); answered 200 on 2026-10-09.
    public var adminPanel: URL? {
        switch self {
        case .production: URL(string: "https://safebeauty.web.app/admin")!
        case .staging, .localEmulator: nil
        }
    }
}

// MARK: - Password derivation and phone normalisation (ported, not reinvented)

/// Port of SafeBeauty's `PinHasher` (ios/SafeBeautyCore/Sources/SafeBeautyCore/Security/PinHasher.swift), itself the
/// Swift twin of `PinHasher.kt` and the admin console's `deriveAuthPassword`: PBKDF2-HMAC-SHA256, 65,536 iterations,
/// 32 bytes, the password as UTF-8, the salt base64. The test vectors in the tests are SafeBeauty's own.
public enum SafeBeautyPassword {
    public static let iterations: UInt32 = 65_536
    public static let keyBytes = 32

    public enum Failure: Error, Equatable {
        case saltNotBase64
        case derivationFailed(status: Int32)
    }

    /// PBKDF2(password, salt) -> base64. This is what SafeBeauty stores as `pinHash`; Linumic OS never sends it.
    public static func hash(_ password: String, saltBase64: String) throws -> String {
        guard let salt = Data(base64Encoded: saltBase64) else { throw Failure.saltNotBase64 }
        let bytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyBytes)
        let status: Int32 = salt.withUnsafeBytes { saltBuffer in
            bytes.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, bytes.count,
                                     saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, keyBytes)
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed(status: status) }
        return Data(derived).base64EncodedString()
    }

    /// The Firebase Auth password: `hash("AUTH:" + password)`, domain-separated from the stored hash.
    public static func authPassword(_ password: String, saltBase64: String) throws -> String {
        try hash("AUTH:" + password, saltBase64: saltBase64)
    }
}

/// Port of `PhoneUtils.normalizeForLogin` (ios/SafeBeautyCore/Sources/SafeBeautyCore/Util/PhoneUtils.swift, which
/// mirrors PhoneUtils.kt and the console's `normalizeForLogin`). A number typed with "+" is kept as international;
/// anything else is read as Afghan. Persian digits are folded to ASCII.
public enum SafeBeautyPhone {
    static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.compactMap { ch -> Character? in
            guard ch.isNumber, let v = ch.wholeNumberValue, (0...9).contains(v) else { return nil }
            return Character(String(v))
        }
        return (trimmed.hasPrefix("+") ? "+" : "") + String(digits)
    }

    public static func normalizeAfghan(_ raw: String) -> String {
        var c = clean(raw)
        if c.hasPrefix("+93") { return c }
        if c.hasPrefix("0093") { return "+93" + c.dropFirst(4) }
        if c.hasPrefix("93") && c.count >= 11 { return "+" + c }
        if c.hasPrefix("+") { c = String(c.dropFirst()) }
        if c.hasPrefix("0") { c = String(c.dropFirst()) }
        return "+93" + c
    }

    public static func normalizeForLogin(_ raw: String) -> String {
        let c = clean(raw)
        return c.hasPrefix("+") ? c : normalizeAfghan(raw)
    }
}

// MARK: - Models

/// `authenticateWithPassword`'s answer (identity.js:107-118). Only what the sign-in needs.
struct SafeBeautyLoginReply: Decodable, Sendable {
    let mode: String
    let uid: String?
    let name: String?
    let role: String?
    let firebaseEmail: String?
    let salt: String?
}

/// A person in a queue: name, role and status only. The identity-document fields (tazkira number and photos,
/// selfie, address, birth year) are never requested (Firestore field mask), so they never reach this device.
public struct SafeBeautyPerson: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// CUSTOMER, PROVIDER or ADMIN.
    public var role: String
    /// Account status: PENDING, APPROVED, REJECTED, SUSPENDED…
    public var status: String
    /// NONE, PENDING, APPROVED, REJECTED.
    public var kycStatus: String
    public var joined: Date?

    public init(id: String, name: String, role: String, status: String, kycStatus: String, joined: Date?) {
        self.id = id
        self.name = name
        self.role = role
        self.status = status
        self.kycStatus = kycStatus
        self.joined = joined
    }

    /// The fields asked for. Nothing else.
    static let mask = ["name", "role", "status", "kycStatus", "createdAt"]

    init(_ doc: FirestoreDocument) {
        self.init(id: doc.id, name: doc["name"]?.string ?? "", role: doc["role"]?.string ?? "", status: doc["status"]?.string ?? "",
                  kycStatus: doc["kycStatus"]?.string ?? "NONE", joined: doc["createdAt"]?.date)
    }
}

/// A salon balance (`provider_balances`): positive = the platform owes the salon; negative = the salon owes.
public struct SafeBeautyBalance: Equatable, Sendable, Identifiable {
    public var providerID: String
    public var name: String?
    public var owedAmount: Int
    public var updatedAt: Date?
    public var id: String { providerID }

    public init(providerID: String, name: String?, owedAmount: Int, updatedAt: Date?) {
        self.providerID = providerID
        self.name = name
        self.owedAmount = owedAmount
        self.updatedAt = updatedAt
    }
}

/// `platform_config/general` as stored, and the commission the server actually applies.
public struct SafeBeautyCommission: Equatable, Sendable {
    /// The stored value, nil when the document or field is missing or not a number.
    public var storedPercent: Double?
    public var storedMaxDiscountFraction: Double?
    public static let defaultPercent: Double = 10
    public static let defaultMaxDiscountFraction = 0.9

    public init(storedPercent: Double?, storedMaxDiscountFraction: Double?) {
        self.storedPercent = storedPercent
        self.storedMaxDiscountFraction = storedMaxDiscountFraction
    }

    /// `getCommissionPercent` (payments.js:71-79): a stored value outside 0...100 (or none) means 10.
    public var effectivePercent: Double {
        guard let p = storedPercent, p.isFinite, (0...100).contains(p) else { return Self.defaultPercent }
        return p
    }

    /// `getMaxDiscountFraction` (payments.js:56-69): strictly between 0 and 1, else 0.9.
    public var effectiveMaxDiscountFraction: Double {
        guard let f = storedMaxDiscountFraction, f.isFinite, f > 0, f < 1 else { return Self.defaultMaxDiscountFraction }
        return f
    }

    /// The stored value is present but the server ignores it.
    public var storedIsIgnored: Bool { storedPercent != nil && storedPercent != effectivePercent }
}

/// Kabul's day and week. Afghanistan's week starts on Saturday.
public enum SafeBeautyCalendar {
    public static var kabul: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kabul")!
        c.firstWeekday = 7
        return c
    }

    public static func today(_ now: Date) -> DateInterval { kabul.dateInterval(of: .day, for: now)! }
    public static func week(_ now: Date) -> DateInterval { kabul.dateInterval(of: .weekOfYear, for: now)! }
}

/// Everything the SafeBeauty overview shows, read at one time.
public struct SafeBeautySnapshot: Equatable, Sendable {
    public var kycPendingCount: Int
    public var kycQueue: [SafeBeautyPerson]
    public var approvalPendingCount: Int
    public var approvalQueue: [SafeBeautyPerson]
    public var salonCount: Int
    public var verifiedSalonCount: Int
    public var bookingsToday: Int
    public var bookingsThisWeek: Int
    public var today: DateInterval
    public var week: DateInterval
    /// Balances the platform owes (positive), largest first.
    public var payoutsOwed: [SafeBeautyBalance]
    public var refundRequestsPending: Int
    public var commission: SafeBeautyCommission
    public var readAt: Date

    public var payoutsOwedTotal: Int { payoutsOwed.reduce(0) { $0 + $1.owedAmount } }
}

/// A callable's answer: `{"result": …}` or `{"error": {status, message, details}}`.
struct CallableReply<R: Decodable>: Decodable {
    struct Failure: Decodable { let status: String?; let message: String? }
    let result: R?
    let error: Failure?
}

// MARK: - Errors

public enum SafeBeautyError: Error, LocalizedError, Equatable {
    case notSignedIn
    case invalidPhoneOrPassword
    case notAdmin
    case missingPassword
    case auth(FirebaseAuthError)
    /// The uid bridge (`syncUidMap`) failed: without it the security rules can't see the admin.
    case uidMap(String)
    case rateLimited(String)
    case callable(status: String, message: String)
    case firestore(FirestoreError)
    case network(String)
    case decoding(String)
    case derivation(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Not signed in to SafeBeauty.")
        case .invalidPhoneOrPassword: L("The phone number or password is wrong.")
        case .notAdmin: L("This SafeBeauty account isn't an administrator (users.role is not ADMIN).")
        case .missingPassword: L("Enter the phone number and password.")
        case .auth(let e): e.errorDescription
        case .uidMap(let m): LF("SafeBeauty's uid bridge (syncUidMap) failed, so its security rules can't see this admin: %@", m)
        case .rateLimited(let m): LF("SafeBeauty is limiting sign-in attempts: %@", m)
        case .callable(let status, let m): LF("SafeBeauty returned %1$@: %2$@", status, m)
        case .firestore(let e): e.errorDescription
        case .network(let m): LF("Couldn't reach SafeBeauty: %@", m)
        case .decoding(let m): LF("SafeBeauty answered in a form this app doesn't understand: %@", m)
        case .derivation(let m): LF("The sign-in password couldn't be derived: %@", m)
        }
    }

    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .auth(.sessionExpired), .firestore(.unauthenticated): true
        default: false
        }
    }
}

// MARK: - Client

/// The admin session kept on this device: the Firebase refresh token, the app uid and the display name. Never the
/// phone number, the password, the salt or any derived password.
public struct SafeBeautyStoredSession: Codable, Equatable, Sendable {
    public var environment: SafeBeautyEnvironment
    public var appUID: String
    public var name: String
    public var refreshToken: String

    public init(environment: SafeBeautyEnvironment, appUID: String, name: String, refreshToken: String) {
        self.environment = environment
        self.appUID = appUID
        self.name = name
        self.refreshToken = refreshToken
    }
}

public actor SafeBeautyAdminClient {
    public nonisolated let environment: SafeBeautyEnvironment
    private let session: FirebaseSession
    private let firestore: FirestoreREST
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    public static let queueLimit = 100

    public init(environment: SafeBeautyEnvironment, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.environment = environment
        self.transport = transport
        self.now = now
        session = FirebaseSession(auth: FirebaseAuthREST(endpoints: environment.auth, transport: transport, now: now), now: now)
        firestore = FirestoreREST(endpoint: environment.firestore, transport: transport)
    }

    /// POST a callable: `{"data": …}` -> `{"result": …}` or `{"error": {status, message}}`.
    private func call<T: Decodable>(_ name: String, _ data: [String: String], token: String?, as: T.Type) async throws -> T {
        var request = URLRequest(url: environment.functionsBase.appending(path: name))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])
        let body: Data
        let response: HTTPURLResponse
        do { (body, response) = try await transport.send(request) } catch let e as URLError { throw SafeBeautyError.network(e.localizedDescription) }
        let reply = try? JSONDecoder().decode(CallableReply<T>.self, from: body)
        if (200..<300).contains(response.statusCode), let result = reply?.result { return result }
        let status = reply?.error?.status ?? "HTTP \(response.statusCode)"
        let message = reply?.error?.message ?? String(decoding: body.prefix(200), as: UTF8.self)
        if status == "RESOURCE_EXHAUSTED" { throw SafeBeautyError.rateLimited(message) }
        if (200..<300).contains(response.statusCode) { throw SafeBeautyError.decoding(message) }
        throw SafeBeautyError.callable(status: status, message: message)
    }

    /// The console's five steps (index.html doLogin): normalise the phone, `authenticateWithPassword`, derive the
    /// Firebase password, sign in, `syncUidMap`. The password and the derived password are used once, here, and
    /// are not kept; the phone number isn't either.
    public func signIn(phone: String, password: String) async throws -> SafeBeautyStoredSession {
        let normalized = SafeBeautyPhone.normalizeForLogin(phone)
        guard !normalized.isEmpty, normalized != "+93", !password.isEmpty else { throw SafeBeautyError.missingPassword }
        let login = try await call("authenticateWithPassword", ["phone": normalized, "password": password], token: nil, as: SafeBeautyLoginReply.self)
        guard login.mode == "REAL", let uid = login.uid, let email = login.firebaseEmail, !email.isEmpty, let salt = login.salt else {
            throw SafeBeautyError.invalidPhoneOrPassword
        }
        guard login.role == "ADMIN" else { throw SafeBeautyError.notAdmin }
        let derived: String
        do { derived = try SafeBeautyPassword.authPassword(password, saltBase64: salt) } catch { throw SafeBeautyError.derivation(String(describing: error)) }
        let tokens: FirebaseTokens
        do { tokens = try await session.signIn(email: email, password: derived) }
        catch let e as FirebaseAuthError { throw SafeBeautyError.auth(e) }
        catch let e as URLError { throw SafeBeautyError.network(e.localizedDescription) }
        do {
            struct Synced: Decodable { let synced: Bool }
            _ = try await call("syncUidMap", ["appUid": uid], token: tokens.idToken, as: Synced.self)
        } catch {
            await session.signOut()
            throw SafeBeautyError.uidMap(error.localizedDescription)
        }
        return SafeBeautyStoredSession(environment: environment, appUID: uid, name: login.name ?? "", refreshToken: tokens.refreshToken)
    }

    public func restore(refreshToken: String) async { await session.restore(refreshToken: refreshToken) }
    public func signOut() async { await session.signOut() }
    public var currentRefreshToken: String? { get async { await session.currentRefreshToken } }

    private func token(forceRefresh: Bool = false) async throws -> String {
        do { return try await session.idToken(forceRefresh: forceRefresh) }
        catch let e as FirebaseAuthError { throw SafeBeautyError.auth(e) }
        catch let e as URLError { throw SafeBeautyError.network(e.localizedDescription) }
    }

    /// Runs a Firestore read with a fresh token; one retry after a 401 with a refreshed token.
    private func read<T>(_ body: (String) async throws -> T) async throws -> T {
        do { return try await body(token()) } catch FirestoreError.unauthenticated {
            do { return try await body(token(forceRefresh: true)) } catch let e as FirestoreError { throw SafeBeautyError.firestore(e) }
        } catch let e as FirestoreError { throw SafeBeautyError.firestore(e) }
    }

    // MARK: Reads (Firestore, read-only, field-masked)

    public func count(_ collection: String, _ filters: [FirestoreFilter] = []) async throws -> Int {
        try await read { try await firestore.count(collection, filters: filters, token: $0) }
    }

    public func people(where filter: FirestoreFilter) async throws -> [SafeBeautyPerson] {
        try await read { try await firestore.query("users", filters: [filter], select: SafeBeautyPerson.mask, limit: Self.queueLimit, token: $0) }
            .map(SafeBeautyPerson.init)
            .sorted { ($0.joined ?? .distantPast) > ($1.joined ?? .distantPast) }
    }

    public func commission() async throws -> SafeBeautyCommission {
        let doc = try await read { try await firestore.get("platform_config", "general", mask: ["commissionPercent", "maxDiscountFraction"], token: $0) }
        return SafeBeautyCommission(storedPercent: doc?["commissionPercent"]?.number, storedMaxDiscountFraction: doc?["maxDiscountFraction"]?.number)
    }

    /// Positive balances (the platform owes the salon), with the salon owner's name.
    public func payoutsOwed() async throws -> [SafeBeautyBalance] {
        let docs = try await read { try await firestore.list("provider_balances", mask: ["providerId", "owedAmount", "updatedAt"], pageSize: 300, token: $0) }
        let owed = docs.compactMap { d -> SafeBeautyBalance? in
            guard let amount = d["owedAmount"]?.number, amount > 0 else { return nil }
            return SafeBeautyBalance(providerID: d["providerId"]?.string ?? d.id, name: nil, owedAmount: Int(amount), updatedAt: d["updatedAt"]?.date)
        }.sorted { $0.owedAmount > $1.owedAmount }
        let ids = Array(owed.prefix(100).map(\.providerID))
        let names = try await read { try await firestore.batchGet("users", ids: ids, mask: ["name"], token: $0) }
            .reduce(into: [String: String]()) { $0[$1.id] = $1["name"]?.string }
        return owed.map { var b = $0; b.name = names[b.providerID]; return b }
    }

    /// Everything the overview shows. The counts are server-side aggregation queries (no documents read).
    public func snapshot() async throws -> SafeBeautySnapshot {
        let at = now()
        let today = SafeBeautyCalendar.today(at), week = SafeBeautyCalendar.week(at)
        func ms(_ d: Date) -> FirestoreFilter.Value { .integer(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
        let kyc = FirestoreFilter("kycStatus", .equal, .string("PENDING"))
        let pending = FirestoreFilter("status", .equal, .string("PENDING"))
        return SafeBeautySnapshot(
            kycPendingCount: try await count("users", [kyc]),
            kycQueue: try await people(where: kyc),
            approvalPendingCount: try await count("users", [pending]),
            approvalQueue: try await people(where: pending),
            salonCount: try await count("salons"),
            verifiedSalonCount: try await count("salons", [FirestoreFilter("isVerified", .equal, .bool(true))]),
            bookingsToday: try await count("appointments", [FirestoreFilter("appointmentDate", .greaterThanOrEqual, ms(today.start)),
                                                            FirestoreFilter("appointmentDate", .lessThan, ms(today.end))]),
            bookingsThisWeek: try await count("appointments", [FirestoreFilter("appointmentDate", .greaterThanOrEqual, ms(week.start)),
                                                               FirestoreFilter("appointmentDate", .lessThan, ms(week.end))]),
            today: today, week: week,
            payoutsOwed: try await payoutsOwed(),
            refundRequestsPending: try await count("refund_requests", [FirestoreFilter("status", .equal, .string("PENDING"))]),
            commission: try await commission(),
            readAt: at)
    }
}
