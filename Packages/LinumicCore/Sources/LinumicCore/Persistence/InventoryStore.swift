import Foundation

/// Loads and saves the inventory. The local JSON store is the MVP implementation.
/// A remote (backend API) store will conform to the same protocol later.
public protocol InventoryStore: Sendable {
    /// Returns the stored inventory, or `nil` if nothing has been stored yet.
    func load() async throws -> Inventory?
    func save(_ inventory: Inventory) async throws
    /// Moves the stored inventory aside (e.g. before replacing an outdated schema) and returns where it went.
    func archive() async throws -> URL?
}

public enum InventoryStoreError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    /// The file predates the current schema. There is no automatic migration, so the caller archives it.
    case outdatedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let v):
            "The inventory file uses schema version \(v), which this version of the app does not support."
        case .outdatedSchemaVersion(let v):
            "The inventory file uses the older schema version \(v)."
        }
    }
}

public enum InventoryCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct VersionProbe: Decodable { var schemaVersion: Int }

    /// Checks the schema version before decoding, so an old file is reported as outdated and not as corrupt.
    public static func decode(_ data: Data) throws -> Inventory {
        let version = try decoder().decode(VersionProbe.self, from: data).schemaVersion
        if version > Inventory.currentSchemaVersion { throw InventoryStoreError.unsupportedSchemaVersion(version) }
        if version < Inventory.currentSchemaVersion { throw InventoryStoreError.outdatedSchemaVersion(version) }
        return try decoder().decode(Inventory.self, from: data)
    }
}

/// Stores the inventory as a single JSON file, written atomically.
public actor JSONFileInventoryStore: InventoryStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/LinumicCommandCenter/inventory.json` (inside the sandbox container when sandboxed).
    public static func defaultFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "LinumicCommandCenter", directoryHint: .isDirectory)
            .appending(path: "inventory.json", directoryHint: .notDirectory)
    }

    public func load() async throws -> Inventory? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        return try InventoryCoding.decode(Data(contentsOf: fileURL))
    }

    public func save(_ inventory: Inventory) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(inventory).write(to: fileURL, options: [.atomic])
    }

    /// Renames the current file to `inventory-archived-<timestamp>.json` next to it. Nothing is deleted.
    public func archive() async throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let target = fileURL.deletingLastPathComponent().appending(path: "inventory-archived-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }
}

/// Keeps the inventory in memory. Used by tests and SwiftUI previews.
public actor InMemoryInventoryStore: InventoryStore {
    private var inventory: Inventory?

    public init(_ inventory: Inventory? = nil) {
        self.inventory = inventory
    }

    public func load() async throws -> Inventory? { inventory }
    public func save(_ inventory: Inventory) async throws { self.inventory = inventory }
    public func archive() async throws -> URL? {
        inventory = nil
        return nil
    }
}

/// The bundled seed inventory, which contains verified facts only (see docs/product-inventory.md).
public enum SeedInventory {
    public static func load() throws -> Inventory {
        guard let url = Bundle.module.url(forResource: "seed-inventory", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try InventoryCoding.decode(Data(contentsOf: url))
    }
}
