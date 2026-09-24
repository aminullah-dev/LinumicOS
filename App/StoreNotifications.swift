import Foundation
import LinumicCore
import UserNotifications

/// Local notifications for store changes. Nothing leaves the device: the system shows them.
@MainActor
enum StoreNotifier {
    /// Shows banners even while Linumic OS is in front.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }
    }

    private static let presenter = Presenter()

    /// Asks once, up front, so the first real change isn't lost to a permission prompt nobody saw.
    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ changes: [StoreChange]) async {
        guard !changes.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = change.store.title
            content.body = change.message
            if change.isImportant { content.sound = .default }
            try? await center.add(UNNotificationRequest(identifier: change.id.uuidString, content: content, trigger: nil))
        }
    }
}
