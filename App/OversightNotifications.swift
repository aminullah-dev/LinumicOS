import Foundation
import LinumicCore
import UserNotifications

/// Local notifications for oversight changes (new security alerts, broken CI, uncommitted work).
/// Nothing leaves the device; the system shows them.
@MainActor
enum OversightNotifier {
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }
    private static let presenter = Presenter()

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ changes: [OversightChange]) async {
        guard !changes.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Project oversight")
            content.body = change.message
            if change.isImportant { content.sound = .default }
            try? await center.add(UNNotificationRequest(identifier: change.id.uuidString, content: content, trigger: nil))
        }
    }
}
