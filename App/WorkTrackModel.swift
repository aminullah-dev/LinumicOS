import Foundation
import LinumicCore
import Observation

/// WorkTrack customers and renewals, through the WorkTrack vendor API (`/v1/vendor`). The owner signs in with
/// his vendor account; only the refresh token is kept (Keychain, this device). Everything shown carries the
/// environment and the time it was read. Nothing is cached on disk except the local action log.
@MainActor
@Observable
final class WorkTrackModel {
    private(set) var session: WorkTrackStoredSession?
    private(set) var companies: [WTCompany] = []
    private(set) var lastRead: Date?
    /// Money's reading of the same refresh (revenue, CRM accounts, CRM invoices), each part with its own time or
    /// failure. In memory only.
    private(set) var moneyRead: WorkTrackMoneyRead?
    private(set) var plans: [String: WTPlanDef] = [:]
    private(set) var audit: [WTAuditEntry] = []
    private(set) var actions: [WorkTrackActionRecord] = []
    private(set) var isRefreshing = false
    /// A load error. The previous data, if any, is cleared rather than shown as current.
    private(set) var loadError: String?
    var errorMessage: String?

    static let notifyKey = "LCCNotifyWorkTrackExpiry"

    /// Debug builds also offer the local Firebase emulator.
    static var offeredEnvironments: [WorkTrackEnvironment] {
        #if DEBUG
        WorkTrackEnvironment.offered(includeEmulator: true)
        #else
        WorkTrackEnvironment.offered(includeEmulator: false)
        #endif
    }

    private let secrets: SecretStore
    private let log: WorkTrackActionLog?
    private var client: WorkTrackVendorClient?
    /// A Sales read the owner asked for (one account's contacts, the shape check) while it runs. A refresh waits for it,
    /// and it is refused while a refresh runs: one request at a time, so the client's token refresh is never raced.
    private var salesRead: Task<Void, Never>?
    /// Sales copies drafts and numbers through this one guard, which lives as long as the model: a guard made by a sheet
    /// would be gone when the sheet closes, and the clipboard would never be cleared.
    private let clipboard = ClipboardGuard(pasteboard: SystemPasteboard())

    /// How long a copied Sales draft or phone number stays on the clipboard.
    static let salesClipboardSeconds: TimeInterval = 120

    init(inventory: InventoryModel) {
        secrets = inventory.secrets
        log = (try? WorkTrackActionLog.defaultFileURL()).map(WorkTrackActionLog.init(fileURL:))
        if let text = try? secrets.read(.workTrackVendorSession), let data = text.data(using: .utf8),
           let stored = try? JSONDecoder().decode(WorkTrackStoredSession.self, from: data),
           Self.offeredEnvironments.contains(stored.environment) {
            session = stored
        }
    }

    var isSignedIn: Bool { session != nil }
    var environment: WorkTrackEnvironment? { session?.environment }
    var summary: WTCustomersSummary { WTCustomersSummary(companies: companies) }
    var revenue: WTRevenue? { moneyRead?.revenue.value }
    /// The money parts that failed in the last refresh (the automation run note); nil when all were read.
    var moneyError: String? { moneyRead?.failure }

    func company(_ id: String) -> WTCompany? { companies.first { $0.companyId == id } }
    func plan(_ plan: WTPlan) -> WTPlanDef? { plans[plan.rawValue] }

    // MARK: Session

    /// Reads the action log and, with a stored session, resumes it from the refresh token and reads the list.
    func load() async {
        if let log { actions = (try? await log.load()) ?? [] }
        if let session, client == nil {
            let c = WorkTrackVendorClient(environment: session.environment)
            await c.restore(refreshToken: session.refreshToken)
            client = c
            await refresh()
        }
    }

    /// Signs in, confirms the account is a vendor (`GET /vendor/me`), and only then keeps the refresh token.
    func signIn(environment: WorkTrackEnvironment, email: String, password: String) async throws {
        let c = WorkTrackVendorClient(environment: environment)
        let s = try await c.signIn(email: email, password: password)
        do { _ = try await c.me() } catch {
            await c.signOut()
            throw error
        }
        try store(s)
        client = c
        session = s
        clearData()
        await refresh()
    }

    func signOut() {
        Task { await client?.signOut() }
        client = nil
        session = nil
        try? secrets.delete(.workTrackVendorSession)
        clearData()
        loadError = nil
        Task { await WorkTrackNotifier.reschedule(for: [], environment: nil) }
    }

    private func store(_ s: WorkTrackStoredSession) throws {
        try secrets.write(String(decoding: try JSONEncoder().encode(s), as: UTF8.self), for: .workTrackVendorSession)
    }

    /// Firebase may hand back a new refresh token; keep the Keychain copy current.
    private func persistRotatedToken() async {
        guard let client, var s = session, let current = await client.currentRefreshToken, current != s.refreshToken else { return }
        s.refreshToken = current
        session = s
        try? store(s)
    }

    private func clearData() {
        companies = []
        lastRead = nil
        moneyRead = nil
        plans = [:]
        audit = []
    }

    /// A session the server no longer accepts is removed, so the app doesn't keep presenting it as signed in.
    private func handle(_ error: Error) -> String {
        if let e = error as? WorkTrackError, e.needsSignIn {
            signOut()
        }
        return error.localizedDescription
    }

    // MARK: Reads

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await salesRead?.value
        do {
            let list = try await client.companies()
            companies = list
            lastRead = .now
            loadError = nil
            // The rest is secondary: a failure there doesn't hide the company list. Money is read right after the
            // list, so its invoices are filtered with the TEST and DUPLICATE marks of this same reading.
            let money = await WorkTrackMoneyReader.read(client)
            moneyRead = money
            plans = (try? await client.plans()) ?? plans
            audit = (try? await client.audit()) ?? audit
            await persistRotatedToken()
            if money.needsSignIn {
                // The same rule as a failed list: a session the server no longer accepts is removed.
                let message = money.failure
                signOut()
                loadError = message
                return
            }
            await WorkTrackNotifier.reschedule(for: list, environment: session?.environment)
        } catch {
            clearData()
            loadError = handle(error)
        }
    }

    // MARK: Sales (read-only, on demand)

    /// Whether a Sales read the owner asked for is running.
    var isSalesReading: Bool { salesRead != nil }

    struct SalesContacts {
        let rows: [WTCrmContactRef]
        /// Contacts WorkTrack sent that could not be read.
        let skipped: Int
        let readAt: Date
    }

    /// One account's contacts (`GET /vendor/crm/contacts?accountId=`). Nothing is kept here: the view holds them while it
    /// is open.
    func contacts(forAccount id: String) async throws -> SalesContacts {
        try await salesCall { client in
            let list = try await client.crmContacts(accountId: id)
            return SalesContacts(rows: list.rows, skipped: list.skipped, readAt: .now)
        }
    }

    /// The owner's one check of the CRM answer: one `GET /vendor/crm/accounts`, kept as names, types and counts only.
    func checkCRMShape() async throws -> WTShapeReport {
        try await salesCall { try await $0.crmAccountsShape() }
    }

    /// Copies a draft or a number concealed (macOS) or local only (iOS), and clears it after two minutes if it is still
    /// there. Nothing is sent.
    func copyConcealed(_ text: String) {
        clipboard.copy(text, clearAfter: Self.salesClipboardSeconds)
    }

    private func salesCall<T: Sendable>(_ read: @escaping @Sendable (WorkTrackVendorClient) async throws -> T) async throws -> T {
        guard let client else { throw WorkTrackError.notSignedIn }
        guard !isRefreshing, salesRead == nil else { throw WorkTrackModelError.busy }
        let call = Task { try await read(client) }
        salesRead = Task { _ = await call.result }
        defer { salesRead = nil }
        do {
            let value = try await call.value
            await persistRotatedToken()
            return value
        } catch {
            throw WorkTrackModelError.message(handle(error))
        }
    }

    struct CompanyRecord {
        let detail: WTCompanyDetail
        let orders: [WTOrder]
        let readAt: Date
    }

    func record(_ companyID: String) async throws -> CompanyRecord {
        guard let client else { throw WorkTrackError.notSignedIn }
        do {
            let detail = try await client.detail(companyID)
            let orders = try await client.orders(companyID)
            if let i = companies.firstIndex(where: { $0.companyId == companyID }) { companies[i] = detail.company }
            await persistRotatedToken()
            return CompanyRecord(detail: detail, orders: orders, readAt: .now)
        } catch {
            throw WorkTrackModelError.message(handle(error))
        }
    }

    /// The company as WorkTrack has it right now (`GET /vendor/companies/:id`), for building a renewal.
    func fetchCurrent(_ companyID: String) async throws -> WTCompany {
        guard let client else { throw WorkTrackError.notSignedIn }
        do {
            let c = try await client.company(companyID)
            if let i = companies.firstIndex(where: { $0.companyId == companyID }) { companies[i] = c }
            if plans.isEmpty { plans = (try? await client.plans()) ?? [:] }
            return c
        } catch {
            throw WorkTrackModelError.message(handle(error))
        }
    }

    // MARK: Renewal

    struct RenewalResult {
        let stored: WTLicense
        /// What a fresh read returned after the write.
        let refetched: WTLicense?
        let mismatches: [WTFieldChange]
        let readAt: Date
    }

    /// Re-reads the licence and refuses if it changed since the sheet was built, sends the PUT once, re-reads,
    /// compares, and records the action in the local log whatever the outcome.
    func renew(company: WTCompany, basedOn: WTLicense, write: WTLicenseWrite) async throws -> RenewalResult {
        guard let client, let session else { throw WorkTrackError.notSignedIn }
        let fresh: WTCompany
        do { fresh = try await client.company(company.companyId) } catch { throw WorkTrackModelError.message(handle(error)) }
        guard fresh.license == basedOn else {
            if let i = companies.firstIndex(where: { $0.companyId == company.companyId }) { companies[i] = fresh }
            throw WorkTrackModelError.changedSinceOpened
        }

        let stored: WTLicense
        do {
            stored = try await client.putLicense(companyID: company.companyId, write)
        } catch {
            let message = error.localizedDescription
            await append(WorkTrackActionRecord(at: .now, environment: session.environment, actorEmail: session.email, companyID: company.companyId,
                                               companyName: company.name, before: basedOn, sent: write.expectedLicense, stored: nil,
                                               outcome: .failed, message: message))
            throw WorkTrackModelError.message(handle(error))
        }

        var refetched: WTLicense?
        var note: String?
        do { refetched = try await client.detail(company.companyId).company.license } catch { note = error.localizedDescription }
        let mismatches = WorkTrackRenewal.mismatches(expected: write.expectedLicense, stored: refetched ?? stored)
        let verified = refetched != nil && mismatches.isEmpty
        await append(WorkTrackActionRecord(at: .now, environment: session.environment, actorEmail: session.email, companyID: company.companyId,
                                           companyName: company.name, before: basedOn, sent: write.expectedLicense, stored: refetched ?? stored,
                                           outcome: verified ? .verified : .unverified,
                                           message: note ?? (mismatches.isEmpty ? nil : mismatches.map { "\($0.field): \($0.before) → \($0.after)" }.joined(separator: "; "))))
        await persistRotatedToken()
        await refresh()
        return RenewalResult(stored: stored, refetched: refetched, mismatches: mismatches, readAt: .now)
    }

    private func append(_ record: WorkTrackActionRecord) async {
        actions.insert(record, at: 0)
        guard let log else { return }
        do { try await log.append(record) } catch {
            errorMessage = String(localized: "Could not save the WorkTrack action log: \(error.localizedDescription)")
        }
    }
}

enum WorkTrackModelError: LocalizedError {
    case changedSinceOpened
    /// A WorkTrack refresh or another read is running.
    case busy
    case message(String)

    var errorDescription: String? {
        switch self {
        case .changedSinceOpened:
            String(localized: "The licence changed in WorkTrack after this sheet was opened (someone else, or a payment). Nothing was sent. Close the sheet and start the renewal again from the current licence.")
        case .busy:
            String(localized: "WorkTrack is being read right now. Try again in a moment.")
        case .message(let m): m
        }
    }
}
