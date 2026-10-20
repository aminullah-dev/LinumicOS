import Foundation
import LinumicCore
import Observation
import UserNotifications

/// Obligations & accounts (تعهدات و حساب‌ها): the register of dated obligations and of the accounts the company depends
/// on. Built on this device from the seed (facts recorded with a source), the owner's entries (`obligations.json`) and
/// the live dates the other models already read (the Monitor's RDAP and TLS readings, the licence ledger, the Keys &
/// Backups registry, the continuity export log). Writes only `obligations.json`. No network.
@MainActor
@Observable
final class ObligationsModel {
    static let notifyKey = "LCCNotifyObligations"
    private static let sentKey = "LCCObligationAlertsSent"

    private(set) var file = ObligationsFile()
    /// Set when `obligations.json` exists but can't be read; the file is then never overwritten.
    private(set) var loadError: String?
    /// The store's own reason for it, without the sentence around it (Money puts it in a sentence of its own).
    private(set) var loadFailure: String?
    var errorMessage: String?

    private let store: ObligationsStore?
    private let monitor: MonitorModel
    private let licences: LicenceModel
    private let keys: KeysModel
    private let continuity: ContinuityModel

    init(monitor: MonitorModel, licences: LicenceModel, keys: KeysModel, continuity: ContinuityModel) {
        self.monitor = monitor
        self.licences = licences
        self.keys = keys
        self.continuity = continuity
        store = (try? ObligationsStore.defaultFileURL()).map(ObligationsStore.init(fileURL:))
        switch store?.load() {
        case .loaded(let f)?: file = f
        case .unreadable(let why)?:
            loadFailure = why
            loadError = String(localized: "obligations.json could not be read (\(why)). The seed and the live dates are shown; nothing you enter is saved until the file is fixed or removed.")
        case .empty?, nil: break
        }
    }

    static var isNotifyOn: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }

    // MARK: Reading

    /// What the other models hold right now that carries dates. A source not read yet is left out (nil), which the
    /// register reports as a part not read.
    var liveInput: ObligationLiveInput {
        ObligationLiveInput(monitor: monitor.snapshot.lastRoundAt == nil && monitor.snapshot.domains.isEmpty ? nil : monitor.snapshot,
                            monitorHosts: Set(monitor.targets.map(\.host)),
                            licences: licences.isLoaded ? licences.records : nil,
                            licencesReadAt: licences.lastSyncedAt,
                            licencesSynced: licences.lastSyncedAt != nil,
                            keys: keys.loadError == nil ? keys.registry : nil,
                            // continuity.json that could not be read is unknown, not "no export yet".
                            continuity: continuity.isAvailable && continuity.loadError == nil ? continuity.log : nil)
    }

    func register(now: Date = .now) -> ObligationsRegister {
        ObligationsBuilder.build(file: file, live: liveInput, now: now)
    }

    var briefInput: BriefObligationsInput { BriefObligationsInput(register: register(), loadError: loadError) }

    // MARK: Changes (each saved at once, refused without its source or evidence)

    @discardableResult
    func add(title: String, product: String?, area: ObligationArea, due: KeyDay?, consequence: String?, source: String) -> Bool {
        mutate { try $0.add(title: title, product: product, area: area, due: due, consequence: consequence, source: source, now: .now) }
    }

    /// Only for a seed row or one of yours: a live row takes its day from its source, an account's renewal from the
    /// account (`editAccount`), so each day is entered in one place.
    @discardableResult
    func setDate(_ id: String, due: KeyDay, source: String) -> Bool {
        guard register().obligation(id)?.origin.takesDateHere == true else {
            errorMessage = String(localized: "This row takes its date from its own source (a reading, or the account's card), so it is not set here.")
            return false
        }
        return mutate { try $0.setDate(id, due: due, source: source, now: .now) }
    }

    /// Never for a live row: it closes only when its source records it.
    @discardableResult
    func complete(_ o: Obligation, on day: KeyDay, evidence: String) -> Bool {
        guard o.origin.takesDoneHere else {
            errorMessage = String(localized: "This row closes only when its own source records it (an export, a restore test, a new reading).")
            return false
        }
        return mutate { try $0.complete(o.id, due: o.due, on: day, evidence: evidence, now: .now) }
    }

    func reopen(_ o: Obligation) {
        mutate { $0.reopen(o.id, due: o.due) }
    }

    @discardableResult
    func addAccount(name: String, purpose: String, holder: AccountHolder?, source: String) -> Bool {
        mutate { try $0.addAccount(name: name, purpose: purpose, holder: holder, source: source, now: .now) }
    }

    @discardableResult
    func editAccount(_ id: String, renewal: KeyDay?, renewalSource: String?, holder: AccountHolder?, holderSource: String?,
                     cost: AccountCost?) -> Bool {
        mutate { try $0.editAccount(id, renewal: renewal, renewalSource: renewalSource, holder: holder, holderSource: holderSource,
                                    cost: cost, now: .now) }
    }

    @discardableResult
    private func mutate(_ change: (inout ObligationsFile) throws -> Void) -> Bool {
        guard loadError == nil else {
            errorMessage = loadError
            return false
        }
        var copy = file
        do {
            try change(&copy)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard copy != file else { return true }
        do {
            try store?.save(copy)
            file = copy
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Alerts at 30, 14, 7 and 1 days (and on the day)

    /// Posts what entered a new lead window since the last look, once per window (the key a server sweep would share),
    /// and forgets keys of obligations that are gone or closed. Called after each Daily Brief round.
    func postDueAlerts(now: Date = .now) async {
        let register = register(now: now)
        var sent = Set(UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [])
        let alerts = ObligationAlerts.due(register, today: KeyDay(now), sent: sent)
        let open = Set(register.obligations.filter { !$0.isClosed }.map(\.id))
        sent = sent.filter { key in open.contains { key.hasPrefix("obligation:\($0):") } }
        defer { UserDefaults.standard.set(Array(sent).sorted(), forKey: Self.sentKey) }
        guard !alerts.isEmpty else { return }
        guard Self.isNotifyOn else {
            // Off: nothing is posted, and nothing piles up for when it is turned on again.
            sent.formUnion(alerts.map(\.key))
            return
        }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        if alerts.count == 1, let a = alerts.first {
            content.title = String(localized: "Obligation due")
            content.body = ObligationsBriefRules.text(a.obligation, today: KeyDay(now))
                + (a.obligation.displayConsequence.map { " " + $0 } ?? "")
        } else {
            content.title = String(localized: "\(alerts.count) obligations due")
            content.body = alerts.prefix(4).map { ObligationsBriefRules.text($0.obligation, today: KeyDay(now)) }.joined(separator: "; ")
        }
        content.sound = alerts.contains { $0.lead <= 1 } ? .default : nil
        NotificationGate.apply(content)
        let id = "obligations.\(KeyDay(now).description).\(DeskHash.of(alerts.map(\.key)))"
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            sent.formUnion(alerts.map(\.key))
        } catch {
            // Not posted: tried again at the next round.
        }
    }
}
