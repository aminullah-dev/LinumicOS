import Foundation

// MARK: - The owner's marks on Desk items (desk-state.json, this device)

/// What the owner did with one item.
public struct DeskMark: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case done
        case snoozed
        /// "Waiting on others": hidden until the fact changes.
        case waiting
        /// Dismissed with a reason: hidden until the fact changes.
        case dismissed
    }

    public var kind: Kind
    /// When it was marked, in whole seconds (see `DeskState.stamp`).
    public var at: Date
    /// The item's fact hash when it was marked.
    public var factHash: String
    /// Snoozed until.
    public var until: Date?
    /// Why it was dismissed (required for a dismissal), as the owner typed it.
    public var reason: String?

    // No title: a Brief line's title can name a customer or carry an email address, and nothing reads it back. A
    // file written before this had "title"; decoding ignores it.

    public init(kind: Kind, at: Date, factHash: String, until: Date? = nil, reason: String? = nil) {
        self.kind = kind
        self.at = at
        self.factHash = factHash
        self.until = until
        self.reason = reason
    }
}

/// How a mark applies to an item right now.
public enum DeskResolution: Hashable, Sendable {
    /// No mark, or one that no longer applies (a snooze that ended, a fact that changed).
    case open
    /// Done on something read from a source (a Brief line, an unread source), read again since and still there:
    /// shown again with "Still open according to <source>".
    case reopened(DeskMark)
    /// Done on a ledger line that still reads the same: "You marked it; the ledger is not ticked yet".
    case markedNotTicked(DeskMark)
    /// Snoozed, waiting on others, dismissed, or done until the next reading.
    case hidden(DeskMark)

    public var mark: DeskMark? {
        switch self {
        case .open: nil
        case .reopened(let m), .markedNotTicked(let m), .hidden(let m): m
        }
    }
}

public struct DeskState: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// By item id. A mark that came from the cloud for an item this device has not shown yet can be kept under the
    /// item's cloud key (`DeskCloudKey`), which `resolve` also looks up.
    public var marks: [String: DeskMark]
    /// Items whose mark the owner undid ("Restore") and that the cloud may still hold: the undo is sent as a deletion at
    /// the next sync, then forgotten. Nothing else removes a mark from the cloud: a mark this device drops because it no
    /// longer applies here (`remove`) stays there, for the devices where it still does.
    public var restored: Set<String>

    public init(marks: [String: DeskMark] = [:], restored: Set<String> = []) {
        version = Self.currentVersion
        self.marks = marks
        self.restored = restored
    }

    private enum CodingKeys: String, CodingKey { case version, marks, restored }

    // A file written before the cloud sync has no "restored".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        marks = try c.decode([String: DeskMark].self, forKey: .marks)
        restored = try c.decodeIfPresent(Set<String>.self, forKey: .restored) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(marks, forKey: .marks)
        // Sorted, so the file does not change between two saves of the same state.
        if !restored.isEmpty { try c.encode(restored.sorted(), forKey: .restored) }
    }

    /// The mark of an item: under its own id, or under its cloud key when it came from the cloud before this device
    /// showed the item.
    public func mark(for id: String) -> DeskMark? {
        if let m = marks[id] { return m }
        let key = DeskCloudKey.cloud(id)
        return key == id ? nil : marks[key]
    }

    /// Sets an item's mark under its own id (dropping a copy kept under its cloud key, and an undo not yet sent).
    private mutating func set(_ id: String, _ mark: DeskMark) {
        let key = DeskCloudKey.cloud(id)
        if key != id { marks[key] = nil }
        marks[id] = mark
        restored.remove(id)
        restored.remove(key)
    }

    // MARK: Marking

    /// A mark's time, rounded up to the next whole second. `desk-state.json` keeps whole seconds, so a mark read back
    /// after a relaunch is the same mark, and a reading made in the same second just before the mark still counts as
    /// earlier than it.
    public static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up))
    }

    public mutating func markDone(_ item: DeskItem, now: Date) {
        set(item.id, DeskMark(kind: .done, at: Self.stamp(now), factHash: item.factHash))
    }

    public mutating func snooze(_ item: DeskItem, until: Date, now: Date) {
        set(item.id, DeskMark(kind: .snoozed, at: Self.stamp(now), factHash: item.factHash, until: Self.stamp(until)))
    }

    public mutating func markWaiting(_ item: DeskItem, now: Date) {
        set(item.id, DeskMark(kind: .waiting, at: Self.stamp(now), factHash: item.factHash))
    }

    /// Dismisses with a reason; an empty reason is refused (returns false), and so is any reason on a Sales item that is
    /// not one of `SalesDismissReason`'s: the reason is synced, and a typed one could name the customer.
    @discardableResult
    public mutating func dismiss(_ item: DeskItem, reason: String, now: Date) -> Bool {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return false }
        if SalesDismissReason.applies(toItemID: item.id), SalesDismissReason(rawValue: r) == nil { return false }
        set(item.id, DeskMark(kind: .dismissed, at: Self.stamp(now), factHash: item.factHash, reason: r))
        return true
    }

    /// Undoes any mark, here and (at the next sync) in the cloud.
    public mutating func restore(_ id: String) {
        let key = DeskCloudKey.cloud(id)
        guard marks[id] != nil || marks[key] != nil else { return }
        marks[id] = nil
        marks[key] = nil
        restored.insert(id)
    }

    /// Drops marks that no longer apply on this device. Unlike `restore`, this is not sent to the cloud.
    public mutating func remove(_ ids: Set<String>) {
        for id in ids { marks[id] = nil }
    }

    // MARK: Rules (roadmap §4)

    /// - Snooze hides until its time.
    /// - Waiting on others and Dismiss hide until the fact hash changes.
    /// - Done on a ledger line moves it to "you marked it, the ledger is not ticked yet" until that line's text changes.
    /// - Done on anything read from a source hides it until the next reading; if it is still there, it comes back as
    ///   "still open according to <source>". When the source gives no read time, it stays hidden until the fact changes.
    public func resolve(_ item: DeskItem, now: Date) -> DeskResolution {
        guard let m = mark(for: item.id) else { return .open }
        switch m.kind {
        case .snoozed:
            return (m.until ?? .distantPast) > now ? .hidden(m) : .open
        case .waiting, .dismissed:
            return m.factHash == item.factHash ? .hidden(m) : .open
        case .done:
            guard m.factHash == item.factHash else { return .open }
            switch item.kind {
            case .task:
                return .markedNotTicked(m)
            case .fact, .source:
                if let readAt = item.evidence.readAt, readAt > m.at { return .reopened(m) }
                return .hidden(m)
            }
        }
    }
}

/// `desk-state.json` next to the inventory. Only the owner's marks: item ids, kinds, times, fact hashes and dismiss
/// reasons. No titles or details, so nothing a source said about a customer is written to disk.
public struct DeskStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "desk-state.json")
    }

    public enum LoadResult: Sendable {
        /// No file yet.
        case empty
        case loaded(DeskState)
        /// The file exists but can't be read; it is then never overwritten.
        case unreadable(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            return .loaded(try InventoryCoding.decoder().decode(DeskState.self, from: data))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func save(_ state: DeskState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(state).write(to: fileURL, options: [.atomic])
    }
}
