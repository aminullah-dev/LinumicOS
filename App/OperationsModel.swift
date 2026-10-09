import Foundation
import LinumicCore
import Observation

/// Operations (عملیات): Talar, SafeBeauty and VELRO admin overviews, read-only (plus Talar's audited hall
/// approve/reject). One signed-in session per product; only its refresh token (or, for VELRO, the rotating refresh
/// token) is kept, in this device's Keychain. Nothing read is cached on disk except the queue counts.
@MainActor
@Observable
final class OperationsModel {
    let talar: TalarModel
    let safeBeauty: SafeBeautyModel
    let velro: VelroModel

    static let notifyKey = "LCCNotifyOperationsQueues"
    /// The queues are read on launch and then every 30 minutes (the app's refresh loop), never faster:
    /// VELRO's dashboard runs many COUNT queries and SafeBeauty's counts are billed per query.
    static let autoRefreshInterval: TimeInterval = 30 * 60

    init(inventory: InventoryModel) {
        let counts = OperationsCountStore()
        talar = TalarModel(secrets: inventory.secrets, counts: counts)
        safeBeauty = SafeBeautyModel(secrets: inventory.secrets, counts: counts)
        velro = VelroModel(secrets: inventory.secrets, counts: counts)
    }

    func load() async {
        await talar.load()
        await safeBeauty.load()
        await velro.load()
    }

    func autoRefreshIfDue() async {
        await talar.autoRefreshIfDue()
        await safeBeauty.autoRefreshIfDue()
        await velro.autoRefreshIfDue()
    }

    /// The dashboard card's lines: every dashboard queue with its latest count, or nil when its product isn't read.
    var waiting: [(queue: OperationsQueue, count: OperationsCount?)] {
        let all = talar.counts + safeBeauty.counts + velro.counts
        return OperationsQueue.dashboard.map { q in (q, all.first { $0.queue == q }) }
    }

    func isSignedIn(_ product: OperationsProduct) -> Bool {
        switch product {
        case .talar: talar.isSignedIn
        case .safeBeauty: safeBeauty.isSignedIn
        case .velro: velro.isSignedIn
        }
    }

    /// Debug builds also offer the local emulators / backend.
    static var includeLocal: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Records fresh counts and posts a notification for every queue that just went from 0 to more than 0
/// (production only: demo and local queues aren't anyone's work).
@MainActor
private func track(_ counts: [OperationsCount], in store: OperationsCountStore) async {
    let changed = store.record(counts).filter(\.isProduction)
    await OperationsNotifier.post(changed)
}

private func decodeSession<T: Decodable>(_ type: T.Type, _ key: SecretKey, _ secrets: SecretStore) -> T? {
    guard let text = try? secrets.read(key), let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

private func store<T: Encodable>(_ value: T, _ key: SecretKey, _ secrets: SecretStore) throws {
    try secrets.write(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), for: key)
}

// MARK: - Talar

@MainActor
@Observable
final class TalarModel {
    private(set) var session: TalarStoredSession?
    private(set) var dashboard: TalarDashboard?
    private(set) var halls: [TalarHall] = []
    private(set) var reviews: [TalarReview] = []
    private(set) var organizations: [TalarOrganization] = []
    private(set) var payouts: [TalarOrgPayouts] = []
    private(set) var payoutSummary: TalarPayoutSummary?
    /// Set when the settlement overview (secondary) couldn't be read.
    private(set) var payoutError: String?
    private(set) var actions: [OperationsActionRecord] = []
    private(set) var lastRead: Date?
    private(set) var isRefreshing = false
    private(set) var loadError: String?

    private let secrets: SecretStore
    private let countStore: OperationsCountStore
    private let log: OperationsActionLog?
    private var client: TalarAdminClient?

    static var offeredEnvironments: [TalarEnvironment] { TalarEnvironment.offered(includeEmulator: OperationsModel.includeLocal) }

    init(secrets: SecretStore, counts: OperationsCountStore) {
        self.secrets = secrets
        countStore = counts
        log = (try? OperationsActionLog.defaultFileURL()).map(OperationsActionLog.init(fileURL:))
        if let s = decodeSession(TalarStoredSession.self, .talarAdminSession, secrets), Self.offeredEnvironments.contains(s.environment) { session = s }
    }

    var isSignedIn: Bool { session != nil }
    var environment: TalarEnvironment? { session?.environment }

    var counts: [OperationsCount] {
        guard let env = environment, let at = lastRead, let d = dashboard else { return [] }
        return [OperationsCount(queue: .talarHalls, count: max(d.hallsAwaitingReview, halls.count), environment: env.rawValue, readAt: at),
                OperationsCount(queue: .talarReviews, count: reviews.count, environment: env.rawValue, readAt: at)]
    }

    func organizationName(_ id: String?) -> String? { organizations.first { $0.id == id }?.name }
    func hall(_ id: String) -> TalarHall? { halls.first { $0.id == id } }

    func load() async {
        if let log { actions = ((try? await log.load()) ?? []).filter { $0.product == .talar } }
        if let session, client == nil {
            let c = TalarAdminClient(environment: session.environment)
            await c.restore(refreshToken: session.refreshToken)
            client = c
            await refresh()
        }
    }

    func signIn(environment: TalarEnvironment, email: String, password: String) async throws {
        let c = TalarAdminClient(environment: environment)
        let s = try await c.signIn(email: email, password: password)
        do { _ = try await c.dashboard() } catch {
            await c.signOut()
            throw error
        }
        try store(s, .talarAdminSession, secrets)
        client = c
        session = s
        clear()
        countStore.forget(.talar)
        await refresh()
    }

    func signOut() {
        let c = client
        Task { await c?.signOut() }
        client = nil
        session = nil
        try? secrets.delete(.talarAdminSession)
        countStore.forget(.talar)
        clear()
        loadError = nil
    }

    private func clear() {
        dashboard = nil
        halls = []
        reviews = []
        organizations = []
        payouts = []
        payoutSummary = nil
        payoutError = nil
        lastRead = nil
    }

    private func persistRotatedToken() async {
        guard let client, var s = session, let current = await client.currentRefreshToken, current != s.refreshToken else { return }
        s.refreshToken = current
        session = s
        try? store(s, .talarAdminSession, secrets)
    }

    private func handle(_ error: Error) -> String {
        if let e = error as? TalarError, e.needsSignIn { signOut() }
        return error.localizedDescription
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            dashboard = try await client.dashboard()
            halls = try await client.pendingHalls()
            reviews = try await client.pendingReviews()
            lastRead = .now
            loadError = nil
        } catch {
            clear()
            loadError = handle(error)
            return
        }
        // Settlements are secondary: a failure there doesn't hide the queues.
        do {
            organizations = try await client.organizations()
            let overview = try await client.payoutOverview()
            payouts = overview.rows
            payoutSummary = TalarPayoutSummary(overview.rows, truncated: overview.truncated)
            payoutError = nil
        } catch {
            payouts = []
            payoutSummary = nil
            payoutError = error.localizedDescription
        }
        await persistRotatedToken()
        await track(counts, in: countStore)
    }

    func autoRefreshIfDue() async {
        guard isSignedIn, !isRefreshing else { return }
        if let lastRead, Date.now.timeIntervalSince(lastRead) < OperationsModel.autoRefreshInterval - 60 { return }
        await refresh()
    }

    /// Approve or reject one hall: sent once (never retried), then the queue is read again to check it left.
    /// Recorded in the local action log whatever happens. Talar writes its own audit entry.
    func review(_ hall: TalarHall, write: TalarHallReviewWrite) async throws -> OperationsActionRecord {
        guard let client, let session else { throw TalarError.notSignedIn }
        let name = hall.name.best()
        let action = "hall.review_\(write.decision.rawValue)"
        do {
            try await client.reviewHall(hall.id, write)
        } catch {
            let r = OperationsActionRecord(at: .now, product: .talar, environment: session.environment.rawValue, actor: session.email, action: action,
                                           targetID: hall.id, targetName: name, detail: write.reason, outcome: .failed, message: error.localizedDescription)
            await append(r)
            throw OperationsModelError.message(handle(error))
        }
        var outcome = OperationsActionRecord.Outcome.unverified
        var message: String?
        do {
            let fresh = try await client.pendingHalls()
            outcome = fresh.contains { $0.id == hall.id } ? .unverified : .verified
            if outcome == .unverified { message = String(localized: "Talar accepted it, but the hall is still in the queue.") }
        } catch { message = error.localizedDescription }
        let r = OperationsActionRecord(at: .now, product: .talar, environment: session.environment.rawValue, actor: session.email, action: action,
                                       targetID: hall.id, targetName: name, detail: write.reason, outcome: outcome, message: message)
        await append(r)
        await refresh()
        return r
    }

    private func append(_ r: OperationsActionRecord) async {
        actions.insert(r, at: 0)
        try? await log?.append(r)
    }
}

// MARK: - SafeBeauty

@MainActor
@Observable
final class SafeBeautyModel {
    private(set) var session: SafeBeautyStoredSession?
    private(set) var snapshot: SafeBeautySnapshot?
    private(set) var isRefreshing = false
    private(set) var loadError: String?

    private let secrets: SecretStore
    private let countStore: OperationsCountStore
    private var client: SafeBeautyAdminClient?

    static var offeredEnvironments: [SafeBeautyEnvironment] { SafeBeautyEnvironment.offered(includeEmulator: OperationsModel.includeLocal) }

    init(secrets: SecretStore, counts: OperationsCountStore) {
        self.secrets = secrets
        countStore = counts
        if let s = decodeSession(SafeBeautyStoredSession.self, .safeBeautyAdminSession, secrets), Self.offeredEnvironments.contains(s.environment) { session = s }
    }

    var isSignedIn: Bool { session != nil }
    var environment: SafeBeautyEnvironment? { session?.environment }
    var lastRead: Date? { snapshot?.readAt }

    var counts: [OperationsCount] {
        guard let env = environment, let s = snapshot else { return [] }
        return [OperationsCount(queue: .safeBeautyKYC, count: s.kycPendingCount, environment: env.rawValue, readAt: s.readAt),
                OperationsCount(queue: .safeBeautyApprovals, count: s.approvalPendingCount, environment: env.rawValue, readAt: s.readAt)]
    }

    func load() async {
        if let session, client == nil {
            let c = SafeBeautyAdminClient(environment: session.environment)
            await c.restore(refreshToken: session.refreshToken)
            client = c
            await refresh()
        }
    }

    /// The phone number and password are used for this call only; neither is kept.
    func signIn(environment: SafeBeautyEnvironment, phone: String, password: String) async throws {
        let c = SafeBeautyAdminClient(environment: environment)
        let s = try await c.signIn(phone: phone, password: password)
        try store(s, .safeBeautyAdminSession, secrets)
        client = c
        session = s
        snapshot = nil
        countStore.forget(.safeBeauty)
        await refresh()
    }

    func signOut() {
        let c = client
        Task { await c?.signOut() }
        client = nil
        session = nil
        snapshot = nil
        loadError = nil
        try? secrets.delete(.safeBeautyAdminSession)
        countStore.forget(.safeBeauty)
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await client.snapshot()
            loadError = nil
            if var s = session, let current = await client.currentRefreshToken, current != s.refreshToken {
                s.refreshToken = current
                session = s
                try? store(s, .safeBeautyAdminSession, secrets)
            }
            await track(counts, in: countStore)
        } catch {
            snapshot = nil
            if let e = error as? SafeBeautyError, e.needsSignIn { signOut() }
            loadError = error.localizedDescription
        }
    }

    func autoRefreshIfDue() async {
        guard isSignedIn, !isRefreshing else { return }
        if let lastRead, Date.now.timeIntervalSince(lastRead) < OperationsModel.autoRefreshInterval - 60 { return }
        await refresh()
    }
}

// MARK: - VELRO

@MainActor
@Observable
final class VelroModel {
    private(set) var session: VelroStoredSession?
    private(set) var dashboard: VelroDashboard?
    private(set) var drivers: VelroPage<VelroDriver>?
    private(set) var activeTrips: VelroPage<VelroTrip>?
    private(set) var upcomingTrips: VelroPage<VelroTrip>?
    private(set) var stations: VelroPage<VelroStation>?
    private(set) var routes: VelroPage<VelroRoute>?
    private(set) var commission: VelroCommission?
    private(set) var commissionError: String?
    private(set) var lastRead: Date?
    private(set) var isRefreshing = false
    private(set) var loadError: String?

    private let secrets: SecretStore
    private let countStore: OperationsCountStore
    private var client: VelroStaffClient?

    static var offeredEnvironments: [VelroEnvironment] { VelroEnvironment.offered(includeLocal: OperationsModel.includeLocal) }

    /// A per-install id VELRO keeps beside the refresh token ("sign out of all devices" tells devices apart).
    static var deviceID: String {
        let key = "LCCVelroDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "linumic-os-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    init(secrets: SecretStore, counts: OperationsCountStore) {
        self.secrets = secrets
        countStore = counts
        if let s = decodeSession(VelroStoredSession.self, .velroStaffSession, secrets), Self.offeredEnvironments.contains(s.environment) { session = s }
    }

    var isSignedIn: Bool { session != nil }
    var environment: VelroEnvironment? { session?.environment }

    var counts: [OperationsCount] {
        guard let env = environment, let at = lastRead, let d = dashboard else { return [] }
        return [OperationsCount(queue: .velroDrivers, count: d.attention.pendingDrivers, environment: env.rawValue, readAt: at)]
    }

    /// Writes (or removes) the Keychain copy. Called by the client inside its refresh, before the new token is used.
    private func makeClient(_ environment: VelroEnvironment) -> VelroStaffClient {
        let secrets = self.secrets
        return VelroStaffClient(environment: environment, persist: { s in
            if let s {
                try? secrets.write(String(decoding: (try? JSONEncoder().encode(s)) ?? Data(), as: UTF8.self), for: .velroStaffSession)
            } else {
                try? secrets.delete(.velroStaffSession)
            }
        })
    }

    func load() async {
        if let session, client == nil {
            let c = makeClient(session.environment)
            await c.restore(session)
            client = c
            await refresh()
        }
    }

    /// Step 1: VELRO sends a code (only to a number that holds a staff role). The phone number is not kept.
    func requestCode(environment: VelroEnvironment, phone: String) async throws -> VelroOtpSent {
        let c = pendingClient(environment)
        return try await c.requestCode(phone: phone, locale: Self.locale)
    }

    /// Step 2: the code becomes a session; the client stores the refresh token in the Keychain.
    func verify(environment: VelroEnvironment, phone: String, code: String) async throws {
        let c = pendingClient(environment)
        let s = try await c.verify(phone: phone, code: code, deviceID: Self.deviceID, locale: Self.locale)
        signInClient = nil
        client = c
        session = s
        clear()
        countStore.forget(.velro)
        await refresh()
    }

    private var signInClient: VelroStaffClient?
    private func pendingClient(_ environment: VelroEnvironment) -> VelroStaffClient {
        if let c = signInClient, c.environment == environment { return c }
        let c = makeClient(environment)
        signInClient = c
        return c
    }

    static var locale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fa") == true ? "fa-AF" : "en"
    }

    func signOut() {
        let c = client
        Task { await c?.signOut() }
        client = nil
        session = nil
        try? secrets.delete(.velroStaffSession)
        countStore.forget(.velro)
        clear()
        loadError = nil
    }

    private func clear() {
        dashboard = nil
        drivers = nil
        activeTrips = nil
        upcomingTrips = nil
        stations = nil
        routes = nil
        commission = nil
        commissionError = nil
        lastRead = nil
    }

    private func syncSession() async {
        guard let client else { return }
        if let current = await client.current { session = current } else { signOut() }
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            dashboard = try await client.dashboard()
            drivers = try await client.pendingDrivers()
            activeTrips = try await client.activeTrips()
            upcomingTrips = try await client.upcomingTrips(hours: 24)
            stations = try await client.stations()
            routes = try await client.routes()
            lastRead = .now
            loadError = nil
        } catch {
            clear()
            loadError = error.localizedDescription
            if let e = error as? VelroError, e.needsSignIn { signOut(); loadError = e.localizedDescription }
            else { await syncSession() }
            return
        }
        if session?.canReadSettings == true {
            do { commission = try await client.commission(); commissionError = nil } catch { commission = nil; commissionError = error.localizedDescription }
        } else {
            commission = nil
            commissionError = VelroError.permissionDenied.localizedDescription
        }
        await syncSession()
        await track(counts, in: countStore)
    }

    func autoRefreshIfDue() async {
        guard isSignedIn, !isRefreshing else { return }
        if let lastRead, Date.now.timeIntervalSince(lastRead) < OperationsModel.autoRefreshInterval - 60 { return }
        await refresh()
    }

    func documents(driverID: String) async throws -> VelroDocumentChecklist {
        guard let client else { throw VelroError.notSignedIn }
        do {
            let d = try await client.documents(driverID: driverID)
            await syncSession()
            return d
        } catch {
            if let e = error as? VelroError, e.needsSignIn { signOut() }
            throw error
        }
    }
}

enum OperationsModelError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): m }
    }
}
