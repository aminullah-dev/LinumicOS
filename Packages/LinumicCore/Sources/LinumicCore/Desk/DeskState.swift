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
    public var at: Date
    /// The item's fact hash when it was marked.
    public var factHash: String
    /// Snoozed until.
    public var until: Date?
    /// Why it was dismissed (required for a dismissal).
    public var reason: String?
    /// The item's title when it was marked, so a hidden item stays readable.
    public var title: String

    public init(kind: Kind, at: Date, factHash: String, until: Date? = nil, reason: String? = nil, title: String) {
        self.kind = kind
        self.at = at
        self.factHash = factHash
        self.until = until
        self.reason = reason
        self.title = title
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
    /// By item id.
    public var marks: [String: DeskMark]

    public init(marks: [String: DeskMark] = [:]) {
        version = Self.currentVersion
        self.marks = marks
    }

    // MARK: Marking

    public mutating func markDone(_ item: DeskItem, now: Date) {
        marks[item.id] = DeskMark(kind: .done, at: now, factHash: item.factHash, title: item.title)
    }

    public mutating func snooze(_ item: DeskItem, until: Date, now: Date) {
        marks[item.id] = DeskMark(kind: .snoozed, at: now, factHash: item.factHash, until: until, title: item.title)
    }

    public mutating func markWaiting(_ item: DeskItem, now: Date) {
        marks[item.id] = DeskMark(kind: .waiting, at: now, factHash: item.factHash, title: item.title)
    }

    /// Dismisses with a reason; an empty reason is refused (returns false).
    @discardableResult
    public mutating func dismiss(_ item: DeskItem, reason: String, now: Date) -> Bool {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return false }
        marks[item.id] = DeskMark(kind: .dismissed, at: now, factHash: item.factHash, reason: r, title: item.title)
        return true
    }

    /// Undoes any mark.
    public mutating func restore(_ id: String) {
        marks[id] = nil
    }

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
        guard let m = marks[item.id] else { return .open }
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

/// `desk-state.json` next to the inventory. Only the owner's marks: ids, kinds, times, hashes, titles and reasons.
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
