import Foundation

// MARK: - What this device remembers between syncs (desk-sync.json)

public struct DeskSyncState: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var marks: CloudTableState<DeskMark>
    public var obligations: CloudTableState<ObligationCloudPayload>
    public var vendors: CloudTableState<VendorCloudPayload>
    /// The read time of the last ledger reading this Mac sent (so a reading is sent once).
    public var ledgerSentAt: Date?
    /// Why the server refused the last reading, if it did.
    public var ledgerRefused: String?
    /// The Mac's reading as the cloud holds it: what iPhone and iPad show, kept so it shows offline too.
    public var cloudLedger: CloudLedgerSnapshot?
    /// Seed rows the server refused (none are expected), with its reason.
    public var seedRefused: [String: String]
    /// Rows this version of the app could not read at the last sync (written by a later version).
    public var unreadableRows: Int
    public var lastSyncedAt: Date?

    public init() {
        version = Self.currentVersion
        marks = CloudTableState()
        obligations = CloudTableState()
        vendors = CloudTableState()
        seedRefused = [:]
        unreadableRows = 0
    }

    private enum CodingKeys: String, CodingKey {
        case version, marks, obligations, vendors, ledgerSentAt, ledgerRefused, cloudLedger, seedRefused, unreadableRows, lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        marks = try c.decodeIfPresent(CloudTableState<DeskMark>.self, forKey: .marks) ?? CloudTableState()
        obligations = try c.decodeIfPresent(CloudTableState<ObligationCloudPayload>.self, forKey: .obligations) ?? CloudTableState()
        vendors = try c.decodeIfPresent(CloudTableState<VendorCloudPayload>.self, forKey: .vendors) ?? CloudTableState()
        ledgerSentAt = try c.decodeIfPresent(Date.self, forKey: .ledgerSentAt)
        ledgerRefused = try c.decodeIfPresent(String.self, forKey: .ledgerRefused)
        cloudLedger = try? c.decodeIfPresent(CloudLedgerSnapshot.self, forKey: .cloudLedger)
        seedRefused = try c.decodeIfPresent([String: String].self, forKey: .seedRefused) ?? [:]
        unreadableRows = try c.decodeIfPresent(Int.self, forKey: .unreadableRows) ?? 0
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    public var conflictCount: Int { marks.conflicts.count + obligations.conflicts.count + vendors.conflicts.count }
    public var refusedCount: Int {
        marks.refused.count + obligations.refused.count + vendors.refused.count + seedRefused.count + (ledgerRefused == nil ? 0 : 1)
    }
}

/// `desk-sync.json` next to the inventory: what this device and the server last agreed on, the conflicts, and the Mac's
/// ledger reading as the cloud holds it. A file that can't be read is reported and never overwritten.
public struct DeskSyncStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "desk-sync.json")
    }

    public enum LoadResult: Sendable {
        case empty
        case loaded(DeskSyncState)
        case unreadable(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .empty }
        do {
            let state = try InventoryCoding.decoder().decode(DeskSyncState.self, from: Data(contentsOf: fileURL))
            guard state.version <= DeskSyncState.currentVersion else {
                return .unreadable(LF("written by a newer version of the app (version %ld)", state.version))
            }
            return .loaded(state)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func save(_ state: DeskSyncState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(state).write(to: fileURL, options: [.atomic])
    }
}

// MARK: - One sync

/// What this device holds, at the moment the sync starts.
public struct DeskCloudLocal: Sendable {
    public var desk: DeskState
    /// Nil when obligations.json could not be read: obligations and accounts are then not synced at all.
    public var obligations: ObligationsFile?
    /// The Mac's newest ledger reading (nil on iPhone and iPad).
    public var ledger: CloudLedgerUpload?

    public init(desk: DeskState, obligations: ObligationsFile?, ledger: CloudLedgerUpload? = nil) {
        self.desk = desk
        self.obligations = obligations
        self.ledger = ledger
    }
}

public struct DeskCloudReport: Hashable, Sendable {
    /// Rows written to the server.
    public var sent = 0
    /// Rows taken in from the server.
    public var received = 0
    public var conflicts = 0
    public var refused = 0
    /// Rows a later version of the app wrote, which this one leaves alone.
    public var unreadable = 0
    /// What became of the ledger reading this Mac sent, if it sent one.
    public var ledger: CloudLedgerPushResult.Status?

    public init() {}
}

/// The outcome of one sync: the new state, and what to take into this device's files.
public struct DeskCloudSyncResult: Sendable {
    public var state: DeskSyncState
    /// Marks to take in, by cloud key (nil: remove).
    public var marks: [String: DeskMark?]
    public var obligations: [String: ObligationCloudPayload?]
    public var vendors: [String: VendorCloudPayload?]
    /// Undo intents that reached the server or no longer need to: cloud keys, and "done:" row ids.
    public var settledRestores: Set<String>
    public var settledReopens: Set<String>
    public var report: DeskCloudReport

    /// What this device held for each row when the sync started, and the base before the sync for the rows taken in.
    var markSnapshot: [String: CloudLocal<DeskMark>]
    var obligationSnapshot: [String: CloudLocal<ObligationCloudPayload>]
    var vendorSnapshot: [String: CloudLocal<VendorCloudPayload>]
    var markBaseBefore: [String: CloudRow<DeskMark>?]
    var obligationBaseBefore: [String: CloudRow<ObligationCloudPayload>?]
    var vendorBaseBefore: [String: CloudRow<VendorCloudPayload>?]

    /// Takes the server's rows into the files as they are now. A row the owner changed here while the sync ran is left
    /// as he made it, and its base goes back to what it was, so the next sync sees both changes (a conflict if they
    /// differ) instead of sending his over the other device's.
    public func apply(desk: DeskState, obligations file: ObligationsFile?, known: Set<String>)
    -> (desk: DeskState, obligations: ObligationsFile?, state: DeskSyncState) {
        var state = self.state
        var d = desk
        let nowMarks = DeskCloudMapping.localMarks(desk)
        for key in marks.keys.sorted() {
            if (nowMarks[key] ?? .absent).same(as: markSnapshot[key] ?? .absent) {
                DeskCloudMapping.set(marks[key] ?? nil, key: key, in: &d, known: known)
            } else if let before = markBaseBefore[key] {
                state.marks.base[key] = before
            }
        }
        for key in settledRestores where (nowMarks[key] ?? .absent).same(as: .deleted) {
            d.restored = d.restored.filter { DeskCloudKey.cloud($0) != key }
        }
        guard var f = file else { return (d, nil, state) }
        let nowObligations = DeskCloudMapping.localObligations(f)
        let nowVendors = DeskCloudMapping.localVendors(f)
        for id in obligations.keys.sorted() {
            if (nowObligations[id] ?? .absent).same(as: obligationSnapshot[id] ?? .absent) {
                DeskCloudMapping.set(obligations[id] ?? nil, id: id, in: &f)
            } else if let before = obligationBaseBefore[id] {
                state.obligations.base[id] = before
            }
        }
        for id in vendors.keys.sorted() {
            if (nowVendors[id] ?? .absent).same(as: vendorSnapshot[id] ?? .absent) {
                DeskCloudMapping.set(vendors[id] ?? nil, id: id, in: &f)
            } else if let before = vendorBaseBefore[id] {
                state.vendors.base[id] = before
            }
        }
        for id in settledReopens where (nowObligations[id] ?? .absent).same(as: .deleted) {
            f.reopened.removeAll { DeskCloudMapping.obligationRowID("done", $0.obligationID, due: $0.due) == id }
        }
        return (d, f, state)
    }
}

public enum DeskCloudSync {
    /// At most this many rows per push call (the server's limit).
    static let batch = 500

    /// Pulls every row, merges each with this device's (`DeskCloudMerge`), sends what changed here with the version it
    /// is based on, and the Mac's ledger reading when it is newer than the last one sent. Conflicts are kept, never
    /// resolved here.
    public static func sync(local: DeskCloudLocal, state: DeskSyncState, remote: DeskCloudRemote, device: CloudDevice = .current,
                            now: Date, seed: [Obligation] = ObligationSeed.obligations,
                            seedAccounts: [VendorAccount] = ObligationSeed.accounts,
                            seedRevision: Int = ObligationSeed.revision) async throws -> DeskCloudSyncResult {
        let pull = try await remote.pull()
        var st = state
        var report = DeskCloudReport()
        report.unreadable = pull.unreadable
        st.unreadableRows = pull.unreadable

        // Marks.
        let markLocal = DeskCloudMapping.localMarks(local.desk)
        let markBase = st.marks.base
        let m = try await round(&st.marks, local: markLocal, remote: pull.marks, entryKey: { _ in ("mark", nil) }, merge: nil,
                                extra: [], now: now) { try await remote.pushMarks($0, device: device) }

        // Obligations and accounts (not when obligations.json could not be read: nothing of it is known here). The seed is
        // sent too, for the server's sweep, and never taken back in.
        var o = RoundOutput<ObligationCloudPayload>()
        var v = RoundOutput<VendorCloudPayload>()
        var obligationLocal: [String: CloudLocal<ObligationCloudPayload>] = [:]
        var vendorLocal: [String: CloudLocal<VendorCloudPayload>] = [:]
        let obligationBase = st.obligations.base
        let vendorBase = st.vendors.base
        if let file = local.obligations {
            obligationLocal = DeskCloudMapping.localObligations(file)
            vendorLocal = DeskCloudMapping.localVendors(file)
            let seedRows = DeskCloudMapping.seedChanges(remote: pull.obligations, seed: seed, revision: seedRevision)
            o = try await round(&st.obligations, local: obligationLocal, remote: pull.obligations.filter { $0.entry != "seed" },
                                entryKey: { DeskCloudMapping.obligationEntryKey($0).map { ($0.entry, $0.key) } }, merge: nil, extra: seedRows, now: now) {
                try await remote.pushObligations($0, device: device)
            }
            let seedAccountRows = DeskCloudMapping.seedAccountChanges(remote: pull.vendors, accounts: seedAccounts, revision: seedRevision)
            v = try await round(&st.vendors, local: vendorLocal, remote: pull.vendors.filter { $0.entry != "seed" },
                                entryKey: { DeskCloudMapping.vendorEntryKey($0).map { ($0.entry, $0.key) } }, merge: DeskCloudMerge.mergeVendor, extra: seedAccountRows,
                                now: now) {
                try await remote.pushVendors($0, device: device)
            }
            for (id, why) in o.extraRefused.merging(v.extraRefused, uniquingKeysWith: { a, _ in a }) { st.seedRefused[id] = why }
            for id in o.extraApplied.union(v.extraApplied) { st.seedRefused[id] = nil }
        }

        // The Mac's ledger reading, when it is newer than the one last sent.
        st.cloudLedger = pull.ledger
        if let upload = local.ledger, upload.readAt > (st.ledgerSentAt ?? .distantPast) {
            let r = try await remote.replaceLedger(expectedVersion: pull.ledger?.version ?? 0, reading: upload)
            report.ledger = r.status
            switch r.status {
            case .applied, .unchanged:
                st.ledgerSentAt = upload.readAt
                st.ledgerRefused = nil
                st.cloudLedger = CloudLedgerSnapshot(version: r.version ?? 0, readAt: upload.readAt, digest: upload.digest,
                                                     writtenOn: .macOS, updatedAt: now, sources: upload.sources, items: upload.items)
            case .older:
                st.ledgerSentAt = upload.readAt
            case .stale:
                break   // the server moved on since the pull; sent again at the next sync
            case .invalid:
                // Not sent again until the next reading.
                st.ledgerSentAt = upload.readAt
                st.ledgerRefused = r.message ?? L("Refused by the server.")
            }
        }

        st.lastSyncedAt = now
        report.sent = m.sent + o.sent + v.sent
        report.received = m.received + o.received + v.received
        report.conflicts = st.conflictCount
        report.refused = st.refusedCount
        return DeskCloudSyncResult(
            state: st, marks: m.changes, obligations: o.changes, vendors: v.changes,
            settledRestores: m.settledDeletes, settledReopens: Set(o.settledDeletes.filter { $0.hasPrefix("done:") }), report: report,
            markSnapshot: markLocal, obligationSnapshot: obligationLocal, vendorSnapshot: vendorLocal,
            markBaseBefore: Dictionary(uniqueKeysWithValues: m.changes.keys.map { ($0, markBase[$0]) }),
            obligationBaseBefore: Dictionary(uniqueKeysWithValues: o.changes.keys.map { ($0, obligationBase[$0]) }),
            vendorBaseBefore: Dictionary(uniqueKeysWithValues: v.changes.keys.map { ($0, vendorBase[$0]) }))
    }

    // MARK: Conflicts

    /// The owner's choice for a conflict. `thisDevice` keeps this device's version and sends it over the server's at the
    /// next sync; `otherDevice` takes the server's version in. Returns the value to write into this device's file for
    /// `otherDevice` (`.some(nil)`: remove it), nil when nothing is to be written here.
    public static func resolve<P: CloudPayload>(_ table: inout CloudTableState<P>, id: String, keepThisDevice: Bool) -> P?? {
        guard let conflict = table.conflicts.removeValue(forKey: id) else { return nil }
        // The server's row becomes the base either way: this device has seen it.
        table.base[id] = conflict.remote
        table.refused[id] = nil
        return keepThisDevice ? nil : .some(conflict.remote.value)
    }

    /// Writes a mark taken from the cloud (a conflict's other side) into the state.
    public static func take(_ mark: DeskMark?, key: String, into desk: inout DeskState, known: Set<String>) {
        DeskCloudMapping.set(mark, key: key, in: &desk, known: known)
    }

    public static func take(_ value: ObligationCloudPayload?, id: String, into file: inout ObligationsFile) {
        DeskCloudMapping.set(value, id: id, in: &file)
    }

    public static func take(_ value: VendorCloudPayload?, id: String, into file: inout ObligationsFile) {
        DeskCloudMapping.set(value, id: id, in: &file)
    }

    // MARK: One table

    struct RoundOutput<P: CloudPayload>: Sendable {
        var changes: [String: P?] = [:]
        var settledDeletes: Set<String> = []
        var sent = 0
        var received = 0
        var extraApplied: Set<String> = []
        var extraRefused: [String: String] = [:]
    }

    static func round<P: CloudPayload>(_ table: inout CloudTableState<P>, local: [String: CloudLocal<P>], remote: [CloudRow<P>],
                                       entryKey: (String) -> (entry: String, key: String?)?,
                                       merge: ((P?, P, P) -> P?)?, extra: [CloudChange<P>], now: Date,
                                       push: ([CloudChange<P>]) async throws -> [CloudPushResult<P>]) async throws -> RoundOutput<P> {
        var out = RoundOutput<P>()
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sends: [CloudChange<P>] = []
        var sent: [String: CloudLocal<P>] = [:]
        for id in Set(table.base.keys).union(local.keys).union(remoteByID.keys).sorted() {
            let here = local[id] ?? .absent
            let step = DeskCloudMerge.step(base: table.base[id], local: here, remote: remoteByID[id], dropped: table.dropped[id], merge: merge)
            switch step {
            case .keep:
                // Nothing to send any more: a refusal or a conflict about it no longer applies.
                table.conflicts[id] = nil
                table.refused[id] = nil
                if case .deleted = here { out.settledDeletes.insert(id) }
            case .forget:
                table.base[id] = nil
                table.conflicts[id] = nil
                table.refused[id] = nil
                if case .deleted = here { out.settledDeletes.insert(id) }
            case .adopt(let row):
                adopt(row, id: id, here: here, table: &table, out: &out)
            case .conflict(let mine, let theirs):
                table.conflicts[id] = CloudConflict(id: id, local: mine, remote: theirs, foundAt: table.conflicts[id]?.foundAt ?? now)
                table.refused[id] = nil
            case .push(let value, let expected):
                sends.append(change(id, value: value, expected: expected, table: table, remote: remoteByID[id], entryKey: entryKey))
                sent[id] = value.map(CloudLocal.value) ?? .deleted
            case .pushMerged(let merged, let expected):
                out.changes[id] = .some(merged)
                sends.append(change(id, value: merged, expected: expected, table: table, remote: remoteByID[id], entryKey: entryKey))
                sent[id] = .value(merged)
            }
        }

        // Nothing that reads as a key or token leaves this device (the server refuses it too): it is reported here.
        var clean: [CloudChange<P>] = []
        for change in sends {
            if let value = change.value {
                let kinds = ContinuityBundle.forbiddenKinds(in: value.fingerprint)
                if !kinds.isEmpty {
                    table.refused[change.id] = LF("Not sent: it holds what reads as %@.", kinds.map { L($0) }.joined(separator: ", "))
                    sent[change.id] = nil
                    continue
                }
            }
            clean.append(change)
        }
        let extraIDs = Set(extra.map(\.id))
        var results: [CloudPushResult<P>] = []
        let all = clean + extra
        for start in stride(from: 0, to: all.count, by: batch) {
            results += try await push(Array(all[start..<min(start + batch, all.count)]))
        }
        for r in results {
            if extraIDs.contains(r.id) {
                switch r.status {
                case .applied: out.extraApplied.insert(r.id)
                case .invalid: out.extraRefused[r.id] = r.message ?? L("Refused by the server.")
                case .stale: break   // another device sent it first
                }
                continue
            }
            guard let what = sent[r.id] else { continue }
            switch r.status {
            case .applied:
                table.base[r.id] = r.row
                table.conflicts[r.id] = nil
                table.refused[r.id] = nil
                table.dropped[r.id] = nil
                out.sent += 1
                if case .deleted = what { out.settledDeletes.insert(r.id) }
            case .stale:
                // Another device wrote it since the pull: decide again with what the server holds now, without sending twice.
                switch DeskCloudMerge.step(base: table.base[r.id], local: what, remote: r.row, dropped: table.dropped[r.id], merge: merge) {
                case .adopt(let row): adopt(row, id: r.id, here: what, table: &table, out: &out)
                case .conflict(let mine, let theirs):
                    table.conflicts[r.id] = CloudConflict(id: r.id, local: mine, remote: theirs, foundAt: table.conflicts[r.id]?.foundAt ?? now)
                default: break
                }
            case .invalid:
                table.refused[r.id] = r.message ?? L("Refused by the server.")
            }
        }
        return out
    }

    private static func adopt<P: CloudPayload>(_ row: CloudRow<P>, id: String, here: CloudLocal<P>, table: inout CloudTableState<P>,
                                               out: inout RoundOutput<P>) {
        table.base[id] = row
        table.conflicts[id] = nil
        table.refused[id] = nil
        table.dropped[id] = nil
        let holds: Bool = switch here {
        case .value(let v): v.same(as: row.value)
        case .deleted, .absent: row.value == nil
        }
        if !holds {
            // `.some`: a tombstone is a change too (nil would remove the key instead).
            out.changes[id] = .some(row.value)
            out.received += 1
        }
        if case .deleted = here { out.settledDeletes.insert(id) }
    }

    private static func change<P: CloudPayload>(_ id: String, value: P?, expected: Int64, table: CloudTableState<P>, remote: CloudRow<P>?,
                                                entryKey: (String) -> (entry: String, key: String?)?) -> CloudChange<P> {
        let parsed = entryKey(id)
        let entry = value?.entry ?? table.base[id]?.entry ?? remote?.entry ?? parsed?.entry ?? ""
        return CloudChange(id: id, entry: entry, key: parsed?.key, expectedVersion: expected, value: value)
    }
}

extension DeskSyncState {
    /// Records that this device dropped Desk marks as no longer applying here: they stay in the cloud for the devices
    /// where they still apply, and are not taken in again until they change there.
    public mutating func dropped(_ ids: Set<String>) {
        for id in ids {
            let key = DeskCloudKey.cloud(id)
            if let base = marks.base[key] { marks.dropped[key] = base.version }
        }
    }
}
