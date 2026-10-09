import Foundation

/// ETag cache for GitHub GETs. With it, `GitHubClient` sends `If-None-Match` and answers a 304 from
/// here, so an unchanged repository costs no rate limit (GitHub doesn't count authenticated 304s).
/// The entries are persisted with the platform hub cache, so this also works across launches.
public actor GitHubResponseCache {
    public struct Entry: Codable, Sendable, Equatable {
        public var etag: String
        public var body: Data
        public var storedAt: Date

        public init(etag: String, body: Data, storedAt: Date) {
            self.etag = etag
            self.body = body
            self.storedAt = storedAt
        }
    }

    private var entries: [String: Entry]
    /// 304 answers since this cache was created (for the refresh report).
    public private(set) var notModifiedCount = 0
    /// Entries older than this are dropped when the cache is saved, so it can't grow without bound.
    public static let maxAge: TimeInterval = 14 * 24 * 3600

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    func entry(for key: String) -> Entry? { entries[key] }

    func store(_ entry: Entry, for key: String) { entries[key] = entry }

    /// A 304 confirmed the entry is still current: count it and keep it fresh.
    func noteNotModified(_ key: String, at date: Date) {
        notModifiedCount += 1
        entries[key]?.storedAt = date
    }

    /// Entries worth keeping, for persistence.
    public func persistable(now: Date = .now) -> [String: Entry] {
        entries.filter { now.timeIntervalSince($0.value.storedAt) < Self.maxAge }
    }
}
