import Foundation
import LinumicCore
import UserNotifications

/// A local notification when a production queue (Talar halls or reviews, SafeBeauty KYC or approvals, VELRO
/// drivers) goes from empty to waiting. Counts only; nothing leaves the device. Settings → Integrations → Operations.
@MainActor
enum OperationsNotifier {
    static func post(_ changes: [OperationsCount]) async {
        guard !changes.isEmpty, UserDefaults.standard.object(forKey: OperationsModel.notifyKey) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Waiting for you")
            content.body = change.queue.sentence(change.count)
            content.sound = .default
            let id = "operations-\(change.queue.rawValue)-\(Int(change.readAt.timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
