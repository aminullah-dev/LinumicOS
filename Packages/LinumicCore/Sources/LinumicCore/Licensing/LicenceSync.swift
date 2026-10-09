import Foundation

/// The ledger as stored on this device: an offline cache that works without the server.
public struct LicenceLedgerFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var records: [LicenceRecord]
    /// Set when a local change hasn't reached the server yet.
    public var needsUpload: Bool
    public var lastSyncedAt: Date?

    public init(records: [LicenceRecord] = [], needsUpload: Bool = false, lastSyncedAt: Date? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
        self.needsUpload = needsUpload
        self.lastSyncedAt = lastSyncedAt
    }
}

/// Reads and writes `licences.json` next to the inventory, atomically.
public actor LicenceLedgerStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/LinumicCommandCenter/licences.json` (inside the sandbox container).
    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "licences.json")
    }

    public func load() throws -> LicenceLedgerFile {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return LicenceLedgerFile() }
        let file = try InventoryCoding.decoder().decode(LicenceLedgerFile.self, from: Data(contentsOf: fileURL))
        guard file.schemaVersion <= LicenceLedgerFile.currentSchemaVersion else {
            throw InventoryStoreError.unsupportedSchemaVersion(file.schemaVersion)
        }
        return file
    }

    public func save(_ file: LicenceLedgerFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(file).write(to: fileURL, options: [.atomic])
    }
}

/// Where the shared ledger lives. Supabase in the app, a stub in tests.
public protocol LicenceRemote: Sendable {
    func fetchAll() async throws -> [LicenceRecord]
    /// Inserts new licences and merges changes into existing ones. Never deletes.
    func upsert(_ records: [LicenceRecord]) async throws
}

/// The `licences` table on Supabase, through the admin-only `export_licences` / `upsert_licences` RPCs.
public struct SupabaseLicenceRemote: LicenceRemote {
    private let config: SupabaseConfig
    private let transport: HTTPTransport
    private let token: @Sendable () async throws -> String

    public init(config: SupabaseConfig, transport: HTTPTransport = URLSessionTransport(), token: @escaping @Sendable () async throws -> String) {
        self.config = config
        self.transport = transport
        self.token = token
    }

    private func rpc(_ name: String, body: Data) async throws -> Data {
        var request = URLRequest(url: config.url.appending(path: "rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SupabaseREST.error(from: data, status: response.statusCode) }
        return data
    }

    public func fetchAll() async throws -> [LicenceRecord] {
        let data = try await rpc("export_licences", body: Data("{}".utf8))
        return try InventoryCoding.decoder().decode([LicenceRecord].self, from: data)
    }

    public func upsert(_ records: [LicenceRecord]) async throws {
        guard !records.isEmpty else { return }
        var body = Data(#"{"rows":"#.utf8)
        body.append(try InventoryCoding.encoder().encode(records))
        body.append(Data("}".utf8))
        _ = try await rpc("upsert_licences", body: body)
    }
}

/// Two-way sync of the ledger. Unlike the inventory (last writer wins), licences are merged
/// record by record and nothing is ever deleted, so two devices can't erase each other's licences.
public enum LicenceSync {
    public struct Result: Sendable, Equatable {
        public let records: [LicenceRecord]
        public let uploaded: Int
        public let conflicts: [LicenceLedger.Conflict]
    }

    public static func sync(local: [LicenceRecord], remote: LicenceRemote) async throws -> Result {
        let server = try await remote.fetchAll()
        let merged = LicenceLedger.merge(local, server)
        let toSend = LicenceLedger.changes(merged.records, comparedTo: server)
        guard !toSend.isEmpty else { return Result(records: merged.records, uploaded: 0, conflicts: merged.conflicts) }
        try await remote.upsert(toSend)
        // Read back what the server now holds; its merge rules match ours.
        let after = try await remote.fetchAll()
        let final = LicenceLedger.merge(merged.records, after)
        return Result(records: final.records, uploaded: toSend.count, conflicts: merged.conflicts + final.conflicts)
    }
}
