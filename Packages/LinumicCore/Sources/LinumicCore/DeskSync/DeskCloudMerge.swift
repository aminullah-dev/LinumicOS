import Foundation

// MARK: - Merging one row (never last-writer-wins)
//
// Each row is merged on its own, from three versions: what this device and the server last agreed on (the base), what
// this device holds now, and what the server holds now.
//
//   * only one side changed it: that side's version is kept (sent, or taken in);
//   * both changed it the same way: nothing to do;
//   * both changed it differently: a conflict. Nothing is written over: this device keeps its own version, the server
//     keeps its, and both are shown on the Desk until the owner picks one. (The facts recorded about one account are the
//     exception when the two sides recorded different facts, a renewal here and a cost there: both are kept.)
//
// A row missing on the server is never read as deleted (the server may have been restored from an older copy): it is
// sent again. A row missing on this device is never read as deleted either: only an undo the owner made here (a
// Restore, a Reopen) is sent as a deletion, as a tombstone.

/// What this device holds for one row.
public enum CloudLocal<P: CloudPayload>: Hashable, Sendable {
    case value(P)
    /// The owner undid it on this device (a Restore on the Desk, a Reopen of a Done).
    case deleted
    /// Not on this device and not undone here: never here, dropped here as no longer applying, or the file was lost.
    case absent

    var payload: P? { if case .value(let p) = self { p } else { nil } }

    /// The same, comparing values by what is written (`fingerprint`).
    func same(as other: CloudLocal<P>?) -> Bool {
        switch (self, other ?? .absent) {
        case let (.value(a), .value(b)): a.same(as: b)
        case (.deleted, .deleted), (.absent, .absent): true
        default: false
        }
    }
}

/// Both sides changed one row differently. Shown on the Desk with both versions until the owner picks one.
public struct CloudConflict<P: CloudPayload>: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// This device's version; nil when the owner undid it here.
    public var local: P?
    /// What the server holds (written by the other device).
    public var remote: CloudRow<P>
    public var foundAt: Date

    public init(id: String, local: P?, remote: CloudRow<P>, foundAt: Date) {
        self.id = id
        self.local = local
        self.remote = remote
        self.foundAt = foundAt
    }
}

/// What this device remembers about one table between syncs.
public struct CloudTableState<P: CloudPayload>: Codable, Hashable, Sendable {
    /// The rows as this device and the server last agreed on them, by row id.
    public var base: [String: CloudRow<P>]
    /// Rows both sides changed differently, by row id.
    public var conflicts: [String: CloudConflict<P>]
    /// Rows the server refused, with its reason. Sent again at each sync until they pass or change.
    public var refused: [String: String]
    /// Desk marks this device dropped as no longer applying here, at the version it had: the cloud keeps them (they may
    /// apply on another device) and they are not taken in again until they change there.
    public var dropped: [String: Int64]

    public init(base: [String: CloudRow<P>] = [:], conflicts: [String: CloudConflict<P>] = [:], refused: [String: String] = [:],
                dropped: [String: Int64] = [:]) {
        self.base = base
        self.conflicts = conflicts
        self.refused = refused
        self.dropped = dropped
    }

    private enum CodingKeys: String, CodingKey { case base, conflicts, refused, dropped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent([String: CloudRow<P>].self, forKey: .base) ?? [:]
        conflicts = try c.decodeIfPresent([String: CloudConflict<P>].self, forKey: .conflicts) ?? [:]
        refused = try c.decodeIfPresent([String: String].self, forKey: .refused) ?? [:]
        dropped = try c.decodeIfPresent([String: Int64].self, forKey: .dropped) ?? [:]
    }
}

/// What to do with one row in this sync.
public enum CloudStep<P: CloudPayload>: Hashable, Sendable {
    /// Nothing changed (or this device keeps a row it dropped).
    case keep
    /// Take the server's row in (its value, or its tombstone), here and as the new base.
    case adopt(CloudRow<P>)
    /// Send this device's value (nil: a tombstone), based on the server's version `expected`.
    case push(P?, expected: Int64)
    /// Both sides added to the row without contradicting each other: keep the union here and send it.
    case pushMerged(P, expected: Int64)
    /// Both sides changed it differently: keep both, show both.
    case conflict(local: P?, remote: CloudRow<P>)
    /// Neither the server nor this device holds it any more: forget the base.
    case forget
}

public enum DeskCloudMerge {
    /// The step for one row. `merge` may combine two different changes (account facts); nil keeps them as a conflict.
    public static func step<P: CloudPayload>(base: CloudRow<P>?, local: CloudLocal<P>, remote: CloudRow<P>?,
                                             dropped: Int64? = nil,
                                             merge: ((_ base: P?, _ local: P, _ remote: P) -> P?)? = nil) -> CloudStep<P> {
        let baseValue = base?.value
        let localValue: P?
        let localChanged: Bool
        switch local {
        case .value(let v):
            localValue = v
            localChanged = !v.same(as: baseValue)
        case .deleted:
            localValue = nil
            if base == nil {
                // An undo with nothing agreed before it (this device's sync state was lost or never existed): if the server
                // holds a value, it may be the one undone or another device's; both are shown, nothing is chosen.
                if let remote, remote.value != nil { return .conflict(local: nil, remote: remote) }
                return .keep
            }
            localChanged = baseValue != nil
        case .absent:
            localValue = baseValue
            localChanged = false
        }

        guard let remote else {
            // Not on the server: never read as a deletion. What this device holds is sent again; a row it dropped is not.
            let droppedHere: Bool = if case .absent = local { dropped != nil } else { false }
            if let v = localValue, !droppedHere { return .push(v, expected: 0) }
            return base == nil ? .keep : .forget
        }
        let remoteChanged = remote.version != (base?.version ?? 0)
        if !remoteChanged {
            guard localChanged else {
                // The file lost a row both sides had agreed on: take it in again (unless this device dropped it).
                if case .absent = local, remote.value != nil, dropped != remote.version { return .adopt(remote) }
                return .keep
            }
            return .push(localValue, expected: remote.version)
        }
        guard localChanged else { return .adopt(remote) }
        if cloudSame(localValue, remote.value) { return .adopt(remote) }
        if let merge, let l = localValue, let r = remote.value, let merged = merge(baseValue, l, r) {
            return cloudSame(merged, r) ? .adopt(remote) : .pushMerged(merged, expected: remote.version)
        }
        return .conflict(local: localValue, remote: remote)
    }

    /// Account facts recorded on both sides: kept together when the new facts on each side are about different things
    /// (a renewal here, a cost there), or say the same; a conflict (nil) when both recorded the same thing differently.
    public static func mergeFacts(base: AccountFacts?, local: AccountFacts, remote: AccountFacts) -> AccountFacts? {
        func print(_ e: VendorAccountEdit) -> Data { (try? InventoryCoding.encoder().encode(e)) ?? Data() }
        let known = Set((base?.edits ?? []).map(print))
        let localPrints = Set(local.edits.map(print))
        let newLocal = local.edits.filter { !known.contains(print($0)) }
        let newRemote = remote.edits.filter { !known.contains(print($0)) && !localPrints.contains(print($0)) }
        // The newest value each side recorded for each fact.
        func latest<T: Equatable>(_ edits: [VendorAccountEdit], _ value: (VendorAccountEdit) -> T?) -> T? {
            edits.sorted { $0.enteredAt < $1.enteredAt }.compactMap(value).last
        }
        func clash<T: Equatable>(_ value: (VendorAccountEdit) -> T?) -> Bool {
            guard let l = latest(newLocal, value), let r = latest(newRemote, value) else { return false }
            return l != r
        }
        if clash({ e in e.renewal.map { "\($0.description)|\(e.renewalSource ?? "")" } })
            || clash({ e in e.holder.map { "\($0.rawValue)|\(e.holderSource ?? "")" } })
            || clash({ e in e.cost }) {
            return nil
        }
        return AccountFacts(edits: local.edits + newRemote)
    }

    /// `mergeFacts` for the vendors table: only facts are combined; an account itself is never.
    static func mergeVendor(base: VendorCloudPayload?, local: VendorCloudPayload, remote: VendorCloudPayload) -> VendorCloudPayload? {
        guard case .facts(let l) = local, case .facts(let r) = remote else { return nil }
        var b: AccountFacts?
        if case .facts(let f)? = base { b = f }
        return mergeFacts(base: b, local: l, remote: r).map(VendorCloudPayload.facts)
    }
}
