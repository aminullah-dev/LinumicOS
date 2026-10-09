import Foundation
import LinumicCore
import UserNotifications

/// Local notifications for the Monitor: a target down on two checks in a row, its recovery, and a TLS certificate
/// or domain registration entering the 30, 14 or 7-day window. Nothing leaves the device.
/// Settings → Integrations → Monitor.
@MainActor
enum MonitorNotifier {
    static func post(_ alerts: [MonitorAlert], targets: [MonitorTarget], now: Date) async {
        guard !alerts.isEmpty, UserDefaults.standard.object(forKey: MonitorModel.notifyKey) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            let id: String
            switch alert {
            case .down(let targetID):
                guard let t = targets.first(where: { $0.id == targetID }) else { continue }
                content.title = String(localized: "\(t.product.title) is down")
                content.body = String(localized: "\(L(t.name)) (\(t.host)) failed two checks in a row.")
                id = "monitor-down-\(targetID)"
            case .recovered(let targetID):
                guard let t = targets.first(where: { $0.id == targetID }) else { continue }
                content.title = String(localized: "\(t.product.title) is back up")
                content.body = String(localized: "\(L(t.name)) (\(t.host)) answers again.")
                id = "monitor-up-\(targetID)"
            case .certificate(let host, let level, let days):
                content.title = String(localized: "TLS certificate ending")
                content.body = level == .expired
                    ? String(localized: "The certificate of \(host) has expired.")
                    : String(localized: "The certificate of \(host) ends in \(days) days.")
                id = "monitor-cert-\(host)-\(level.rawValue)"
            case .domain(let name, let level, let days):
                content.title = String(localized: "Domain registration ending")
                content.body = level == .expired
                    ? String(localized: "The registration of \(name) has expired.")
                    : String(localized: "The registration of \(name) ends in \(days) days. Renew it at the registrar.")
                id = "monitor-domain-\(name)-\(level.rawValue)"
            }
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "\(id)-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil))
        }
    }
}
