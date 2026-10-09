import Foundation

// MARK: - Action log

/// Linumic OS's own record of a store action it sent (today only App Store releases): what, which version, the state
/// before and after, and the result. Kept on this device; App Store Connect keeps its own history too.
public struct ReleaseActionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Sent, accepted, and the read-back shows the version processing for distribution or live.
        case verified
        /// Sent and accepted, but the read-back didn't confirm it yet (or couldn't be read).
        case unverified
        /// Apple refused it, or it never arrived.
        case failed
        /// Not sent: the version wasn't waiting for a manual release any more, or couldn't be checked first.
        case notSent
    }

    public var id: UUID
    public var at: Date
    public var action: String
    public var appName: String
    public var appIdentifier: String
    public var versionID: String
    public var versionString: String
    public var platform: String
    public var buildNumber: String?
    public var stateBefore: String
    public var stateAfter: String?
    public var outcome: Outcome
    public var message: String?

    public init(id: UUID = UUID(), at: Date, action: String, appName: String, appIdentifier: String, versionID: String,
                versionString: String, platform: String, buildNumber: String?, stateBefore: String, stateAfter: String?,
                outcome: Outcome, message: String?) {
        self.id = id
        self.at = at
        self.action = action
        self.appName = appName
        self.appIdentifier = appIdentifier
        self.versionID = versionID
        self.versionString = versionString
        self.platform = platform
        self.buildNumber = buildNumber
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
        self.outcome = outcome
        self.message = message
    }
}

private let isoEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

private let isoDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

/// Append-only JSON file next to `inventory.json` (`release-actions.json`). Entries are never removed.
public actor ReleaseActionLog {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "release-actions.json")
    }

    /// Newest first. A missing file is an empty log.
    public func load() throws -> [ReleaseActionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try isoDecoder.decode([ReleaseActionRecord].self, from: Data(contentsOf: fileURL)).sorted { $0.at > $1.at }
    }

    public func append(_ record: ReleaseActionRecord) throws {
        var all = try load()
        all.append(record)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try isoEncoder.encode(all.sorted { $0.at < $1.at }).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Snapshot file

/// The last reading, per device (`release-center.json`). A cache of observations: deleting it costs one refresh.
public struct ReleaseCenterStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "release-center.json")
    }

    /// An unreadable or missing file is an empty snapshot (it is only a cache).
    public func load() -> ReleaseCenterSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return ReleaseCenterSnapshot() }
        return (try? isoDecoder.decode(ReleaseCenterSnapshot.self, from: data)) ?? ReleaseCenterSnapshot()
    }

    public func save(_ snapshot: ReleaseCenterSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try isoEncoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
