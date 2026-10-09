import Foundation

// Operations (عملیات): the queues across Talar, SafeBeauty and VELRO that wait for the owner, the dashboard's
// "Waiting for you" lines, and the 0 -> more-than-0 rule for notifications. Pure logic; no network here.

/// A queue that waits for the owner (or his staff) in one product's admin console.
public enum OperationsQueue: String, CaseIterable, Codable, Sendable, Identifiable {
    case talarHalls
    case talarReviews
    case safeBeautyKYC
    case safeBeautyApprovals
    case velroDrivers

    public var id: String { rawValue }

    public var product: OperationsProduct {
        switch self {
        case .talarHalls, .talarReviews: .talar
        case .safeBeautyKYC, .safeBeautyApprovals: .safeBeauty
        case .velroDrivers: .velro
        }
    }

    public var title: String {
        switch self {
        case .talarHalls: L("Halls awaiting approval")
        case .talarReviews: L("Reviews awaiting moderation")
        case .safeBeautyKYC: L("Identity checks (KYC) to review")
        case .safeBeautyApprovals: L("Salon owners awaiting approval")
        case .velroDrivers: L("Drivers awaiting approval")
        }
    }

    /// "3 halls are waiting for approval in Talar", for notifications and VoiceOver.
    public func sentence(_ count: Int) -> String {
        switch self {
        case .talarHalls: LF("Talar: %ld halls waiting for approval", count)
        case .talarReviews: LF("Talar: %ld reviews waiting for moderation", count)
        case .safeBeautyKYC: LF("SafeBeauty: %ld identity checks waiting for review", count)
        case .safeBeautyApprovals: LF("SafeBeauty: %ld salon owners waiting for approval", count)
        case .velroDrivers: LF("VELRO: %ld drivers waiting for approval", count)
        }
    }

    /// The queues on the dashboard card (the ones that block someone from starting work).
    public static let dashboard: [OperationsQueue] = [.talarHalls, .safeBeautyKYC, .safeBeautyApprovals, .velroDrivers]
}

public enum OperationsProduct: String, CaseIterable, Codable, Sendable, Identifiable {
    case talar, safeBeauty, velro

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .talar: "Talar"
        case .safeBeauty: "SafeBeauty"
        case .velro: "VELRO"
        }
    }

    public var symbol: String {
        switch self {
        case .talar: "building.columns"
        case .safeBeauty: "sparkles"
        case .velro: "car.2"
        }
    }
}

/// One count as read: from which environment, and when.
public struct OperationsCount: Codable, Equatable, Sendable, Identifiable {
    public var queue: OperationsQueue
    public var count: Int
    /// The environment's raw value (production, demo, staging, localEmulator, localBackend).
    public var environment: String
    public var readAt: Date
    public var id: String { queue.rawValue }

    public init(queue: OperationsQueue, count: Int, environment: String, readAt: Date) {
        self.queue = queue
        self.count = count
        self.environment = environment
        self.readAt = readAt
    }

    public var isProduction: Bool { environment == "production" }
}

public enum OperationsTransitions {
    /// Queues that were read before at 0 and are now above 0, in the same environment. A queue never read before
    /// (first sign-in) or read in another environment doesn't count: nobody knows it "became" non-empty.
    public static func newlyWaiting(previous: [OperationsCount], current: [OperationsCount]) -> [OperationsCount] {
        let before = Dictionary(previous.map { ($0.queue, $0) }, uniquingKeysWith: { a, _ in a })
        return current.filter { now in
            guard now.count > 0, let was = before[now.queue], was.environment == now.environment else { return false }
            return was.count == 0
        }
    }

    /// Replaces the counts of the queues just read, keeps the others.
    public static func merge(_ stored: [OperationsCount], with fresh: [OperationsCount]) -> [OperationsCount] {
        var byQueue = Dictionary(stored.map { ($0.queue, $0) }, uniquingKeysWith: { a, _ in a })
        for c in fresh { byQueue[c.queue] = c }
        return OperationsQueue.allCases.compactMap { byQueue[$0] }
    }
}

/// The last counts, kept in UserDefaults for the 0 -> >0 rule. Counts only: no names, no ids, nothing else.
public struct OperationsCountStore: Sendable {
    public static let key = "LCCOperationsLastCounts"
    private let defaults: @Sendable () -> UserDefaults

    public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) { self.defaults = defaults }

    public func load() -> [OperationsCount] {
        guard let data = defaults().data(forKey: Self.key) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([OperationsCount].self, from: data)) ?? []
    }

    public func save(_ counts: [OperationsCount]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(counts) { defaults().set(data, forKey: Self.key) }
    }

    /// Records the fresh counts and returns the queues that just went from 0 to more than 0.
    @discardableResult
    public func record(_ fresh: [OperationsCount]) -> [OperationsCount] {
        let previous = load()
        let changed = OperationsTransitions.newlyWaiting(previous: previous, current: fresh)
        save(OperationsTransitions.merge(previous, with: fresh))
        return changed
    }

    /// Forgets one product's counts (on sign-out), so the next sign-in starts fresh.
    public func forget(_ product: OperationsProduct) {
        save(load().filter { $0.queue.product != product })
    }
}

// MARK: - Local action log

/// Linumic OS's own record of an operations write it sent (today only Talar's hall approve/reject): who, where,
/// what, the outcome. The product keeps its own audit trail too; this is the owner's copy on this device.
public struct OperationsActionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Accepted, and a fresh read no longer lists the item in the queue.
        case verified
        /// Accepted, but the re-read failed or still lists it.
        case unverified
        /// Refused, or it never arrived.
        case failed
    }

    public var id: UUID
    public var at: Date
    public var product: OperationsProduct
    public var environment: String
    public var actor: String
    /// e.g. `hall.review_approve`, the name the product's own audit log uses.
    public var action: String
    public var targetID: String
    public var targetName: String
    public var detail: String?
    public var outcome: Outcome
    public var message: String?

    public init(id: UUID = UUID(), at: Date, product: OperationsProduct, environment: String, actor: String, action: String,
                targetID: String, targetName: String, detail: String?, outcome: Outcome, message: String?) {
        self.id = id
        self.at = at
        self.product = product
        self.environment = environment
        self.actor = actor
        self.action = action
        self.targetID = targetID
        self.targetName = targetName
        self.detail = detail
        self.outcome = outcome
        self.message = message
    }
}

/// Append-only JSON file next to `inventory.json` (`operations-actions.json`). Entries are never removed.
public actor OperationsActionLog {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "operations-actions.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first. A missing file is an empty log.
    public func load() throws -> [OperationsActionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try Self.decoder.decode([OperationsActionRecord].self, from: Data(contentsOf: fileURL)).sorted { $0.at > $1.at }
    }

    public func append(_ record: OperationsActionRecord) throws {
        var all = try load()
        all.append(record)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(all.sorted { $0.at < $1.at }).write(to: fileURL, options: .atomic)
    }
}
