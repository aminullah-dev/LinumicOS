import Foundation
import LinumicCore
import Observation

/// Desk sync (همگام‌سازی میز کار): the owner's Desk marks, his obligations and accounts, and the Mac's ledger reading,
/// with the cloud, so the iPhone shows the same Desk and the server reminds while the Mac is off (docs/desk-sync.md).
/// Rows are merged one by one with versions (`DeskCloudSync`); when both devices changed a row differently, nothing is
/// written over: both versions are kept and shown on the Desk until the owner picks one. Remembers what was agreed in
/// `desk-sync.json` on this device. Signed out, it does nothing and the Desk works as before.
@MainActor
@Observable
final class DeskSyncModel {
    /// Mac: send the ledgers' lines to the cloud for iPhone and iPad (default on).
    static let ledgerKey = "LCCDeskSyncLedgers"
    /// Mac: when the owner turned ledger lines off (the empty reading sent then empties the cloud copy).
    static let ledgerOffAtKey = "LCCDeskSyncLedgersOffAt"

    private(set) var state = DeskSyncState()
    /// Set when `desk-sync.json` exists but can't be read; nothing is synced (and the file is not overwritten) until it
    /// is fixed or removed.
    private(set) var loadError: String?
    private(set) var isSyncing = false
    private(set) var lastError: String?
    /// The RPCs answered 404: the migrations aren't applied to the project yet.
    private(set) var isDeployed = true
    private(set) var lastReport: DeskCloudReport?

    private var again = false
    private var running: Task<Outcome, Never>?
    private var soon: Task<Void, Never>?
    /// Marks dropped here while a sync ran: applied again on top of the state the sync leaves.
    private var pendingDrops: Set<String> = []
    /// Conflict choices made while a sync ran: made once it ends (the buttons are disabled meanwhile).
    private var pendingResolutions: [(Conflict, Bool)] = []
    private let store: DeskSyncStore?
    private let inventory: InventoryModel
    private let desk: DeskModel
    private let obligations: ObligationsModel

    init(inventory: InventoryModel, desk: DeskModel, obligations: ObligationsModel) {
        self.inventory = inventory
        self.desk = desk
        self.obligations = obligations
        store = (try? DeskSyncStore.defaultFileURL()).map(DeskSyncStore.init(fileURL:))
        switch store?.load() {
        case .loaded(let s)?: state = s
        case .unreadable(let why)?:
            loadError = String(localized: "desk-sync.json could not be read (\(why)). The Desk is not synced until the file is fixed or removed; removing it loses nothing you entered, and differences then show as conflicts.")
        case .empty?, nil: break
        }
        desk.cloud = self
        obligations.cloud = self
    }

    var isConnected: Bool { inventory.deskCloud() != nil }
    var cloudLedger: CloudLedgerSnapshot? { state.cloudLedger }

    static var sendsLedgers: Bool { UserDefaults.standard.object(forKey: ledgerKey) as? Bool ?? true }

    static func setSendsLedgers(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: ledgerKey)
        if on { UserDefaults.standard.removeObject(forKey: ledgerOffAtKey) } else { UserDefaults.standard.set(Date.now, forKey: ledgerOffAtKey) }
    }

    /// Mac: turns ledger lines on or off. Off sends an empty reading marked as turned off; on reads the ledgers now and
    /// sends that reading, whatever was sent before, so iPhone and iPad don't keep saying they are off.
    func setSendsLedgers(_ on: Bool) {
        Self.setSendsLedgers(on)
        if on {
            state.ledgerSentAt = nil
            save()
            Task { await desk.refreshLedgers() }   // its new reading starts a sync
        } else {
            syncSoon()
        }
    }

    enum Outcome {
        case synced(DeskCloudReport)
        case notConnected
        case notDeployed
        case failed(String)
    }

    // MARK: Syncing

    /// One sync now. Asked while one runs, one more follows it, and the caller waits for both.
    @discardableResult
    func sync() async -> Outcome {
        if let running {
            again = true
            return await running.value
        }
        let task = Task { await self.rounds() }
        running = task
        let outcome = await task.value
        running = nil
        // Choices the owner made while it ran, on the state it left.
        let choices = pendingResolutions
        pendingResolutions = []
        for (conflict, keep) in choices { resolve(conflict, keepThisDevice: keep) }
        return outcome
    }

    private func rounds() async -> Outcome {
        guard let remote = inventory.deskCloud() else { return .notConnected }
        if let loadError { return .failed(loadError) }
        // desk-state.json that can't be read is never written, so nothing is taken in until it is fixed.
        if let error = desk.loadError { return .failed(error) }
        isSyncing = true
        defer {
            isSyncing = false
            pendingDrops = []
        }
        var outcome = Outcome.synced(DeskCloudReport())
        repeat {
            again = false
            // obligations.json that can't be read is not synced at all: what it holds is unknown here.
            let file = obligations.loadError == nil ? obligations.file : nil
            let local = DeskCloudLocal(desk: desk.state, obligations: file, ledger: ledgerUpload())
            do {
                let result = try await DeskCloudSync.sync(local: local, state: state, remote: remote, now: .now)
                // Applied to the files as they are now: a change made while the sync ran is kept (see `apply`).
                let applied = result.apply(desk: desk.state, obligations: obligations.loadError == nil ? obligations.file : nil,
                                           known: desk.itemIDs())
                desk.takeFromCloud(applied.desk)
                if let f = applied.obligations { obligations.takeFromCloud(f) }
                state = applied.state
                // Marks dropped here while it ran stay dropped (the state the sync started from did not have them so).
                if !pendingDrops.isEmpty {
                    state.dropped(pendingDrops)
                    pendingDrops = []
                }
                save()
                lastReport = result.report
                lastError = nil
                isDeployed = true
                outcome = .synced(result.report)
            } catch SupabaseError.server(let status, _) where status == 404 {
                isDeployed = false
                lastError = nil
                return .notDeployed
            } catch {
                lastError = error.localizedDescription
                return .failed(error.localizedDescription)
            }
        } while again
        return outcome
    }

    /// A sync a few seconds after a change here (a mark, a Done, a new ledger reading), so the other device sees it soon;
    /// changes made together go in one sync.
    func syncSoon() {
        guard isConnected, loadError == nil else { return }
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// The Mac's newest reading, when ledger lines are sent; an empty one once after they were turned off.
    private func ledgerUpload() -> CloudLedgerUpload? {
        #if os(macOS)
        if Self.sendsLedgers {
            return desk.reading.map { DeskCloudLedger.upload($0, now: .now) }
        }
        return (UserDefaults.standard.object(forKey: Self.ledgerOffAtKey) as? Date).map(DeskCloudLedger.empty(at:))
        #else
        return nil
        #endif
    }

    /// Marks this device dropped as no longer applying here: they stay in the cloud for the devices where they apply.
    func dropped(_ ids: Set<String>) {
        guard loadError == nil else { return }
        if isSyncing { pendingDrops.formUnion(ids) }
        let before = state
        state.dropped(ids)
        if state != before { save() }
    }

    private func save() {
        guard loadError == nil else { return }
        try? store?.save(state)
    }

    // MARK: Conflicts

    /// Both devices changed one row differently: what each holds, in words.
    struct Conflict: Identifiable, Hashable {
        enum Table: Hashable { case marks, obligations, vendors }

        var table: Table
        var rowID: String
        var title: String
        var mine: String
        var theirs: String
        var theirsOn: CloudDevice?
        var theirsAt: Date?
        /// The server's version the owner saw: a choice is made only while the other side is still that version.
        var theirsVersion: Int64
        var foundAt: Date

        var id: String { "\(table)|\(rowID)" }
    }

    /// Every open conflict, oldest first.
    var conflicts: [Conflict] {
        guard state.conflictCount > 0 else { return [] }
        let items = desk.allItems()
        let register = obligations.register()
        var out: [Conflict] = []
        for c in state.marks.conflicts.values {
            let item = items.first { $0.id == c.id || DeskCloudKey.cloud($0.id) == c.id }
            out.append(Conflict(table: .marks, rowID: c.id,
                                title: item?.title ?? String(localized: "A Desk item that this device does not show"),
                                mine: Self.describe(c.local, of: item), theirs: Self.describe(c.remote.value, of: item),
                                theirsOn: c.remote.writtenOn, theirsAt: c.remote.updatedAt, theirsVersion: c.remote.version,
                                foundAt: c.foundAt))
        }
        for c in state.obligations.conflicts.values {
            let key = c.remote.key ?? c.id
            let title = register.obligation(key)?.displayTitle ?? key
            out.append(Conflict(table: .obligations, rowID: c.id, title: title, mine: Self.describe(c.local, entry: c.remote.entry),
                                theirs: Self.describe(c.remote.value, entry: c.remote.entry), theirsOn: c.remote.writtenOn,
                                theirsAt: c.remote.updatedAt, theirsVersion: c.remote.version, foundAt: c.foundAt))
        }
        for c in state.vendors.conflicts.values {
            let key = c.remote.key ?? c.id
            let title = register.accounts.first { $0.id == key }?.name ?? key
            out.append(Conflict(table: .vendors, rowID: c.id, title: title, mine: Self.describe(c.local), theirs: Self.describe(c.remote.value),
                                theirsOn: c.remote.writtenOn, theirsAt: c.remote.updatedAt, theirsVersion: c.remote.version,
                                foundAt: c.foundAt))
        }
        return out.sorted { ($0.foundAt, $0.id) < ($1.foundAt, $1.id) }
    }

    /// Keeps one side. This device's is sent over the other's at the next sync; the other's is taken in here now. Made
    /// while a sync runs, it waits for the sync to end (which would otherwise write the conflict back); and it is made
    /// only while the other side is still the version the owner saw, else the Desk shows the newer one to choose from.
    func resolve(_ conflict: Conflict, keepThisDevice: Bool) {
        guard loadError == nil else { return }
        if running != nil {
            pendingResolutions.append((conflict, keepThisDevice))
            return
        }
        let current: Int64? = switch conflict.table {
        case .marks: state.marks.conflicts[conflict.rowID]?.remote.version
        case .obligations: state.obligations.conflicts[conflict.rowID]?.remote.version
        case .vendors: state.vendors.conflicts[conflict.rowID]?.remote.version
        }
        guard current == conflict.theirsVersion else { return }
        switch conflict.table {
        case .marks:
            if case .some(let theirs) = DeskCloudSync.resolve(&state.marks, id: conflict.rowID, keepThisDevice: keepThisDevice) {
                var d = desk.state
                DeskCloudSync.take(theirs, key: conflict.rowID, into: &d, known: desk.itemIDs())
                desk.takeFromCloud(d)
            }
        case .obligations:
            if case .some(let theirs) = DeskCloudSync.resolve(&state.obligations, id: conflict.rowID, keepThisDevice: keepThisDevice) {
                var f = obligations.file
                DeskCloudSync.take(theirs, id: conflict.rowID, into: &f)
                obligations.takeFromCloud(f)
            }
        case .vendors:
            if case .some(let theirs) = DeskCloudSync.resolve(&state.vendors, id: conflict.rowID, keepThisDevice: keepThisDevice) {
                var f = obligations.file
                DeskCloudSync.take(theirs, id: conflict.rowID, into: &f)
                obligations.takeFromCloud(f)
            }
        }
        save()
        syncSoon()
    }

    // MARK: Words for each side

    static func describe(_ mark: DeskMark?, of item: DeskItem?) -> String {
        guard let mark else { return String(localized: "No mark (undone)") }
        let when = mark.at.formatted(date: .abbreviated, time: .shortened)
        switch mark.kind {
        case .done: return String(localized: "Done, \(when)")
        case .snoozed: return String(localized: "Snoozed until \((mark.until ?? mark.at).formatted(date: .abbreviated, time: .shortened))")
        case .waiting: return String(localized: "Waiting on others, since \(when)")
        case .dismissed: return String(localized: "Dismissed, \(when): \(mark.reason ?? "")")
        }
    }

    static func describe(_ value: ObligationCloudPayload?, entry: String) -> String {
        switch value {
        case nil:
            return entry == "done" ? String(localized: "Not done (reopened)") : String(localized: "Removed")
        case .row(let o)?, .seed(let o)?:
            return String(localized: "Added: \(o.displayTitle), due \(o.due?.description ?? String(localized: "date unknown"))")
        case .date(let d)?:
            return String(localized: "Due \(d.due.description) (source: \(d.source))")
        case .done(let c)?:
            return String(localized: "Done on \(c.on.description): \(c.evidence)")
        }
    }

    static func describe(_ value: VendorCloudPayload?) -> String {
        switch value {
        case nil:
            return String(localized: "Removed")
        case .account(let a)?, .seed(let a)?:
            return String(localized: "Added: \(a.name)")
        case .facts(let f)?:
            var parts: [String] = []
            if let e = f.edits.last(where: { $0.renewal != nil }), let day = e.renewal {
                parts.append(String(localized: "renewal \(day.description) (source: \(e.renewalSource ?? ""))"))
            }
            if let e = f.edits.last(where: { $0.holder != nil }), let holder = e.holder {
                parts.append(String(localized: "holder: \(holder.title)"))
            }
            if let cost = f.edits.last(where: { $0.cost != nil })?.cost {
                parts.append(cost.text)
            }
            return parts.isEmpty ? String(localized: "Nothing recorded") : parts.joined(separator: "; ")
        }
    }
}
