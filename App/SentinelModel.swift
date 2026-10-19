import Foundation
import LinumicCore
import Observation
import UserNotifications

/// Server watch (Sentinel): reads what the checks on Supabase saw (docs/sentinel.md). Those checks run every
/// 10 minutes on the server, so outages and expiring licences are caught while this device is off; the app reads
/// them when it runs, and on iPhone in background refresh too, and posts a notification for each new event.
@MainActor
@Observable
final class SentinelModel {
    static let notifyKey = "LCCNotifySentinel"
    private static let seenKey = "LCCSentinelSeenEvents"

    private(set) var overview: SentinelOverview?
    private(set) var events: [SentinelEvent] = []
    private(set) var lastRead: Date?
    private(set) var loadError: String?
    /// The RPCs answered 404: the migrations and function aren't deployed yet.
    private(set) var isDeployed = true
    private(set) var isRefreshing = false
    private(set) var isRequestingRound = false

    private let inventory: InventoryModel
    /// Event ids already notified on this device; nil until the first read, which only records (no flood of old events).
    private var seen: Set<Int>?

    init(inventory: InventoryModel) {
        self.inventory = inventory
        if let ids = UserDefaults.standard.array(forKey: Self.seenKey) as? [Int] { seen = Set(ids) }
    }

    var summary: SentinelSummary? { overview.map { SentinelSummary.make($0, now: .now) } }
    var unacknowledged: [SentinelEvent] { events.filter { !$0.isAcknowledged } }

    private var client: SentinelClient? { inventory.sentinelClient() }

    var isConnected: Bool { client != nil }

    enum Outcome { case read, notConnected, notDeployed, failed(String) }

    @discardableResult
    func refresh() async -> Outcome {
        guard let client else { return .notConnected }
        guard !isRefreshing else { return .read }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let o = client.overview(hours: 24)
            async let e = client.events(limit: 50, includeAcknowledged: true)
            let (overview, events) = try await (o, e)
            self.overview = overview
            self.events = events
            lastRead = .now
            loadError = nil
            isDeployed = true
            await notifyNew(events)
            return .read
        } catch SupabaseError.server(let status, _) where status == 404 {
            isDeployed = false
            loadError = nil
            return .notDeployed
        } catch {
            loadError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    func acknowledge(_ event: SentinelEvent) async {
        guard let client else { return }
        do {
            try await client.acknowledge(eventID: event.id)
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Asks the server for a round now (at most one every 2 minutes), then reads again once it had time to run.
    func requestRound() async -> Bool {
        guard let client, !isRequestingRound else { return false }
        isRequestingRound = true
        defer { isRequestingRound = false }
        do {
            let accepted = try await client.requestRound()
            if accepted {
                try? await Task.sleep(for: .seconds(20))
                await refresh()
            }
            return accepted
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    // MARK: Notifications

    private func notifyNew(_ events: [SentinelEvent]) async {
        let ids = Set(events.map(\.id))
        let previous = seen
        seen = (previous ?? []).union(ids)
        // Only ids the server still returns can come back, so that is all that needs keeping.
        UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.seenKey)
        guard let previous else { return }   // first read: record only, no flood of old events
        let fresh = events.filter { !previous.contains($0.id) && !$0.isAcknowledged }
        guard !fresh.isEmpty, UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for event in fresh.prefix(5) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Server watch")
            content.body = Self.line(for: event)
            if event.severity >= .warning { content.sound = .default }
            NotificationGate.apply(content)
            try? await center.add(UNNotificationRequest(identifier: "sentinel.\(event.id)", content: content, trigger: nil))
        }
    }

    /// The event in the app's language, built from its kind and facts (the server's English title is a fallback).
    static func line(for event: SentinelEvent) -> String {
        let name = MonitorCatalog.targets.first { $0.id == event.subject }.map { "\($0.product.title) \(L($0.name))" } ?? event.subject
        switch event.kind {
        case .targetDown:
            return String(localized: "\(name) is down")
        case .targetRecovered:
            return String(localized: "\(name) is back up")
        case .licenceExpiring:
            let who = event.detail?.customer ?? event.subject
            return String(localized: "Licence for \(who) expires in \(event.detail?.daysLeft ?? 0) days")
        case .licenceExpired:
            return String(localized: "Licence for \(event.detail?.customer ?? event.subject) has expired")
        }
    }
}
