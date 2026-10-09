import Foundation
import LinumicCore
import UserNotifications

/// Local reminders 30, 14, 7 and 1 days before a WorkTrack customer's last licensed day, at 09:00 on this device.
/// Production customers only (demo and emulator companies aren't anyone's renewal). Rebuilt after every read.
@MainActor
enum WorkTrackNotifier {
    private static let prefix = "worktrack-"
    /// iOS keeps at most 64 pending notifications per app; licences use up to 48.
    private static let limit = 12

    static func reschedule(for companies: [WTCompany], environment: WorkTrackEnvironment?) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard environment == .production, UserDefaults.standard.object(forKey: WorkTrackModel.notifyKey) as? Bool ?? true else { return }
        let reminders = WorkTrackReminder.schedule(for: companies, today: WorkTrackDates.kabulToday()).prefix(limit)
        guard !reminders.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for r in reminders {
            guard let (y, m, d) = WorkTrackDates.parse(r.fireDay) else { continue }
            let when = DateComponents(year: y, month: m, day: d, hour: 9)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "WorkTrack licence expiring")
            let last = WorkTrackDates.displayDate(r.expiresAt)?.formatted(date: .abbreviated, time: .omitted) ?? r.expiresAt
            content.body = String(localized: "\(r.name) (\(r.plan)) ends in \(r.daysBefore) days (last day \(last)). Open WorkTrack customers to renew.")
            content.sound = r.daysBefore <= 7 ? .default : nil
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }
}
