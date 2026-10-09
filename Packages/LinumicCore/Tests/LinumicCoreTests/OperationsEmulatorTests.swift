import Foundation
import Testing
@testable import LinumicCore

// Opt-in, LOCAL ONLY. Exercises the real Talar, SafeBeauty and VELRO clients against local emulators/backends,
// never a real project. Each suite is enabled by its own variable and fixes its environment to the local one.
//
//   LCC_TALAR_EMULATOR=1      swift test --package-path Packages/LinumicCore --filter liveTalar
//   LCC_SAFEBEAUTY_EMULATOR=1 swift test --package-path Packages/LinumicCore --filter liveSafeBeauty
//   LCC_VELRO_LOCAL=1         swift test --package-path Packages/LinumicCore --filter liveVelro
//
// Setup for each is in docs/integrations.md ("Operations: testing locally").

private let env = ProcessInfo.processInfo.environment

/// A document straight from a Firestore emulator, as the emulator's admin ("Bearer owner" bypasses rules).
private func emulatorDocuments(project: String, collection: String) async throws -> [[String: Any]] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/projects/\(project)/databases/(default)/documents/\(collection)?pageSize=300")!)
    request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (json["documents"] as? [[String: Any]]) ?? []
}

private func stringField(_ doc: [String: Any], _ name: String) -> String? {
    ((doc["fields"] as? [String: Any])?[name] as? [String: Any])?["stringValue"] as? String
}

@Suite("Talar local emulator (opt-in)", .enabled(if: env["LCC_TALAR_EMULATOR"] == "1"))
struct TalarEmulatorTests {
    let password = env["LCC_TALAR_PASSWORD"] ?? "Emulator-Admin-Only-1"

    @Test func liveTalarSignInReadsAndHallReview() async throws {
        let environment = TalarEnvironment.localEmulator
        #expect(environment.apiBase.host == "127.0.0.1" && environment.auth.identityToolkit.host == "127.0.0.1"
                && environment.firestore.documents.host == "127.0.0.1")
        let client = TalarAdminClient(environment: environment)
        let session = try await client.signIn(email: "admin@linumic.test", password: password)
        #expect(!session.refreshToken.isEmpty)

        let dashboard = try await client.dashboard()
        let halls = try await client.pendingHalls()
        let reviews = try await client.pendingReviews()
        let orgs = try await client.organizations()
        let overview = try await client.payoutOverview()
        let summary = TalarPayoutSummary(overview.rows, truncated: overview.truncated)
        print("EMULATOR talar dashboard:", dashboard)
        print("EMULATOR talar halls:", halls.map { "\($0.id) \($0.name.best(preferring: "en")) \($0.capacity?.total ?? 0) \($0.status)" })
        print("EMULATOR talar reviews:", reviews.map { "\($0.id) hall=\($0.hallId ?? "-") rating=\($0.rating)" })
        print("EMULATOR talar orgs:", orgs.map { "\($0.id) \($0.status) \($0.commissionPct ?? -1)" }, "pending payouts:", summary.pendingCount, summary.pendingNetMinor)
        #expect(dashboard.hallsAwaitingReview == halls.count)
        #expect(halls.contains { $0.id == "emu-hall-pending-1" && $0.capacity?.total == 800 && $0.hallFeeMinor == 25_000_000 })
        #expect(reviews.contains { $0.id == "emu-review-pending" && $0.hallId == "hall-aryana" })
        #expect(summary.pendingCount >= 1 && summary.organizationsFailed == 0)

        // The one write: approve one hall, reject the other with a reason; Talar audits both.
        let auditBefore = try await emulatorDocuments(project: "demo-talar", collection: "auditLogs").count
        try await client.reviewHall("emu-hall-pending-1", try TalarHallReviewWrite.make(decision: .approve, reason: ""))
        try await client.reviewHall("emu-hall-pending-2", try TalarHallReviewWrite.make(decision: .reject, reason: "Emulator test: photos missing"))
        let after = try await client.pendingHalls()
        #expect(!after.contains { $0.id.hasPrefix("emu-hall-pending") })
        let audit = try await emulatorDocuments(project: "demo-talar", collection: "auditLogs")
        let actions = audit.compactMap { stringField($0, "action") }
        print("EMULATOR talar audit actions:", actions)
        #expect(audit.count == auditBefore + 2)
        #expect(actions.contains("hall.review_approve") && actions.contains("hall.review_reject"))
        // Second attempt on a hall that is no longer pending: 409, nothing changes.
        await #expect(throws: TalarError.conflict("Hall is not awaiting review")) {
            try await client.reviewHall("emu-hall-pending-1", try TalarHallReviewWrite.make(decision: .approve, reason: ""))
        }
        await #expect(throws: TalarError.self) { try await client.reviewHall("no-such-hall", try TalarHallReviewWrite.make(decision: .approve, reason: "")) }

        // Error paths.
        let wrong = TalarAdminClient(environment: environment)
        await #expect(throws: TalarError.auth(.invalidCredentials)) { _ = try await wrong.signIn(email: "admin@linumic.test", password: "nope-nope") }
        let customer = TalarAdminClient(environment: environment)
        await #expect(throws: TalarError.notAdmin) { _ = try await customer.signIn(email: "customer@linumic.test", password: password) }
        let stale = TalarAdminClient(environment: environment)
        await stale.restore(refreshToken: "not-a-real-refresh-token")
        await #expect(throws: TalarError.auth(.sessionExpired)) { _ = try await stale.dashboard() }

        let restored = TalarAdminClient(environment: environment)
        await restored.restore(refreshToken: session.refreshToken)
        #expect(try await restored.dashboard().publishedHalls == dashboard.publishedHalls + 1)
    }
}

/// Records every request's URL and body, so the test can prove which fields were asked for.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [(url: String, body: String)] = []
    var log: [(url: String, body: String)] { lock.withLock { _log } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _log.append((request.url!.absoluteString, String(decoding: request.httpBody ?? Data(), as: UTF8.self))) }
        return try await URLSessionTransport().send(request)
    }
}

@Suite("SafeBeauty local emulator (opt-in)", .enabled(if: env["LCC_SAFEBEAUTY_EMULATOR"] == "1"))
struct SafeBeautyEmulatorTests {
    let password = env["LCC_SAFEBEAUTY_PASSWORD"] ?? "Emulator-Admin-Only-1"

    @Test func liveSafeBeautySignInAndEveryRead() async throws {
        let environment = SafeBeautyEnvironment.localEmulator
        #expect(environment.functionsBase.host == "127.0.0.1" && environment.firestore.documents.host == "127.0.0.1")
        let recorder = RecordingTransport()
        let client = SafeBeautyAdminClient(environment: environment, transport: recorder)
        // Typed the way an owner might: local form, spaces.
        let session = try await client.signIn(phone: "0700 000 099", password: password)
        #expect(session.appUID == "emu-admin" && !session.refreshToken.isEmpty)
        let stored = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!stored.contains("0700") && !stored.contains("+93") && !stored.contains(password), "no phone or password in the stored session")

        let s = try await client.snapshot()
        print("EMULATOR safebeauty: kyc=\(s.kycPendingCount) \(s.kycQueue.map { "\($0.name)/\($0.role)/\($0.kycStatus)" }) approvals=\(s.approvalPendingCount) \(s.approvalQueue.map(\.name))")
        print("EMULATOR safebeauty: salons=\(s.salonCount) verified=\(s.verifiedSalonCount) today=\(s.bookingsToday) week=\(s.bookingsThisWeek) [\(s.week.start) – \(s.week.end)]")
        print("EMULATOR safebeauty: owed=\(s.payoutsOwed.map { "\($0.name ?? $0.providerID) \($0.owedAmount)" }) refunds=\(s.refundRequestsPending) commission stored=\(s.commission.storedPercent ?? -1) effective=\(s.commission.effectivePercent)")
        #expect(s.kycPendingCount == 2 && Set(s.kycQueue.map(\.id)) == ["emu-kyc-1", "emu-kyc-2"])
        #expect(s.approvalPendingCount == 2 && Set(s.approvalQueue.map(\.id)) == ["emu-kyc-2", "emu-provider-1"])
        #expect(s.salonCount == 3 && s.verifiedSalonCount == 1)
        #expect(s.bookingsToday == 2)
        #expect(s.bookingsThisWeek >= 2 && s.bookingsThisWeek <= 3, "tomorrow may fall in the next Saturday-to-Friday week")
        #expect(s.payoutsOwed.map(\.providerID) == ["emu-provider-1"] && s.payoutsOwed.first?.name == "Herat Beauty (emulator)" && s.payoutsOwedTotal == 4200)
        #expect(s.refundRequestsPending == 1)
        #expect(s.commission.storedPercent == 12 && s.commission.effectivePercent == 12 && s.commission.effectiveMaxDiscountFraction == 0.5)

        // Identity documents are never asked for: every users query/get carries a mask without them.
        let userReads = recorder.log.filter { $0.body.contains("\"users\"") || $0.url.contains("/users") }
        #expect(!userReads.isEmpty)
        for r in recorder.log {
            #expect(!r.body.contains("tazkira") && !r.url.contains("tazkira") && !r.body.contains("selfie"))
        }
        // Nothing but reads: the only callables were the two sign-in steps; no Firestore write verbs.
        let callables = recorder.log.filter { $0.url.contains("/us-central1/") }.map { String($0.url.split(separator: "/").last!) }
        #expect(callables == ["authenticateWithPassword", "syncUidMap"])
        #expect(!recorder.log.contains { $0.url.contains(":commit") || $0.url.contains(":batchWrite") })

        // Error paths.
        let wrong = SafeBeautyAdminClient(environment: environment)
        await #expect(throws: SafeBeautyError.invalidPhoneOrPassword) { _ = try await wrong.signIn(phone: "+93700000099", password: "not-it") }
        let customer = SafeBeautyAdminClient(environment: environment)
        await #expect(throws: SafeBeautyError.notAdmin) { _ = try await customer.signIn(phone: "+93700000098", password: password) }
        let stale = SafeBeautyAdminClient(environment: environment)
        await stale.restore(refreshToken: "not-a-real-refresh-token")
        await #expect(throws: SafeBeautyError.auth(.sessionExpired)) { _ = try await stale.commission() }

        let restored = SafeBeautyAdminClient(environment: environment)
        await restored.restore(refreshToken: session.refreshToken)
        #expect(try await restored.commission().effectivePercent == 12)
    }
}

/// Collects what the client hands to the Keychain.
private final class PersistLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [VelroStoredSession?] = []
    var saved: [VelroStoredSession?] { lock.withLock { _saved } }
    func record(_ s: VelroStoredSession?) { lock.withLock { _saved.append(s) } }
}

@Suite("VELRO local backend (opt-in)", .enabled(if: env["LCC_VELRO_LOCAL"] == "1"))
struct VelroLocalTests {
    let staffPhone = env["LCC_VELRO_STAFF_PHONE"] ?? "+93700000077"

    /// The local backend echoes the code (dev-api.sh, VELRO_OTP_DEBUG_ECHO=true); production never does.
    private func signIn(_ client: VelroStaffClient, phone: String) async throws -> VelroStoredSession {
        let sent = try await client.requestCode(phone: phone)
        let code = try #require(sent.debugCode, "start the local API with VELRO_OTP_DEBUG_ECHO=true")
        return try await client.verify(phone: phone, code: code, deviceID: "linumic-os-test-device")
    }

    @Test func liveVelroSignInReadsAndRefreshRotation() async throws {
        let environment = VelroEnvironment.localBackend
        #expect(environment.apiBase.host == "127.0.0.1")
        let log = PersistLog()
        let client = VelroStaffClient(environment: environment, persist: log.record)
        let session = try await signIn(client, phone: staffPhone)
        #expect(VelroRoles.isStaff(session.roles) && session.canReadSettings)
        #expect(!String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("700000077"), "the phone number is not stored")

        let dashboard = try await client.dashboard()
        let drivers = try await client.pendingDrivers()
        let docs = try await client.documents(driverID: try #require(drivers.items.first).id)
        let active = try await client.activeTrips()
        let upcoming = try await client.upcomingTrips()
        let stations = try await client.stations()
        let routes = try await client.routes()
        let commission = try await client.commission()
        print("EMULATOR velro dashboard: pendingDrivers=\(dashboard.attention.pendingDrivers) pendingDocs=\(dashboard.attention.pendingDocuments) active=\(dashboard.activeTrips) today=\(dashboard.today.trips) completed=\(dashboard.today.completedTrips)")
        print("EMULATOR velro drivers:", drivers.items.map { "\($0.fullName ?? "-") \($0.approvalStatus)" }, "docs missing:", docs.missing)
        print("EMULATOR velro trips active=\(active.total) upcoming=\(upcoming.total) stations=\(stations.total) routes=\(routes.total) commission=\(commission.basisPoints ?? -1)")
        #expect(dashboard.attention.pendingDrivers == drivers.total && drivers.total >= 2)
        #expect(docs.required == ["LICENSE", "NATIONAL_ID", "SELFIE"] && !docs.canWork)
        #expect(stations.total > 0 && routes.total > 0)
        #expect(commission.basisPoints == VelroCommission.defaultBasisPoints && commission.percent == 10)

        // Refresh rotation: the new token is persisted before use, and differs from the old one.
        let before = try #require(await client.current).refreshToken
        _ = try await client.validAccessToken(forceRefresh: true)
        let after = try #require(await client.current).refreshToken
        #expect(after != before)
        #expect(log.saved.last??.refreshToken == after, "the rotated token went to the Keychain")
        #expect(try await client.dashboard().attention.pendingDrivers == dashboard.attention.pendingDrivers, "reads continue on the rotated token")

        // Two concurrent forced refreshes share one request (a second one would replay a rotated token).
        let savesBefore = log.saved.count
        async let a = client.validAccessToken(forceRefresh: true)
        async let b = client.validAccessToken(forceRefresh: true)
        let (ta, tb) = try await (a, b)
        #expect(ta == tb && log.saved.count == savesBefore + 1)
        let current = try #require(await client.current)

        // What a replay does on the server: the old token is refused (REFRESH_TOKEN_REVOKED). authenticate.py also
        // calls revoke_all_for_user, but the request transaction rolls back with the 401 (ui/api/session_scope.py
        // commits only on success), so on 2026-10-09 the other sessions survived. Recorded, not asserted: the client
        // must never replay either way.
        let replay = VelroStaffClient(environment: environment, persist: { _ in })
        await replay.restore(VelroStoredSession(environment: environment, userID: session.userID, roles: session.roles, refreshToken: before, deviceID: "replay"))
        await #expect(throws: VelroError.sessionEnded(code: "REFRESH_TOKEN_REVOKED")) { _ = try await replay.dashboard() }
        let victim = VelroStaffClient(environment: environment, persist: { _ in })
        await victim.restore(current)
        let survived = (try? await victim.validAccessToken(forceRefresh: true)) != nil
        print("EMULATOR velro: after a replayed refresh token, the user's other session \(survived ? "SURVIVED (revocation rolled back with the 401)" : "was revoked")")

        // Error paths.
        let wrong = VelroStaffClient(environment: environment, persist: { _ in })
        _ = try await wrong.requestCode(phone: staffPhone)
        await #expect(throws: VelroError.otpInvalid) { _ = try await wrong.verify(phone: staffPhone, code: "00000", deviceID: "x") }
        let driver = VelroStaffClient(environment: environment, persist: { _ in })
        // A driver's number gets no code with audience "staff"; the app-audience code proves verify refuses non-staff.
        let quiet = try await driver.requestCode(phone: "+93700000031")
        #expect(quiet.debugCode == nil, "VELRO sends nothing to a non-staff number on the staff door")
        let unknown = VelroStaffClient(environment: environment, persist: { _ in })
        await #expect(throws: VelroError.notSignedIn) { _ = try await unknown.dashboard() }
    }
}
