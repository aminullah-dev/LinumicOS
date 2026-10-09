import CryptoKit
import Foundation
import LinumicCore
import Observation

/// The licence centre: the ledger (local cache + Supabase), the signing keys (Mac only) and the
/// issue / renew / void actions. Views call this; the protocol work is in LinumicCore.
@MainActor
@Observable
final class LicenceModel {
    enum SyncState: Equatable {
        case localOnly
        case synced(Date)
        case offline(String)
        case pendingUpload(String)
    }

    private(set) var records: [LicenceRecord] = []
    private(set) var isLoaded = false
    private(set) var isSyncing = false
    private(set) var syncState: SyncState = .localOnly
    /// Licence ids whose signed contents differ between this device and the server.
    private(set) var conflicts: [String] = []
    private(set) var keyPresent: [LicenceProduct: Bool] = [:]
    var errorMessage: String?

    static let notifyKey = "LCCNotifyLicenceExpiry"

    /// Issuing needs a private key in this device's Keychain; that is supported on the Mac only.
    static var canIssue: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private let inventory: InventoryModel
    private let store: LicenceLedgerStore?
    private let keys: LicenceSigningKeys
    private var needsUpload = false
    private(set) var lastSyncedAt: Date?
    private var saveTask: Task<Void, Never>?

    init(inventory: InventoryModel) {
        self.inventory = inventory
        self.keys = LicenceSigningKeys(secrets: inventory.secrets)
        self.store = (try? LicenceLedgerStore.defaultFileURL()).map(LicenceLedgerStore.init(fileURL:))
        refreshKeyPresence()
    }

    var summary: LicenceSummary { LicenceSummary(records: records) }

    func record(licenceID: String) -> LicenceRecord? { records.first { $0.licenceID == licenceID } }

    /// Licences that renewed or replaced this one.
    func successors(of record: LicenceRecord) -> [LicenceRecord] { records.filter { $0.renewedFrom == record.licenceID } }

    // MARK: Load and sync

    func load() async {
        if let store {
            do {
                let file = try await store.load()
                records = LicenceLedger.sorted(file.records)
                needsUpload = file.needsUpload
                lastSyncedAt = file.lastSyncedAt
            } catch {
                errorMessage = String(localized: "Could not read the licence ledger: \(error.localizedDescription)")
            }
        }
        isLoaded = true
        await LicenceNotifier.reschedule(for: records)
        await sync()
    }

    /// Merges with the server record by record (nothing is deleted on either side).
    func sync() async {
        guard let remote = inventory.licenceRemote() else {
            syncState = needsUpload || lastSyncedAt == nil ? .localOnly : .synced(lastSyncedAt!)
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await LicenceSync.sync(local: records, remote: remote)
            records = result.records
            conflicts = result.conflicts.map(\.licenceID)
            needsUpload = false
            lastSyncedAt = .now
            syncState = .synced(.now)
            persist()
            await LicenceNotifier.reschedule(for: records)
        } catch {
            syncState = needsUpload ? .pendingUpload(error.localizedDescription) : .offline(error.localizedDescription)
        }
    }

    private func persist() {
        guard let store else { return }
        let file = LicenceLedgerFile(records: records, needsUpload: needsUpload, lastSyncedAt: lastSyncedAt)
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do { try await store.save(file) } catch {
                await MainActor.run { self.errorMessage = String(localized: "Could not save the licence ledger: \(error.localizedDescription)") }
            }
        }
    }

    /// Saves a local change, then uploads it when signed in.
    private func commit(_ changed: [LicenceRecord]) {
        for r in changed {
            if let i = records.firstIndex(where: { $0.licenceID == r.licenceID }) { records[i] = r } else { records.append(r) }
        }
        records = LicenceLedger.sorted(records)
        needsUpload = true
        persist()
        Task {
            await LicenceNotifier.reschedule(for: records)
            await sync()
        }
    }

    private var createdBy: String {
        if let email = inventory.cloudUser?.email { return "Linumic OS (\(email))" }
        return "Linumic OS"
    }

    // MARK: Signing keys

    func refreshKeyPresence() {
        for p in LicenceProduct.allCases { keyPresent[p] = Self.canIssue && keys.hasKey(for: p) }
    }

    func hasKey(_ product: LicenceProduct) -> Bool { keyPresent[product] ?? false }

    /// Checks the key against the built-in public key, then stores it in the Keychain.
    func importKey(pem: String, for product: LicenceProduct) throws {
        try keys.importKey(pem: pem, for: product)
        refreshKeyPresence()
    }

    func removeKey(for product: LicenceProduct) throws {
        try keys.removeKey(for: product)
        refreshKeyPresence()
    }

    private func signingKey(for product: LicenceProduct) throws -> P256.Signing.PrivateKey {
        guard Self.canIssue, let key = try keys.signingKey(for: product) else { throw LicenceModelError.noSigningKey(product) }
        return key
    }

    // MARK: Actions

    /// Signs a new licence. Syncs first (best effort) so the next id accounts for the server ledger.
    func issue(_ request: LicenceRequest) async throws -> LicenceRecord {
        await sync()
        let record = try LicenceLedger.issue(request, signingKey: try signingKey(for: request.product), ledger: records, createdBy: createdBy)
        commit([record])
        return record
    }

    /// A new licence for the same customer with a new expiry (and, if needed, a new machine code). The old one becomes superseded.
    func renew(_ old: LicenceRecord, expires: String?, machine: String, notes: String) async throws -> LicenceRecord {
        await sync()
        let current = record(licenceID: old.licenceID) ?? old
        let (renewed, superseded) = try LicenceLedger.renew(current, expires: expires, machine: machine, notes: notes,
                                                            signingKey: try signingKey(for: old.product), ledger: records, createdBy: createdBy)
        commit([superseded, renewed])
        return renewed
    }

    func void(_ record: LicenceRecord, reason: String) {
        commit([LicenceLedger.void(record, reason: reason)])
    }

    func updateNotes(_ record: LicenceRecord, notes: String) {
        var r = record
        r.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        r.updatedAt = .now
        commit([r])
    }

    /// Imports `issued.csv` (and this app's CSV export) plus any `.lnmlic` files, in one go.
    /// Returns a summary for the owner.
    func importFiles(_ files: [(name: String, text: String)]) -> String {
        var added: [LicenceRecord] = []
        var lines: [String] = []
        var working = records
        for file in files where !file.name.lowercased().hasSuffix(".lnmlic") {
            let result = LicenceCSV.importLedger(file.text, existing: working)
            added += result.added
            working += result.added
            lines.append(String(localized: "\(file.name): \(result.added.count) added, \(result.skipped.count) already in the ledger, \(result.rejected.count) rejected."))
            lines += result.rejected.map { String(localized: "Line \($0.line): \($0.reason)") }
        }
        let keyFiles = files.filter { $0.name.lowercased().hasSuffix(".lnmlic") }
        var changed = added
        if !keyFiles.isEmpty {
            let result = LicenceCSV.attach(keys: keyFiles, to: working)
            let touched = Set(result.attached + result.addedFromKey)
            let addedIDs = Set(added.map(\.licenceID))
            changed = result.records.filter { touched.contains($0.licenceID) || addedIDs.contains($0.licenceID) }
            lines.append(String(localized: "Keys: \(result.attached.count) attached, \(result.addedFromKey.count) added from the key file, \(result.rejected.count) rejected."))
            lines += result.rejected
        }
        if !changed.isEmpty { commit(changed) }
        return lines.joined(separator: "\n")
    }

    func exportCSV() -> String { LicenceCSV.export(records) }
}

enum LicenceModelError: LocalizedError {
    case noSigningKey(LicenceProduct)

    var errorDescription: String? {
        switch self {
        case .noSigningKey(let p):
            String(localized: "No \(p.displayName) signing key on this Mac. Import it under Signing keys first.")
        }
    }
}
