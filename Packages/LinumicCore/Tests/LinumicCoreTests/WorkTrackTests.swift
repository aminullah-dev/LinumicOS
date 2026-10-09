import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. worktrack-{companies,orders,revenue,plans,me}.json were captured from the local Firebase
// emulator (project demo-worktrack, emulator sample companies) on 2026-10-09; worktrack-detail.json and
// worktrack-audit.json are written by hand to the server's schema. None of it is real customer data.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private struct Envelope<T: Decodable>: Decodable { let data: T }

private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(Envelope<T>.self, from: try fixture(name)).data
}

private final class Recorder: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: @Sendable (URLRequest, Int) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> (Int, String)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = lock.withLock { _requests.append(request); return _requests.count }
        let (status, body) = handler(request, n)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let signInReply = #"{"idToken":"id-1","refreshToken":"refresh-1","expiresIn":"3600","localId":"uid-1","email":"vendor@linumic.test"}"#
private let refreshReply = #"{"id_token":"id-2","refresh_token":"refresh-2","expires_in":"3600","user_id":"uid-1"}"#

private func license(expiresAt: String? = "2026-10-19", status: WTLicenseStatus = .active, plan: WTPlan = .silver) -> WTLicense {
    WTLicense(plan: plan, deviceLimit: 30, status: status, expiresAt: expiresAt, enforceDevices: true, enforcePlan: true,
              employeeLimit: 60, extraFeatures: ["projects"], source: "SELF_SERVE")
}

private func json(_ write: WTLicenseWrite) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any])
}

@Suite("WorkTrack vendor models")
struct WorkTrackDecodingTests {
    @Test func companiesDecodeFromEmulatorCapture() throws {
        let companies = try decode([WTCompany].self, "worktrack-companies")
        #expect(companies.count == 6)
        let herat = try #require(companies.first { $0.companyId == "emu_herat" })
        #expect(herat.name == "شرکت آزمایشی هرات")
        #expect(herat.license == WTLicense(plan: .silver, deviceLimit: 30, status: .active, expiresAt: "2026-10-19", enforceDevices: true,
                                           enforcePlan: true, employeeLimit: 60, extraFeatures: ["projects"], source: "SELF_SERVE"))
        #expect(herat.daysUntilExpiry == 10)
        #expect(herat.employeeCap == 60)
        #expect(herat.attention.first == WTAttention(code: "LICENCE_EXPIRING", severity: "medium"))
        let test = try #require(companies.first { $0.companyId == "emu_test" })
        #expect(test.flags?.isTest == true)
        let kabul = try #require(companies.first { $0.companyId == "comp_kabul" })
        #expect(kabul.license.expiresAt == nil && kabul.daysUntilExpiry == nil, "no licence on file = perpetual default")
    }

    @Test func standingAndFilters() throws {
        let companies = try decode([WTCompany].self, "worktrack-companies")
        func c(_ id: String) -> WTCompany { companies.first { $0.companyId == id }! }
        #expect(c("emu_mazar").standing == .lapsed, "20 days past, beyond the 7-day grace")
        #expect(c("emu_herat").standing == .active)
        #expect(c("emu_perpetual").standing == .perpetual)
        #expect(companies.filter(WTCompanyFilter.expiring30.matches).map(\.companyId).sorted() == ["emu_herat", "emu_test", "emu_trial"])
        #expect(companies.filter(WTCompanyFilter.expired.matches).map(\.companyId) == ["emu_mazar"])
        #expect(companies.filter(WTCompanyFilter.trial.matches).map(\.companyId) == ["emu_trial"])
        #expect(!WTCompanyFilter.attention.matches(c("emu_test")), "a TEST mark is info, not attention")

        var grace = c("emu_mazar")
        grace.daysUntilExpiry = -7
        #expect(grace.standing == .grace)
        grace.license.status = .suspended
        #expect(grace.standing == .lapsed)
    }

    @Test func summaryLeavesOutFlaggedCompanies() throws {
        let s = WTCustomersSummary(companies: try decode([WTCompany].self, "worktrack-companies"))
        #expect(s.total == 6)
        #expect(s.flagged == 1)
        #expect(s.expiringSoon.map(\.companyId) == ["emu_trial", "emu_herat"], "the TEST company (3 days) is left out; soonest first")
        #expect(s.expired.map(\.companyId) == ["emu_mazar"])
        #expect(s.trials == 1)
    }

    @Test func detailDecodesEveryTimelineKind() throws {
        let d = try decode(WTCompanyDetail.self, "worktrack-detail")
        #expect(d.company.companyId == "emu_herat")
        #expect(d.contacts.first?.primary == true && d.contacts.first?.phone == nil)
        #expect(d.timeline.count == 6)
        guard case .licence(_, let by, let before, let after) = d.timeline[0] else { Issue.record("expected LICENCE"); return }
        #expect(by == "vendor@linumic.test")
        #expect(before?.expiresAt == "2026-10-19" && after?.expiresAt == "2026-11-19" && after?.source == "VENDOR")
        guard case .flags(_, _, let flags) = d.timeline[1] else { Issue.record("expected FLAGS"); return }
        #expect(flags == nil, "a cleared mark")
        guard case .ticket(_, let id, _, _, _, let resolved) = d.timeline[2] else { Issue.record("expected TICKET"); return }
        #expect(id == "t_1" && resolved == "2026-09-26")
        guard case .order(_, let order, let status, _, let term, let months, let amount, let tx) = d.timeline[3] else { Issue.record("expected ORDER"); return }
        #expect(order == "emu_order_1" && status == "PAID" && term == "MONTHLY" && months == 1 && amount == 3500 && tx == "emu-tx-1")
        #expect(d.timeline[4] == .other(kind: "SOMETHING_NEW", at: "2026-09-01T00:00:00.000Z"), "an unknown kind doesn't break the detail")
        #expect(d.timeline[5] == .signup(at: "2026-08-30T05:00:50.682Z"))
    }

    @Test func ordersRevenuePlansMeAudit() throws {
        let orders = try decode([WTOrder].self, "worktrack-orders")
        #expect(orders.map(\.id) == ["emu_order_1"] && orders[0].paidAt != nil && orders[0].checkoutUrl == nil)

        let r = try decode(WTRevenue.self, "worktrack-revenue")
        #expect(r.currency == "AFN" && r.earned.totalAfn == 3500 && r.earned.byMonth.first?.year == 1405)
        #expect(r.expected.windowDays == 30 && r.expected.renewals.first?.basis == "LAST_PAID_TERM")
        #expect(r.excluded.companyCount == 1)

        let plans = try decode([String: WTPlanDef].self, "worktrack-plans")
        #expect(plans.keys.sorted() == ["BRONZE", "GOLD", "SILVER", "TRIAL"])
        #expect(plans["SILVER"]?.deviceLimit == 75 && plans["TRIAL"]?.purchasable == false)

        let me = try decode(WTVendorMe.self, "worktrack-me")
        #expect(me.vendor && me.email == "vendor@linumic.test")

        let audit = try decode([WTAuditEntry].self, "worktrack-audit")
        #expect(audit.count == 2)
        #expect(audit[0].after?.asLicense?.expiresAt == "2026-11-19")
        #expect(audit[1].before == .null || audit[1].before == nil)
        #expect(audit[1].after?.compact == "{GOLD: {priceAfn: 7500}}")
    }

    @Test func legacyLicenceFillsMissingFieldsLikeTheServer() throws {
        let l = try JSONDecoder().decode(WTLicense.self, from: Data(#"{"plan":"SILVER","deviceLimit":12,"status":"ACTIVE","expiresAt":"2027-01-01","enforceDevices":true}"#.utf8))
        #expect(l.enforcePlan == false && l.employeeLimit == nil && l.extraFeatures.isEmpty && l.source == "VENDOR")
    }

    @Test func problemJSONMapsToClearErrors() {
        func problem(_ status: Int, _ code: String, _ detail: String, fields: String = "") -> Data {
            Data(#"{"type":"x","title":"\#(code)","status":\#(status),"code":"\#(code)","detail":"\#(detail)"\#(fields)}"#.utf8)
        }
        #expect(WorkTrackError.from(status: 401, data: problem(401, "UNAUTHENTICATED", "Token is invalid, expired or revoked")) == .unauthenticated("Token is invalid, expired or revoked"))
        #expect(WorkTrackError.from(status: 403, data: problem(403, "PERMISSION_DENIED", "Not permitted")) == .notVendor)
        #expect(WorkTrackError.from(status: 403, data: problem(403, "PERMISSION_DENIED", "Verify your email address first")) == .emailNotVerified)
        #expect(WorkTrackError.from(status: 404, data: problem(404, "NOT_FOUND", "Company not found")) == .notFound("Company not found"))
        #expect(WorkTrackError.from(status: 422, data: problem(422, "VALIDATION_FAILED", "Request body failed validation", fields: #","fieldErrors":{"expiresAt":"Use YYYY-MM-DD"}"#))
                == .validation(detail: "Request body failed validation", fieldErrors: ["expiresAt": "Use YYYY-MM-DD"]))
        #expect(WorkTrackError.from(status: 500, data: Data("oops".utf8)) == .server(status: 500, code: "", detail: "oops"))
        #expect(WorkTrackError.unauthenticated("x").needsSignIn && WorkTrackError.auth(.sessionExpired).needsSignIn && !WorkTrackError.notVendor.needsSignIn)
    }

    @Test func firebaseErrorsMap() {
        func err(_ m: String) -> Data { Data(#"{"error":{"code":400,"message":"\#(m)"}}"#.utf8) }
        #expect(FirebaseAuthError.from(data: err("INVALID_LOGIN_CREDENTIALS"), status: 400, refreshing: false) == .invalidCredentials)
        #expect(FirebaseAuthError.from(data: err("TOO_MANY_ATTEMPTS_TRY_LATER : Access to this account has been temporarily disabled"), status: 400, refreshing: false) == .tooManyAttempts)
        #expect(FirebaseAuthError.from(data: err("TOKEN_EXPIRED"), status: 400, refreshing: true) == .sessionExpired)
        #expect(FirebaseAuthError.from(data: err("USER_DISABLED"), status: 400, refreshing: true) == .sessionExpired)
        #expect(FirebaseAuthError.from(data: err("USER_DISABLED"), status: 400, refreshing: false) == .userDisabled)
        #expect(FirebaseAuthError.from(data: err("API key not valid. Please pass a valid API key."), status: 400, refreshing: false) == .apiKeyRejected("API_KEY_INVALID"))
    }

    @Test func environmentsAndEmulatorOnlyWhenAsked() {
        #expect(WorkTrackEnvironment.offered(includeEmulator: false) == [.production, .demo])
        #expect(WorkTrackEnvironment.offered(includeEmulator: true).contains(.localEmulator))
        #expect(WorkTrackEnvironment.production.apiBase.absoluteString == "https://worktrack-prod.web.app/v1")
        #expect(WorkTrackEnvironment.demo.apiBase.absoluteString == "https://worktrack-demo-af.web.app/v1")
        #expect(WorkTrackEnvironment.localEmulator.auth.identityToolkit.absoluteString == "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1")
        #expect(WorkTrackEnvironment.production.auth.identityToolkit.host == "identitytoolkit.googleapis.com")
        #expect(WorkTrackVendorClient.url(WorkTrackEnvironment.demo.apiBase, ["vendor", "companies", "a/b c", "detail"]).absoluteString
                == "https://worktrack-demo-af.web.app/v1/vendor/companies/a%2Fb%20c/detail")
    }
}

@Suite("WorkTrack vendor client")
struct WorkTrackClientTests {
    @Test func signInThenReadSendsBearerAndNeverKeepsThePassword() async throws {
        let t = Recorder { req, _ in
            if req.url!.path.hasSuffix("accounts:signInWithPassword") { return (200, signInReply) }
            return (200, #"{"data":{"uid":"uid-1","email":"vendor@linumic.test","vendor":true}}"#)
        }
        let client = WorkTrackVendorClient(environment: .demo, transport: t)
        let session = try await client.signIn(email: " vendor@linumic.test ", password: "s3cret")
        #expect(session == WorkTrackStoredSession(environment: .demo, email: "vendor@linumic.test", refreshToken: "refresh-1"))
        let me = try await client.me()
        #expect(me.vendor)
        let signIn = t.requests[0]
        #expect(signIn.url?.absoluteString == "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyA1Kb5qR8UKXLTkpR3o0Qz7xPUT9i7wAxo")
        let body = try #require(JSONSerialization.jsonObject(with: signIn.httpBody!) as? [String: Any])
        #expect(body["email"] as? String == "vendor@linumic.test" && body["password"] as? String == "s3cret" && body["returnSecureToken"] as? Bool == true)
        let read = t.requests[1]
        #expect(read.httpMethod == "GET" && read.url?.absoluteString == "https://worktrack-demo-af.web.app/v1/vendor/me")
        #expect(read.value(forHTTPHeaderField: "Authorization") == "Bearer id-1")
        #expect(!String(describing: session).contains("s3cret"))
    }

    @Test func restoredSessionRefreshesFirst() async throws {
        let t = Recorder { req, _ in
            req.url!.host == "securetoken.googleapis.com" ? (200, refreshReply) : (200, #"{"data":[]}"#)
        }
        let client = WorkTrackVendorClient(environment: .production, transport: t)
        await client.restore(refreshToken: "stored-refresh")
        let list = try await client.companies()
        #expect(list.isEmpty)
        let refresh = t.requests[0]
        #expect(refresh.url?.absoluteString == "https://securetoken.googleapis.com/v1/token?key=AIzaSyBhGGgbBqhdsJYpM9FpQld28jyhvEfqWPA")
        #expect(String(data: refresh.httpBody!, encoding: .utf8) == "grant_type=refresh_token&refresh_token=stored-refresh")
        #expect(t.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer id-2")
        #expect(await client.currentRefreshToken == "refresh-2")
    }

    @Test func aGetIsRetriedOnceAfter401WithAFreshToken() async throws {
        let t = Recorder { req, n in
            if req.url!.host == "securetoken.googleapis.com" { return (200, refreshReply) }
            if req.url!.path.hasSuffix("signInWithPassword") { return (200, signInReply) }
            return n == 2 ? (401, #"{"code":"UNAUTHENTICATED","detail":"Token is invalid, expired or revoked"}"#) : (200, #"{"data":[]}"#)
        }
        let client = WorkTrackVendorClient(environment: .demo, transport: t)
        _ = try await client.signIn(email: "v@x", password: "p")
        _ = try await client.audit()
        #expect(t.requests.count == 4, "sign-in, GET (401), refresh, GET")
        #expect(t.requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer id-2")
    }

    @Test func theLicencePutIsNeverRetriedAndAlwaysCarriesExpiresAt() async throws {
        let t = Recorder { req, _ in
            if req.url!.path.hasSuffix("signInWithPassword") { return (200, signInReply) }
            return (401, #"{"code":"UNAUTHENTICATED","detail":"Token is invalid, expired or revoked"}"#)
        }
        let client = WorkTrackVendorClient(environment: .demo, transport: t)
        _ = try await client.signIn(email: "v@x", password: "p")
        let write = try WorkTrackRenewal.makeWrite(current: license(), input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), today: "2026-10-09")
        await #expect(throws: WorkTrackError.unauthenticated("Token is invalid, expired or revoked")) {
            _ = try await client.putLicense(companyID: "emu_herat", write)
        }
        #expect(t.requests.count == 2, "no refresh-and-resend for a write")
        let put = t.requests[1]
        #expect(put.httpMethod == "PUT" && put.url?.path == "/v1/vendor/companies/emu_herat/license")
        let body = try #require(JSONSerialization.jsonObject(with: put.httpBody!) as? [String: Any])
        #expect(body["expiresAt"] as? String == "2026-11-19")
    }

    @Test func notVendorAndUnverifiedSurfaceAsSuch() async throws {
        let t = Recorder { req, _ in
            if req.url!.path.hasSuffix("signInWithPassword") { return (200, signInReply) }
            return (403, #"{"type":"x","title":"PERMISSION_DENIED","status":403,"code":"PERMISSION_DENIED","detail":"Not permitted"}"#)
        }
        let client = WorkTrackVendorClient(environment: .demo, transport: t)
        _ = try await client.signIn(email: "v@x", password: "p")
        await #expect(throws: WorkTrackError.notVendor) { _ = try await client.me() }
    }

    @Test func wrongPasswordIsAClearError() async {
        let t = Recorder { _, _ in (400, #"{"error":{"code":400,"message":"INVALID_LOGIN_CREDENTIALS"}}"#) }
        let client = WorkTrackVendorClient(environment: .production, transport: t)
        await #expect(throws: WorkTrackError.auth(.invalidCredentials)) { _ = try await client.signIn(email: "v@x", password: "wrong") }
    }

    @Test func notSignedInThrowsBeforeAnyRequest() async {
        let t = Recorder { _, _ in (200, "{}") }
        let client = WorkTrackVendorClient(environment: .production, transport: t)
        await #expect(throws: WorkTrackError.notSignedIn) { _ = try await client.companies() }
        #expect(t.requests.isEmpty)
    }
}

@Suite("WorkTrack renewal request")
struct WorkTrackRenewalTests {
    let today = "2026-10-09"

    @Test func renewalCopiesEveryUnchangedFieldFromTheFetchedLicence() throws {
        let current = license()
        let write = try WorkTrackRenewal.makeWrite(current: current, input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), today: today)
        let body = try json(write)
        #expect(Set(body.keys) == ["plan", "deviceLimit", "status", "expiresAt", "enforceDevices", "enforcePlan", "employeeLimit", "extraFeatures"])
        #expect(body["plan"] as? String == "SILVER")
        #expect(body["deviceLimit"] as? Int == 30)
        #expect(body["status"] as? String == "ACTIVE")
        #expect(body["expiresAt"] as? String == "2026-11-19")
        #expect(body["enforceDevices"] as? Bool == true)
        #expect(body["enforcePlan"] as? Bool == true)
        #expect(body["employeeLimit"] as? Int == 60)
        #expect(body["extraFeatures"] as? [String] == ["projects"])
        #expect(WorkTrackRenewal.mismatches(expected: write.expectedLicense, stored: WTLicense(plan: .silver, deviceLimit: 30, status: .active, expiresAt: "2026-11-19", enforceDevices: true, enforcePlan: true, employeeLimit: 60, extraFeatures: ["projects"], source: "VENDOR")).isEmpty)
    }

    /// The trap: an omitted `expiresAt` makes WorkTrack store a perpetual licence. The key must always be there.
    @Test func expiresAtIsNeverOmitted() throws {
        let dated = try WorkTrackRenewal.makeWrite(current: license(), input: WTRenewalInput(plan: .gold, deviceLimit: 40, status: .active, expiry: .date("2027-10-19")), today: today)
        let datedJSON = String(data: try JSONEncoder().encode(dated), encoding: .utf8)!
        #expect(datedJSON.contains(#""expiresAt":"2027-10-19""#))

        // Perpetual needs its own confirmation…
        #expect(throws: WTRenewalError.perpetualNotConfirmed) {
            try WorkTrackRenewal.makeWrite(current: license(), input: WTRenewalInput(plan: .gold, deviceLimit: 40, status: .active, expiry: .perpetual(confirmed: false)), today: today)
        }
        // …and even then the key is sent, explicitly null, never dropped.
        let perpetual = try WorkTrackRenewal.makeWrite(current: license(), input: WTRenewalInput(plan: .gold, deviceLimit: 40, status: .active, expiry: .perpetual(confirmed: true)), today: today)
        let perpetualJSON = String(data: try JSONEncoder().encode(perpetual), encoding: .utf8)!
        #expect(perpetualJSON.contains(#""expiresAt":null"#))
        #expect(try json(perpetual).keys.contains("expiresAt"))

        // A perpetual licence renewed to a date stays dated.
        let fromPerpetual = try WorkTrackRenewal.makeWrite(current: license(expiresAt: nil), input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-12-31")), today: today)
        #expect(fromPerpetual.expiresAt == "2026-12-31")
    }

    @Test func nullEmployeeCapIsSentAsNullNotDropped() throws {
        var current = license()
        current.employeeLimit = nil
        let write = try WorkTrackRenewal.makeWrite(current: current, input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), today: today)
        #expect(String(data: try JSONEncoder().encode(write), encoding: .utf8)!.contains(#""employeeLimit":null"#))
    }

    @Test func refusesWhatTheServerWouldRefuseOrMisread() {
        let base = license()
        func make(_ input: WTRenewalInput, current: WTLicense? = nil) throws { _ = try WorkTrackRenewal.makeWrite(current: current ?? base, input: input, today: today) }
        #expect(throws: WTRenewalError.dateInPast("2026-10-08")) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-10-08"))) }
        #expect(throws: WTRenewalError.invalidDate("2026-02-30")) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-02-30"))) }
        #expect(throws: WTRenewalError.invalidDate("19/11/2026")) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("19/11/2026"))) }
        #expect(throws: WTRenewalError.unknownPlan("PRO")) { try make(WTRenewalInput(plan: WTPlan(rawValue: "PRO"), deviceLimit: 30, status: .active, expiry: .date("2026-11-19"))) }
        #expect(throws: WTRenewalError.unwritableStatus("PAUSED")) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: WTLicenseStatus(rawValue: "PAUSED"), expiry: .date("2026-11-19"))) }
        #expect(throws: WTRenewalError.deviceLimitOutOfRange(0)) { try make(WTRenewalInput(plan: .silver, deviceLimit: 0, status: .active, expiry: .date("2026-11-19"))) }
        var odd = base
        odd.extraFeatures = ["projects", "teleport"]
        #expect(throws: WTRenewalError.unknownFeature("teleport")) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), current: odd) }
        // Today itself is a valid last day.
        #expect(throws: Never.self) { try make(WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-10-09"))) }
    }

    @Test func extensionCountsFromTheLaterOfTodayAndTheCurrentEnd() {
        #expect(WorkTrackRenewal.extended(license(expiresAt: "2026-10-19"), months: 1, today: today) == "2026-11-19")
        #expect(WorkTrackRenewal.extended(license(expiresAt: "2026-10-19"), months: 12, today: today) == "2027-10-19")
        #expect(WorkTrackRenewal.extended(license(expiresAt: "2026-09-19"), months: 1, today: today) == "2026-11-09", "expired: from today")
        #expect(WorkTrackRenewal.extended(license(expiresAt: nil), months: 12, today: today) == "2027-10-09", "perpetual: from today")
        #expect(WorkTrackDates.addMonths("2027-01-31", 1) == "2027-02-28", "clamped like lib/dates.ts addMonths")
        #expect(WorkTrackDates.addMonths("2028-01-31", 1) == "2028-02-29")
        #expect(WorkTrackDates.addMonths("2026-12-15", 1) == "2027-01-15")
        #expect(WorkTrackDates.addDays("2026-03-01", -1) == "2026-02-28")
        #expect(WorkTrackDates.daysBetween("2026-10-09", "2026-10-19") == 10)
    }

    @Test func kabulTodayCrossesMidnightBeforeUTC() {
        // 20:00 UTC is 00:30 the next day in Kabul (UTC+4:30).
        let instant = ISO8601DateFormatter().date(from: "2026-10-09T20:00:00Z")!
        #expect(WorkTrackDates.kabulToday(instant) == "2026-10-10")
        #expect(WorkTrackDates.kabulToday(ISO8601DateFormatter().date(from: "2026-10-09T19:00:00Z")!) == "2026-10-09")
    }

    @Test func expiredBecomesActiveButASuspensionStays() {
        #expect(WorkTrackRenewal.suggestedStatus(for: license(status: .expired)) == .active)
        #expect(WorkTrackRenewal.suggestedStatus(for: license(status: .suspended)) == .suspended)
        #expect(WorkTrackRenewal.suggestedStatus(for: license(status: .active)) == .active)
    }

    @Test func diffListsEveryFieldAndMarksTheChangedOnes() throws {
        let current = license()
        let write = try WorkTrackRenewal.makeWrite(current: current, input: WTRenewalInput(plan: .gold, deviceLimit: 30, status: .active, expiry: .date("2027-10-19")), today: today)
        let rows = WorkTrackRenewal.diff(current: current, write: write)
        #expect(rows.count == 9)
        #expect(rows.filter(\.changed).map(\.field) == ["Plan", "Last day (expiresAt)", "Source"])
        let expiry = try #require(rows.first { $0.field == "Last day (expiresAt)" })
        #expect(expiry.before == "2026-10-19" && expiry.after == "2027-10-19")
        let perpetual = try WorkTrackRenewal.makeWrite(current: current, input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .perpetual(confirmed: true)), today: today)
        #expect(WorkTrackRenewal.diff(current: current, write: perpetual).first { $0.field == "Last day (expiresAt)" }?.after == "Never (perpetual)")
    }

    @Test func verificationFindsWhatTheServerStoredDifferently() {
        let expected = license(expiresAt: "2027-10-19")
        var stored = expected
        stored.source = "VENDOR"
        var e = expected
        e.source = "VENDOR"
        #expect(WorkTrackRenewal.mismatches(expected: e, stored: stored).isEmpty)
        stored.expiresAt = nil
        #expect(WorkTrackRenewal.mismatches(expected: e, stored: stored).map(\.field) == ["Last day (expiresAt)"])
    }

    @Test func confirmationNeedsTheExactName() {
        #expect(WorkTrackRenewal.confirmationMatches("  شرکت آزمایشی هرات ", companyName: "شرکت آزمایشی هرات"))
        #expect(!WorkTrackRenewal.confirmationMatches("شرکت آزمایشی", companyName: "شرکت آزمایشی هرات"))
        #expect(!WorkTrackRenewal.confirmationMatches("", companyName: "X"))
    }
}

@Suite("WorkTrack reminders and action log")
struct WorkTrackReminderTests {
    @Test func remindersAt30_14_7_1ForActiveUnflaggedLicences() throws {
        let companies = try decode([WTCompany].self, "worktrack-companies")
        let r = WorkTrackReminder.schedule(for: companies, today: "2026-10-09")
        // emu_herat ends 2026-10-19: 7 days before = 10-12, 1 day = 10-18 (30 and 14 already passed).
        // emu_trial ends 10-14: 1 day = 10-13 (7 days before = 10-07 passed). emu_mazar ended. emu_test is flagged.
        #expect(r.map(\.id) == ["worktrack-emu_herat-2026-10-19-7", "worktrack-emu_trial-2026-10-14-1", "worktrack-emu_herat-2026-10-19-1"])
        #expect(r.first?.fireDay == "2026-10-12")
    }

    @Test func actionLogAppendsAndReadsBackNewestFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wt-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = WorkTrackActionLog(fileURL: dir.appending(path: "worktrack-actions.json"))
        #expect(try await log.load().isEmpty)
        let older = WorkTrackActionRecord(at: Date(timeIntervalSince1970: 1_000), environment: .localEmulator, actorEmail: "v@x", companyID: "a", companyName: "A",
                                          before: license(), sent: license(expiresAt: "2026-11-19"), stored: nil, outcome: .failed, message: "403")
        let newer = WorkTrackActionRecord(at: Date(timeIntervalSince1970: 2_000), environment: .localEmulator, actorEmail: "v@x", companyID: "b", companyName: "B",
                                          before: license(), sent: license(expiresAt: "2026-11-19"), stored: license(expiresAt: "2026-11-19"), outcome: .verified, message: nil)
        try await log.append(older)
        try await log.append(newer)
        let all = try await log.load()
        #expect(all.map(\.companyID) == ["b", "a"])
        #expect(all[0] == newer)
    }
}
