import Foundation
import LinumicCore
import Observation
import UserNotifications

/// Daily Brief (گزارش روز): collects what the other models already hold into a `BriefInput` and lets LinumicCore
/// build the brief. It reads nothing from the network. It keeps one small snapshot per day on this device
/// (`brief-snapshots.json`) for "what changed since yesterday", and schedules the optional morning notification.
@MainActor
@Observable
final class BriefModel {
    static let notifyKey = "LCCBriefNotify"
    static let hourKey = "LCCBriefHour"
    static let minuteKey = "LCCBriefMinute"
    private static let notificationID = "daily-brief"

    private(set) var history: BriefSnapshotHistory
    /// When the morning notification is next due, as scheduled (nil when off or not allowed).
    private(set) var nextNotification: Date?

    private let store: BriefSnapshotStore?
    private let inventory: InventoryModel
    private let licences: LicenceModel
    private let worktrack: WorkTrackModel
    private let operations: OperationsModel
    private let releases: ReleaseCenterModel
    private let monitor: MonitorModel

    init(inventory: InventoryModel, licences: LicenceModel, worktrack: WorkTrackModel, operations: OperationsModel,
         releases: ReleaseCenterModel, monitor: MonitorModel) {
        self.inventory = inventory
        self.licences = licences
        self.worktrack = worktrack
        self.operations = operations
        self.releases = releases
        self.monitor = monitor
        store = (try? BriefSnapshotStore.defaultFileURL()).map(BriefSnapshotStore.init(fileURL:))
        history = store?.load() ?? BriefSnapshotHistory()
    }

    static var isNotificationOn: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
    static var hour: Int { UserDefaults.standard.object(forKey: hourKey) as? Int ?? BriefSchedule.defaultHour }
    static var minute: Int { UserDefaults.standard.object(forKey: minuteKey) as? Int ?? BriefSchedule.defaultMinute }

    // MARK: Collecting

    /// Everything the brief is built from, as the models hold it right now.
    func input(now: Date = .now) -> BriefInput {
        let ops: [BriefOperationsInput] = [
            BriefOperationsInput(product: .talar, isSignedIn: operations.talar.isSignedIn, counts: operations.talar.counts,
                                 loadError: operations.talar.loadError),
            BriefOperationsInput(product: .safeBeauty, isSignedIn: operations.safeBeauty.isSignedIn, counts: operations.safeBeauty.counts,
                                 loadError: operations.safeBeauty.loadError),
            BriefOperationsInput(product: .velro, isSignedIn: operations.velro.isSignedIn, counts: operations.velro.counts,
                                 loadError: operations.velro.loadError),
        ]
        return BriefInput(
            now: now,
            monitor: monitor.snapshot,
            monitorTargets: monitor.targets,
            releases: releases.snapshot,
            licences: BriefLicenceInput(isLoaded: licences.isLoaded, records: licences.records, lastSyncedAt: licences.lastSyncedAt),
            worktrack: BriefWorkTrackInput(isSignedIn: worktrack.isSignedIn, environment: worktrack.environment?.rawValue,
                                           companies: worktrack.companies, lastRead: worktrack.lastRead, loadError: worktrack.loadError),
            operations: ops,
            oversight: BriefOversightInput(repos: inventory.oversight, recentChanges: inventory.recentOversightChanges))
    }

    /// The brief for right now, with the changes since the last snapshot of an earlier day.
    func brief(now: Date = .now) -> DailyBrief {
        let input = input(now: now)
        let today = BriefDailySnapshot.capture(input)
        let changes = history.baseline(before: today.day).map { BriefDiff.lines(from: $0, to: today, targets: input.monitorTargets) }
        return DailyBriefBuilder.build(input, changes: changes)
    }

    var baseline: BriefDailySnapshot? { history.baseline(before: BriefDailySnapshot.dayKey(.now)) }

    // MARK: Snapshot and notification (called from the app's refresh loop)

    /// Stores today's snapshot and reschedules the morning notification with the current brief.
    func record() async {
        history.record(BriefDailySnapshot.capture(input()))
        try? store?.save(history)
        await reschedule()
    }

    /// One pending notification at the next HH:MM, worded from the brief as it is now and saying so ("As of …").
    /// It is rebuilt after every refresh while the app runs, so it is at most one refresh old; if the app was closed
    /// overnight it still says when it was built.
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard Self.isNotificationOn else {
            nextNotification = nil
            return
        }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
            nextNotification = nil
            return
        }
        let now = Date.now
        let fire = BriefSchedule.nextFire(after: now, hour: Self.hour, minute: Self.minute)
        let text = BriefNotificationText.content(brief(now: now), asOf: now.formatted(date: .abbreviated, time: .shortened))
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
        do {
            try await center.add(request)
            nextNotification = fire
        } catch {
            nextNotification = nil
        }
    }
}
