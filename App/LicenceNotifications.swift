import Foundation
import LinumicCore
import UserNotifications

/// Local reminders 30, 14, 7 and 1 days before a licence's last valid day, at 09:00 on this device.
/// Nothing leaves the device; the system shows them. Rebuilt from the ledger after every change.
@MainActor
enum LicenceNotifier {
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }
    private static let presenter = Presenter()
    private static let prefix = "licence-"
    /// iOS keeps at most 64 pending notifications per app; leave room for the others.
    private static let limit = 48

    static func reschedule(for records: [LicenceRecord]) async {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard UserDefaults.standard.object(forKey: LicenceModel.notifyKey) as? Bool ?? true else { return }
        let reminders = LicenceReminder.schedule(for: records).prefix(limit)
        guard !reminders.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for r in reminders {
            guard let day = LicenceDate.date(from: r.fireDay) else { continue }
            var when = LicenceDate.calendar.dateComponents([.year, .month, .day], from: day)
            when.hour = 9
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Licence expiring")
            let last = LicenceDate.date(from: r.expires)?.formatted(date: .abbreviated, time: .omitted) ?? r.expires
            content.body = String(localized: "\(r.product.displayName) licence \(r.licenceID) for \(r.customer) ends in \(r.daysBefore) days (last valid day \(last)).")
            content.sound = r.daysBefore <= 7 ? .default : nil
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }
}
