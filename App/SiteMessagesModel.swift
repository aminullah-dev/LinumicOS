import Foundation
import LinumicCore
import Observation
import UserNotifications

/// Website messages (پیام‌های سایت): the linumic.com contact-form entries, read through SureForms' read-only abilities
/// with a WordPress application password from this device's Keychain (`wordpress.linumic.apppassword`).
/// The messages themselves stay in memory; only the ids the owner has seen or been notified about, and the time of the
/// last reading, are kept on disk (`site-messages.json`). Nothing is written to WordPress.
@MainActor
@Observable
final class SiteMessagesModel {
    static let notifyKey = "LCCNotifySiteMessages"

    private(set) var reading: SiteMessagesReading?
    private(set) var state: SiteMessagesState
    private(set) var isConfigured = false
    /// The WordPress username (not secret), for Settings.
    private(set) var username: String?
    private(set) var loadError: String?
    private(set) var isRefreshing = false

    private let secrets: SecretStore
    private let store: SiteMessagesStateStore?

    init(secrets: SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        store = (try? SiteMessagesStateStore.defaultFileURL()).map(SiteMessagesStateStore.init(fileURL:))
        state = store?.load() ?? SiteMessagesState()
        let credential = Self.readCredential(secrets)
        isConfigured = credential?.isComplete == true
        username = credential?.username
    }

    static var isNotificationOn: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }

    private static func readCredential(_ secrets: SecretStore) -> WordPressAppPassword? {
        ((try? secrets.read(.wordPressLinumic)) ?? nil).flatMap(WordPressAppPassword.decode)
    }

    // MARK: Derived

    /// Messages not marked seen, newest first (empty until the first reading).
    var new: [SiteMessage] { reading.map { SiteMessagesRules.new($0.messages, seen: state.seenIDs) } ?? [] }

    /// For the dashboard: the current count, or the count of the last reading before this launch, or nil (never read).
    var newCount: Int? { reading == nil ? (isConfigured ? state.lastNewCount : nil) : new.count }

    func isSeen(_ m: SiteMessage) -> Bool { state.seenIDs.contains(m.id) }

    var briefInput: BriefSiteMessagesInput {
        BriefSiteMessagesInput(isConfigured: isConfigured, reading: reading, seenIDs: state.seenIDs, loadError: loadError)
    }

    // MARK: Credential (Settings)

    func saveCredential(username: String, password: String) throws {
        let credential = WordPressAppPassword(username: username, password: password)
        guard credential.isComplete else { throw SiteMessagesError.notConfigured }
        try secrets.write(try credential.encoded(), for: .wordPressLinumic)
        isConfigured = true
        self.username = credential.username
        loadError = nil
    }

    func removeCredential() throws {
        try secrets.delete(.wordPressLinumic)
        isConfigured = false
        username = nil
        reading = nil
        loadError = nil
    }

    // MARK: Reading

    /// Reads the newest entries (two GETs). Called at launch, every 30 minutes with the other refreshes, and by Refresh.
    func refresh() async {
        guard !isRefreshing else { return }
        guard let credential = Self.readCredential(secrets), credential.isComplete else {
            isConfigured = false
            return
        }
        isConfigured = true
        isRefreshing = true
        defer { isRefreshing = false }
        let client = SiteMessagesClient(credential: credential, transport: URLSessionTransport(session: SiteMessagesSession.shared))
        do {
            let r = try await client.fetchRecent()
            reading = r
            loadError = nil
            let toNotify = state.record(r)
            save()
            await SiteMessagesNotifier.post(toNotify)
        } catch {
            // The last good reading stays, with the error beside it; it is never shown as fresh.
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Seen (this device only; WordPress's own read/unread is not touched)

    func markSeen(_ m: SiteMessage) {
        state.markSeen([m.id])
        save()
    }

    func markUnseen(_ m: SiteMessage) {
        state.markUnseen(m.id)
        save()
    }

    func markAllSeen() {
        state.markSeen((reading?.messages ?? []).map(\.id))
        state.lastNewCount = 0
        save()
    }

    private func save() { try? store?.save(state) }
}

/// Ephemeral session: no cookies, cache or credential storage, and redirects refused so the Authorization header is
/// never carried to another address.
enum SiteMessagesSession {
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static let shared: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.httpAdditionalHeaders = ["User-Agent": "LinumicOS-SiteMessages/1"]
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()
}

/// A local notification for messages that are new and not notified before (Settings → Integrations → Website
/// messages). Names and a short excerpt only, never the address.
@MainActor
enum SiteMessagesNotifier {
    static func post(_ new: [SiteMessage]) async {
        guard SiteMessagesModel.isNotificationOn, let text = SiteMessagesNotificationText.content(new) else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        let id = "site-messages-\(new.map(\.id).max() ?? 0)"
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
