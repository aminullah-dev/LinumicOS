import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. talar-*.json, safebeauty-*.json and velro-*.json were captured on 2026-10-09 from local
// emulators/backends (Talar and SafeBeauty Firebase emulators, projects demo-talar and demo-safebeauty; a VELRO
// backend on 127.0.0.1 with its development seed), never from production. Every name and number in them is made up.
// velro-session.json has its tokens replaced; velro-otp-request.json has debug_code removed.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Answers requests from a handler and records them.
private final class Stub: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = lock.withLock { _requests.append(request); return _requests.count }
        let (status, body) = try handler(request, n)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func body(_ r: URLRequest) -> [String: Any] {
    (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

/// An unsigned JWT with the given payload (the client only reads claims; the server verifies).
private func jwt(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(b64)."
}

private func signInReply(idToken: String, email: String = "admin@linumic.test") -> Data {
    Data(#"{"idToken":"\#(idToken)","refreshToken":"refresh-1","expiresIn":"3600","localId":"uid-1","email":"\#(email)"}"#.utf8)
}

// MARK: - Firestore REST

@Suite("Firestore REST decoding")
struct FirestoreRESTTests {
    @Test func valuesAndDocuments() throws {
        let page = try JSONDecoder().decode([String: [FirestoreDocument]].self, from: fixture("talar-organizations"))
        let org = try #require(page["documents"]?.first)
        #expect(org.id == "org-demo" && org["name"]?.string == "شرکت تالارهای آریانا" && org["commissionPct"]?.number == 5)

        let config = try JSONDecoder().decode(FirestoreDocument.self, from: fixture("safebeauty-config"))
        #expect(config["commissionPercent"]?.number == 12 && config["maxDiscountFraction"]?.number == 0.5)

        let v = try JSONDecoder().decode([String: FirestoreValue].self, from: Data(#"""
            {"n":{"nullValue":null},"t":{"timestampValue":"2026-10-09T05:31:17.352742Z"},"a":{"arrayValue":{}},
             "m":{"mapValue":{"fields":{"x":{"booleanValue":true}}}},"g":{"geoPointValue":{"latitude":1,"longitude":2}},
             "ms":{"integerValue":"1791523877351"}}
            """#.utf8))
        #expect(v["n"] == .null && v["a"] == .array([]) && v["m"] == .map(["x": .bool(true)]) && v["g"] == .other)
        #expect(v["t"]?.date != nil)
        #expect(v["ms"]?.date == Date(timeIntervalSince1970: 1_791_523_877.351))
    }

    @Test func queryCountBatchGetAndRequestShapes() async throws {
        let stub = Stub { r, _ in
            let url = r.url!.absoluteString
            if url.hasSuffix(":runQuery") { return (200, try fixture("safebeauty-kyc-query")) }
            if url.hasSuffix(":runAggregationQuery") { return (200, try fixture("safebeauty-count")) }
            if url.hasSuffix(":batchGet") { return (200, try fixture("safebeauty-batchget")) }
            return (404, Data())
        }
        let fs = FirestoreREST(endpoint: .emulator(host: "127.0.0.1", port: 8080, project: "demo-safebeauty"), transport: stub)
        let docs = try await fs.query("users", filters: [FirestoreFilter("kycStatus", .equal, .string("PENDING"))], select: ["name", "role"], limit: 100, token: "t")
        #expect(docs.map(\.id).sorted() == ["emu-kyc-1", "emu-kyc-2"])
        let q = body(stub.requests[0])["structuredQuery"] as? [String: Any]
        #expect(((q?["select"] as? [String: Any])?["fields"] as? [[String: String]])?.map { $0["fieldPath"]! } == ["name", "role"])
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer t")

        #expect(try await fs.count("salons", filters: [], token: "t") == 3)
        let found = try await fs.batchGet("users", ids: ["emu-provider-1", "nope"], mask: ["name"], token: "t")
        #expect(found.map(\.id) == ["emu-provider-1"], "missing documents are left out")
        let names = body(stub.requests[2])["documents"] as? [String]
        #expect(names?.first == "projects/demo-safebeauty/databases/(default)/documents/users/emu-provider-1")
        #expect(try await fs.get("platform_config", "missing", mask: [], token: "t") == nil)
    }

    @Test func errors() {
        #expect(FirestoreError.from(status: 403, data: Data(#"{"error":{"code":403,"message":"Missing or insufficient permissions.","status":"PERMISSION_DENIED"}}"#.utf8))
                == .permissionDenied("Missing or insufficient permissions."))
        #expect(FirestoreError.from(status: 400, data: Data(#"[{"error":{"message":"The query requires an index.","status":"FAILED_PRECONDITION"}}]"#.utf8))
                == .failedPrecondition("The query requires an index."))
        #expect(FirestoreError.from(status: 401, data: Data()) == .unauthenticated)
    }
}

// MARK: - Talar

@Suite("Talar admin")
struct TalarTests {
    @Test func decodesEmulatorCaptures() throws {
        let d = try JSONDecoder().decode(TalarDashboard.self, from: fixture("talar-dashboard"))
        #expect(d == TalarDashboard(publishedHalls: 4, hallsAwaitingReview: 2, confirmedBookings: 1, openTickets: 0))

        struct Items<T: Decodable>: Decodable { let items: [T] }
        let halls = try JSONDecoder().decode(Items<TalarHall>.self, from: fixture("talar-halls-pending")).items
        #expect(halls.count == 2)
        let h = try #require(halls.first { $0.id == "emu-hall-pending-1" })
        #expect(h.name.best(preferring: "en") == "Bahar Test Hall (emulator)" && h.name.best(preferring: "fa") == "تالار آزمایشی بهار")
        #expect(h.capacity == .init(total: 800, mens: 400, womens: 400) && h.shifts == ["EVENING", "FULL_DAY"] && h.hallType == "luxury")
        #expect(h.hallFeeMinor == 25_000_000)
        #expect(TalarMoney.format(25_000_000, currency: "AFN").hasSuffix(" AFN") && TalarMoney.format(100, currency: "USD") == "$1")
        #expect(h.refundRules.first?.refundPct == 80 && h.status == "pending_review" && h.orgId == "org-demo")
        #expect(h.createdAt?.date == Date(timeIntervalSince1970: 1_791_350_687.063))

        let reviews = try JSONDecoder().decode(Items<TalarReview>.self, from: fixture("talar-reviews")).items
        #expect(reviews.first?.hallId == "hall-aryana" && reviews.first?.rating == 4 && reviews.first?.aspects["food"] == 5)

        let payouts = try JSONDecoder().decode(Items<TalarPayout>.self, from: fixture("talar-payouts")).items
        #expect(payouts.map(\.status) == ["pending", "paid"] && payouts[0].paymentCount == 2 && payouts[1].paidAt != nil)
        let org = TalarOrganization(id: "org-demo", name: "x", status: "active", commissionPct: 5)
        let s = TalarPayoutSummary([TalarOrgPayouts(organization: org, payouts: payouts),
                                    TalarOrgPayouts(organization: TalarOrganization(id: "o2", name: "y", status: "active", commissionPct: nil), payouts: [], error: "403")],
                                   truncated: false)
        #expect(s.pendingCount == 1 && s.pendingNetMinor == 9_500_000 && s.organizationsWithPending == 1 && s.organizationsFailed == 1)
    }

    @Test func timestampForms() throws {
        let iso = try JSONDecoder().decode(TalarTimestamp.self, from: Data(#""2026-10-09T05:00:00.000Z""#.utf8))
        #expect(iso.date == Date(timeIntervalSince1970: 1_791_522_000))
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(TalarTimestamp.self, from: Data("42".utf8)) }
    }

    @Test func signInRequiresTheAdminClaim() async throws {
        let admin = Stub { _, _ in (200, signInReply(idToken: jwt(["role": "admin", "user_id": "uid-1"]))) }
        let s = try await TalarAdminClient(environment: .localEmulator, transport: admin).signIn(email: " admin@linumic.test ", password: "pw")
        #expect(s.email == "admin@linumic.test" && s.refreshToken == "refresh-1" && s.environment == .localEmulator)
        #expect(body(admin.requests[0])["email"] as? String == "admin@linumic.test")

        let owner = Stub { _, _ in (200, signInReply(idToken: jwt(["role": "owner", "orgId": "org-demo"]))) }
        await #expect(throws: TalarError.notAdmin) { _ = try await TalarAdminClient(environment: .localEmulator, transport: owner).signIn(email: "o@x", password: "pw") }
        #expect(!TalarAdminClient.isAdmin(idToken: "garbage"))
    }

    @Test func readsRetryOnceAfter401AndTheWriteNever() async throws {
        let stub = Stub { r, n in
            let url = r.url!.absoluteString
            if url.contains("signInWithPassword") { return (200, signInReply(idToken: jwt(["role": "admin"]))) }
            if url.contains("securetoken") { return (200, Data(#"{"id_token":"\#(jwt(["role": "admin"]))","refresh_token":"refresh-2","expires_in":"3600","user_id":"uid-1"}"#.utf8)) }
            if url.hasSuffix("/admin/dashboard") { return n == 2 ? (401, Data(#"{"error":{"code":"UNAUTHENTICATED","message":"Authentication required"}}"#.utf8)) : (200, try fixture("talar-dashboard")) }
            if url.contains("/review") { return (401, Data(#"{"error":{"code":"UNAUTHENTICATED","message":"x"}}"#.utf8)) }
            return (404, Data())
        }
        let client = TalarAdminClient(environment: .localEmulator, transport: stub)
        _ = try await client.signIn(email: "a@b", password: "pw")
        #expect(try await client.dashboard().hallsAwaitingReview == 2)
        #expect(stub.requests.map { $0.url!.path }.filter { $0.hasSuffix("dashboard") }.count == 2, "one retry after the 401")
        #expect(await client.currentRefreshToken == "refresh-2")

        let before = stub.requests.count
        await #expect(throws: TalarError.unauthenticated) {
            try await client.reviewHall("h1", try TalarHallReviewWrite.make(decision: .approve, reason: "  "))
        }
        #expect(stub.requests.count == before + 1, "the write is sent once, never retried")
        #expect(body(stub.requests[before]) as NSDictionary == ["decision": "approve"] as NSDictionary, "an empty reason is left out")
        #expect(stub.requests[before].url!.absoluteString.hasSuffix("/api/v1/admin/halls/h1/review"))
    }

    @Test func hallReviewWriteAndErrors() throws {
        let w = try TalarHallReviewWrite.make(decision: .reject, reason: " Photos missing ")
        #expect(String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains(#""reason":"Photos missing""#))
        #expect(throws: TalarError.self) { _ = try TalarHallReviewWrite.make(decision: .reject, reason: String(repeating: "x", count: 501)) }
        func e(_ s: Int, _ code: String, _ m: String) -> TalarError {
            TalarError.from(status: s, data: Data(#"{"error":{"code":"\#(code)","message":"\#(m)","requestId":"r"}}"#.utf8))
        }
        #expect(e(409, "CONFLICT", "Hall is not awaiting review") == .conflict("Hall is not awaiting review"))
        #expect(e(403, "FORBIDDEN", "x") == .notAdmin)
        #expect(e(404, "NOT_FOUND", "Hall not found") == .notFound("Hall not found"))
        #expect(e(400, "VALIDATION_FAILED", "Request validation failed") == .validation("Request validation failed"))
        #expect(TalarError.unauthenticated.needsSignIn && !TalarError.notAdmin.needsSignIn)
    }

    @Test func environments() {
        #expect(TalarEnvironment.offered(includeEmulator: false) == [.production, .demo])
        #expect(TalarEnvironment.production.adminPanel?.absoluteString == "https://talar-af-prod.web.app/admin")
        #expect(TalarEnvironment.localEmulator.firestore.documents.absoluteString == "http://127.0.0.1:8080/v1/projects/demo-talar/databases/(default)/documents")
        #expect(TalarEnvironment.production.firestore.resourcePrefix == "projects/talar-af-prod/databases/(default)/documents")
    }
}

// MARK: - SafeBeauty

@Suite("SafeBeauty admin")
struct SafeBeautyTests {
    // SafeBeauty's own reference vectors (ios/SafeBeautyCore/Tests/SafeBeautyCoreTests/PinHasherTests.swift), generated
    // from the derivation that signs real admins in; they must not be changed to match this port.
    static let salt = "c2FsdHNhbHRzYWx0c2Fs"
    static let zeroSalt = "AAAAAAAAAAAAAAAAAAAAAA=="

    @Test func pbkdf2MatchesSafeBeautyVectors() throws {
        #expect(try SafeBeautyPassword.hash("142857", saltBase64: Self.salt) == "0pyMrXLNCE9vObESd4aBU6TzZKzkMYoQ2USB7sxcvgU=")
        #expect(try SafeBeautyPassword.hash("142857", saltBase64: Self.zeroSalt) == "B1IKgASI6vzLIzH/opVgCYLWKccrnumoxCMpeo6lb4Q=")
        #expect(try SafeBeautyPassword.hash("", saltBase64: Self.salt) == "Zy0sNHHMZXbjLWjbNkB2xkWD3Ja2OMwhdYr+jyGvWTs=")
        #expect(try SafeBeautyPassword.hash("رمزعبور", saltBase64: Self.salt) == "s5cNEtetfTjnKGGzZwH6g2CFvE4dj2bv32BBNZWQ/5A=")
        #expect(try SafeBeautyPassword.authPassword("142857", saltBase64: Self.salt) == "srK0bug0SqF5wWEw8eXgmev4lKFS7HEArhteCPRD9y8=")
        #expect(try SafeBeautyPassword.authPassword("142857", saltBase64: Self.zeroSalt) == "vIIU408nBD7q2O62wFjK5Pm3A2FI2rmPaRuwikSI3B4=")
        #expect(try SafeBeautyPassword.authPassword("رمزعبور", saltBase64: Self.salt) == "NAc7nrfcDipxAhQhadeaVCu3WRIl5u6KsIeXAuLRRL8=")
        #expect(throws: SafeBeautyPassword.Failure.saltNotBase64) { _ = try SafeBeautyPassword.hash("1", saltBase64: "!!!!") }
    }

    @Test func phoneNormalisationMatchesPhoneUtils() {
        #expect(SafeBeautyPhone.normalizeForLogin("0700123456") == "+93700123456")
        #expect(SafeBeautyPhone.normalizeForLogin("700 123 456") == "+93700123456")
        #expect(SafeBeautyPhone.normalizeForLogin("0093700123456") == "+93700123456")
        #expect(SafeBeautyPhone.normalizeForLogin("93700123456") == "+93700123456")
        #expect(SafeBeautyPhone.normalizeForLogin("۰۷۰۰۱۲۳۴۵۶") == "+93700123456", "Persian digits fold to ASCII")
        #expect(SafeBeautyPhone.normalizeForLogin("+1 (555) 123-4567") == "+15551234567")
    }

    /// The five steps against fixtures, and what is sent at each.
    @Test func signInFlow() async throws {
        let login = try fixture("safebeauty-login")
        let stub = Stub { r, _ in
            let url = r.url!.absoluteString
            if url.hasSuffix("/authenticateWithPassword") { return (200, login) }
            if url.contains("signInWithPassword") { return (200, signInReply(idToken: "id-1", email: "emu-admin@sb.app")) }
            if url.hasSuffix("/syncUidMap") { return (200, Data(#"{"result":{"synced":true}}"#.utf8)) }
            return (404, Data())
        }
        let client = SafeBeautyAdminClient(environment: .localEmulator, transport: stub)
        let s = try await client.signIn(phone: "0700 000 099", password: "Emulator-Admin-Only-1")
        #expect(s == SafeBeautyStoredSession(environment: .localEmulator, appUID: "emu-admin", name: "Emulator Admin", refreshToken: "refresh-1"))
        #expect((body(stub.requests[0])["data"] as? [String: String]) == ["phone": "+93700000099", "password": "Emulator-Admin-Only-1"])
        let expected = try SafeBeautyPassword.authPassword("Emulator-Admin-Only-1", saltBase64: "1CJxvlZWvq8/fgGME4x9+Q==")
        #expect(body(stub.requests[1])["password"] as? String == expected && body(stub.requests[1])["email"] as? String == "emu-admin@sb.app")
        #expect((body(stub.requests[2])["data"] as? [String: String]) == ["appUid": "emu-admin"])
        #expect(stub.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer id-1")
        #expect(stub.requests[2].url!.absoluteString == "http://127.0.0.1:5001/demo-safebeauty/us-central1/syncUidMap")
    }

    @Test func signInRefusals() async throws {
        func client(_ reply: String, uidMap: (Int, String) = (200, #"{"result":{"synced":true}}"#)) -> SafeBeautyAdminClient {
            SafeBeautyAdminClient(environment: .localEmulator, transport: Stub { r, _ in
                let url = r.url!.absoluteString
                if url.hasSuffix("/authenticateWithPassword") { return (200, Data(reply.utf8)) }
                if url.contains("signInWithPassword") { return (200, signInReply(idToken: "id-1")) }
                if url.hasSuffix("/syncUidMap") { return (uidMap.0, Data(uidMap.1.utf8)) }
                return (404, Data())
            })
        }
        await #expect(throws: SafeBeautyError.invalidPhoneOrPassword) { _ = try await client(#"{"result":{"mode":"INVALID"}}"#).signIn(phone: "0700000001", password: "x") }
        await #expect(throws: SafeBeautyError.notAdmin) {
            _ = try await client(#"{"result":{"mode":"REAL","uid":"u","role":"CUSTOMER","firebaseEmail":"u@sb.app","salt":"c2FsdHNhbHRzYWx0c2Fs"}}"#).signIn(phone: "0700000001", password: "x")
        }
        await #expect(throws: SafeBeautyError.rateLimited("Too many attempts. Please try again in 10 second(s).")) {
            _ = try await SafeBeautyAdminClient(environment: .localEmulator, transport: Stub { _, _ in
                (429, Data(#"{"error":{"message":"Too many attempts. Please try again in 10 second(s).","status":"RESOURCE_EXHAUSTED"}}"#.utf8))
            }).signIn(phone: "0700000001", password: "x")
        }
        await #expect(throws: SafeBeautyError.self) {
            _ = try await client(#"{"result":{"mode":"REAL","uid":"u","role":"ADMIN","firebaseEmail":"u@sb.app","salt":"c2FsdHNhbHRzYWx0c2Fs"}}"#,
                                 uidMap: (403, #"{"error":{"message":"appUid does not match the signed-in account.","status":"PERMISSION_DENIED"}}"#))
                .signIn(phone: "0700000001", password: "x")
        }
        await #expect(throws: SafeBeautyError.missingPassword) { _ = try await client("{}").signIn(phone: "", password: "") }
    }

    @Test func commissionFollowsTheServersFallbacks() {
        #expect(SafeBeautyCommission(storedPercent: 12, storedMaxDiscountFraction: 0.5).effectivePercent == 12)
        #expect(SafeBeautyCommission(storedPercent: nil, storedMaxDiscountFraction: nil).effectivePercent == 10)
        let bad = SafeBeautyCommission(storedPercent: 150, storedMaxDiscountFraction: 1)
        #expect(bad.effectivePercent == 10 && bad.storedIsIgnored && bad.effectiveMaxDiscountFraction == 0.9)
    }

    @Test func kabulWeekStartsOnSaturday() throws {
        // Friday 2026-10-09 09:00 UTC = 13:30 in Kabul.
        let friday = Date(timeIntervalSince1970: 1_791_536_400)
        let week = SafeBeautyCalendar.week(friday)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kabul")!
        #expect(c.component(.weekday, from: week.start) == 7, "Saturday")
        #expect(c.dateComponents([.year, .month, .day, .hour], from: week.start) == DateComponents(year: 2026, month: 10, day: 3, hour: 0))
        #expect(week.duration == 7 * 86400)
        let day = SafeBeautyCalendar.today(friday)
        #expect(c.dateComponents([.day, .hour], from: day.start) == DateComponents(day: 9, hour: 0))
    }

    @Test func balancesAndPeopleFromFixtures() throws {
        let page = try JSONDecoder().decode([String: [FirestoreDocument]].self, from: fixture("safebeauty-balances"))
        #expect(page["documents"]?.compactMap { $0["owedAmount"]?.number }.sorted() == [-300, 4200])
        struct Row: Decodable { let document: FirestoreDocument? }
        let people = try JSONDecoder().decode([Row].self, from: fixture("safebeauty-kyc-query")).compactMap(\.document).map(SafeBeautyPerson.init)
        #expect(people.count == 2 && people.allSatisfy { $0.kycStatus == "PENDING" } && people.contains { $0.role == "PROVIDER" })
        #expect(people.allSatisfy { $0.joined != nil })
        #expect(!SafeBeautyPerson.mask.contains { $0.localizedCaseInsensitiveContains("tazkira") || $0.localizedCaseInsensitiveContains("selfie") || $0 == "phone" })
    }
}

// MARK: - VELRO

/// What the client handed to the Keychain, in order.
private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [VelroStoredSession?] = []
    var values: [VelroStoredSession?] { lock.withLock { _values } }
    func record(_ s: VelroStoredSession?) { lock.withLock { _values.append(s) } }
}

private func velroSession(access: String, refresh: String, roles: [String] = ["SUPER_ADMIN"]) -> Data {
    Data(#"{"success":true,"data":{"user_id":"u-1","access_token":"\#(access)","refresh_token":"\#(refresh)","roles":\#(String(decoding: try! JSONSerialization.data(withJSONObject: roles), as: UTF8.self)),"is_new_user":false,"expires_in_seconds":900},"message":null,"meta":{}}"#.utf8)
}

private let stored = VelroStoredSession(environment: .localBackend, userID: "u-1", roles: ["SUPER_ADMIN"], refreshToken: "refresh-old-000000", deviceID: "dev-1")

@Suite("VELRO staff")
struct VelroTests {
    @Test func decodesLocalBackendCaptures() throws {
        struct E<T: Decodable>: Decodable { let data: T }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let dash = try d.decode(E<VelroDashboard>.self, from: fixture("velro-dashboard")).data
        #expect(dash.attention.pendingDrivers == 2 && dash.today.trips == 3 && dash.activeTrips == 0 && dash.network.stations == 427 && dash.finance.currency == "AFN")
        #expect(VelroDates.instant(dash.generatedAt) != nil, "microsecond timestamps parse")
        let drivers = try d.decode(E<[VelroDriver]>.self, from: fixture("velro-drivers-pending")).data
        #expect(drivers.count == 2 && drivers.allSatisfy { $0.approvalStatus == "PENDING" } && drivers.contains { $0.fullName == "راننده آزمایشی" })
        let docs = try d.decode(E<VelroDocumentChecklist>.self, from: fixture("velro-driver-documents")).data
        #expect(docs.missing == ["LICENSE", "NATIONAL_ID", "SELFIE"] && !docs.canWork)
        let trips = try d.decode(E<[VelroTrip]>.self, from: fixture("velro-trips")).data
        #expect(trips.count == 3 && trips[0].number == "VLR-2026-000003" && trips[0].departure != nil && trips[0].bookedSeats == 0)
        let stations = try d.decode(E<[VelroStation]>.self, from: fixture("velro-stations")).data
        #expect(stations.count == 3 && stations[0].code == "GRB-SHA-001-S1")
        let routes = try d.decode(E<[VelroRoute]>.self, from: fixture("velro-routes")).data
        #expect(routes[0].fareMinor == 50_000 && routes[0].distanceM == 45_000)
        let otp = try d.decode(E<VelroOtpSent>.self, from: fixture("velro-otp-request")).data
        #expect(otp.expiresInSeconds == 300 && otp.debugCode == nil)
        #expect(VelroDates.instant("2026-10-09T09:00:00-04:00") == Date(timeIntervalSince1970: 1_791_550_800))
    }

    @Test func readsAndCommissionThroughTheClient() async throws {
        let stub = Stub { r, _ in
            let path = r.url!.path
            if path.hasSuffix("/auth/refresh") { return (200, velroSession(access: jwt(["exp": Date.now.timeIntervalSince1970 + 900]), refresh: "refresh-new-00000")) }
            if path.hasSuffix("/admin/settings") { return (200, try fixture("velro-settings")) }
            if path.hasSuffix("/admin/stations") { return (200, try fixture("velro-stations")) }
            if path.hasSuffix("/admin/drivers") { return (200, try fixture("velro-drivers-pending")) }
            return (404, Data())
        }
        let client = VelroStaffClient(environment: .localBackend, transport: stub, persist: { _ in })
        await client.restore(stored)
        #expect(try await client.commission() == VelroCommission(basisPoints: 1000))
        let st = try await client.stations()
        #expect(st.items.count == 3 && st.total == 427, "the total comes from meta")
        _ = try await client.pendingDrivers()
        let q = URLComponents(url: stub.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.contains(URLQueryItem(name: "approval_status", value: "PENDING")))
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" || $0.url!.path.hasSuffix("/auth/refresh") }, "reads only")
        #expect(VelroCommission(basisPoints: 12_000).isOutOfRange && VelroCommission(basisPoints: 1000).percent == 10)
    }

    @Test func verifyRefusesNonStaffAndKeepsNoPhone() async throws {
        let passenger = Stub { _, _ in (200, velroSession(access: "a", refresh: "refresh-x-0000000", roles: ["PASSENGER"])) }
        let saved = Saved()
        await #expect(throws: VelroError.notStaff) {
            _ = try await VelroStaffClient(environment: .localBackend, transport: passenger, persist: saved.record).verify(phone: "+93700000010", code: "12345", deviceID: "d")
        }
        #expect(saved.values.isEmpty, "nothing stored for a non-staff session")

        let staff = Stub { _, _ in (200, velroSession(access: "a", refresh: "refresh-x-0000000", roles: ["DISPATCHER"])) }
        let s = try await VelroStaffClient(environment: .localBackend, transport: staff, persist: saved.record).verify(phone: " +93700000077 ", code: " 12345 ", deviceID: "d")
        #expect(body(staff.requests[0]) as NSDictionary == ["phone": "+93700000077", "code": "12345", "device_id": "d", "locale": "en"] as NSDictionary)
        #expect(!s.canReadSettings && s.canReadDocuments)
        #expect(!String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("700000077"))

        let req = Stub { _, _ in (200, try fixture("velro-otp-request")) }
        _ = try await VelroStaffClient(environment: .localBackend, transport: req, persist: { _ in }).requestCode(phone: "+93700000077")
        #expect(body(req.requests[0])["audience"] as? String == "staff")
    }

    /// The rotation rules, one by one.
    @Test func refreshRotationIsPersistedBeforeUse() async throws {
        let saved = Saved()
        let stub = Stub { r, _ in
            if r.url!.path.hasSuffix("/auth/refresh") {
                // Present the token the client holds; answer with a new one.
                #expect(body(r)["refresh_token"] as? String == "refresh-old-000000" && body(r)["device_id"] as? String == "dev-1")
                #expect(saved.values.isEmpty, "nothing written before the server answered")
                return (200, velroSession(access: jwt(["exp": Date.now.timeIntervalSince1970 + 900]), refresh: "refresh-new-000000"))
            }
            // By the time the new access token is used, the Keychain already has the new refresh token.
            #expect(saved.values.last??.refreshToken == "refresh-new-000000")
            return (200, try fixture("velro-dashboard"))
        }
        let client = VelroStaffClient(environment: .localBackend, transport: stub, persist: saved.record)
        await client.restore(stored)
        #expect(try await client.dashboard().attention.pendingDrivers == 2)
        #expect(await client.current?.refreshToken == "refresh-new-000000" && saved.values.count == 1)
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let stub = Stub { r, _ in
            if r.url!.path.hasSuffix("/auth/refresh") { return (200, velroSession(access: jwt(["exp": Date.now.timeIntervalSince1970 + 900]), refresh: "refresh-new-000000")) }
            return (200, try fixture(r.url!.path.hasSuffix("/stations") ? "velro-stations" : "velro-dashboard"))
        }
        let client = VelroStaffClient(environment: .localBackend, transport: stub, persist: { _ in })
        await client.restore(stored)
        async let a = client.dashboard()
        async let b = client.stations()
        async let c = client.dashboard()
        _ = try await (a, b, c)
        #expect(stub.requests.filter { $0.url!.path.hasSuffix("/auth/refresh") }.count == 1, "one refresh for three requests")
    }

    @Test func lostRefreshAnswerDropsTheSessionInsteadOfReplaying() async throws {
        for failure in [URLError(.timedOut), URLError(.networkConnectionLost)] {
            let saved = Saved()
            let stub = Stub { _, _ in throw failure }
            let client = VelroStaffClient(environment: .localBackend, transport: stub, persist: saved.record)
            await client.restore(stored)
            await #expect(throws: VelroError.refreshOutcomeUnknown) { _ = try await client.dashboard() }
            let current = await client.current
            #expect(saved.values == [nil] && current == nil, "removed from the Keychain; the old token is never sent again")
            await #expect(throws: VelroError.notSignedIn) { _ = try await client.dashboard() }
            #expect(stub.requests.count == 1)
        }
        for status in [502, 504] {
            let saved = Saved()
            let client = VelroStaffClient(environment: .localBackend, transport: Stub { _, _ in (status, Data("Bad Gateway".utf8)) }, persist: saved.record)
            await client.restore(stored)
            await #expect(throws: VelroError.refreshOutcomeUnknown) { _ = try await client.dashboard() }
            #expect(saved.values == [nil])
        }
    }

    @Test func refreshThatNeverLeftKeepsTheSession() async throws {
        let saved = Saved()
        let client = VelroStaffClient(environment: .localBackend, transport: Stub { _, _ in throw URLError(.notConnectedToInternet) }, persist: saved.record)
        await client.restore(stored)
        await #expect(throws: VelroError.self) { _ = try await client.dashboard() }
        let kept = await client.current
        #expect(saved.values.isEmpty && kept == stored)

        // The backend refused with a 500 or 429: its transaction rolled back, the stored token is still current.
        let busy = VelroStaffClient(environment: .localBackend, transport: Stub { _, _ in (500, Data(#"{"success":false,"error":{"code":"INTERNAL_ERROR"}}"#.utf8)) }, persist: saved.record)
        await busy.restore(stored)
        await #expect(throws: VelroError.server(status: 500, code: "INTERNAL_ERROR")) { _ = try await busy.dashboard() }
        let stillKept = await busy.current
        #expect(saved.values.isEmpty && stillKept == stored)
    }

    @Test func refusedRefreshEndsTheSession() async throws {
        let saved = Saved()
        let client = VelroStaffClient(environment: .localBackend, transport: Stub { _, _ in
            (401, Data(#"{"success":false,"error":{"code":"REFRESH_TOKEN_REVOKED","message_key":"error.refresh_token_revoked","context":{},"request_id":"r"}}"#.utf8))
        }, persist: saved.record)
        await client.restore(stored)
        await #expect(throws: VelroError.sessionEnded(code: "REFRESH_TOKEN_REVOKED")) { _ = try await client.dashboard() }
        #expect(saved.values == [nil] && VelroError.sessionEnded(code: "x").needsSignIn)
    }

    @Test func errorCodes() {
        func e(_ s: Int, _ code: String) -> VelroError { VelroError.from(status: s, data: Data(#"{"success":false,"error":{"code":"\#(code)"}}"#.utf8)) }
        #expect(e(401, "OTP_INVALID") == .otpInvalid)
        #expect(e(401, "OTP_EXPIRED") == .otpExpired)
        #expect(e(429, "OTP_RATE_LIMITED") == .otpRateLimited)
        #expect(e(401, "OTP_ATTEMPTS_EXCEEDED") == .otpAttemptsExceeded)
        #expect(e(403, "PERMISSION_DENIED") == .permissionDenied)
        #expect(VelroEnvironment.offered(includeLocal: false) == [.production])
        #expect(VelroEnvironment.production.apiBase.absoluteString == "https://api.velro.linumic.com/api/v1")
    }
}

// MARK: - Operations

@Suite("Operations queues")
struct OperationsQueueTests {
    private func c(_ q: OperationsQueue, _ n: Int, _ env: String = "production") -> OperationsCount {
        OperationsCount(queue: q, count: n, environment: env, readAt: Date(timeIntervalSince1970: 0))
    }

    @Test func onlyZeroToMoreCounts() {
        let previous = [c(.talarHalls, 0), c(.safeBeautyKYC, 2), c(.velroDrivers, 0, "localBackend")]
        let current = [c(.talarHalls, 3), c(.safeBeautyKYC, 5), c(.velroDrivers, 1), c(.safeBeautyApprovals, 4)]
        // talarHalls 0 -> 3: yes. KYC 2 -> 5: already waiting. velroDrivers: other environment. approvals: never read.
        #expect(OperationsTransitions.newlyWaiting(previous: previous, current: current).map(\.queue) == [.talarHalls])
        #expect(OperationsTransitions.newlyWaiting(previous: [c(.talarHalls, 1)], current: [c(.talarHalls, 0)]).isEmpty)
    }

    @Test func storeKeepsCountsOnly() throws {
        let suite = "lcc-ops-test-\(UUID().uuidString)"
        let store = OperationsCountStore(defaults: { UserDefaults(suiteName: suite)! })
        #expect(store.record([c(.talarHalls, 0), c(.velroDrivers, 2)]).isEmpty, "first read: nothing to compare with")
        #expect(store.record([c(.talarHalls, 2)]).map(\.queue) == [.talarHalls])
        #expect(store.load().map(\.queue) == [.talarHalls, .velroDrivers], "other queues kept")
        store.forget(.talar)
        #expect(store.load().map(\.queue) == [.velroDrivers])
        let raw = String(decoding: try #require(UserDefaults(suiteName: suite)!.data(forKey: OperationsCountStore.key)), as: UTF8.self)
        #expect(raw.contains("\"count\":2") && !raw.contains("name"))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test func titlesAndProducts() {
        #expect(OperationsQueue.dashboard.map(\.product) == [.talar, .safeBeauty, .safeBeauty, .velro])
        #expect(OperationsQueue.velroDrivers.sentence(3) == "VELRO: 3 drivers waiting for approval")
    }
}

@Suite("Operations action log")
struct OperationsActionLogTests {
    @Test func appendsAndNeverDrops() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ops-log-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = OperationsActionLog(fileURL: url)
        #expect(try await log.load().isEmpty)
        let a = OperationsActionRecord(at: Date(timeIntervalSince1970: 10), product: .talar, environment: "localEmulator", actor: "admin@linumic.test",
                                       action: "hall.review_approve", targetID: "h1", targetName: "Hall", detail: nil, outcome: .verified, message: nil)
        var b = a
        b.id = UUID()
        b.at = Date(timeIntervalSince1970: 20)
        b.outcome = .failed
        try await log.append(a)
        try await log.append(b)
        #expect(try await log.load().map(\.outcome) == [.failed, .verified], "newest first")
    }
}
