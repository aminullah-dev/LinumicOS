import Foundation

/// Where the synced Desk lives. Supabase in the app, a stub in tests.
public protocol DeskCloudRemote: Sendable {
    /// Every synced row and the Mac's last ledger reading.
    func pull() async throws -> DeskCloudPull
    /// Each change is written only if its row is still at `expectedVersion`; otherwise the row as it is comes back.
    func pushMarks(_ changes: [CloudChange<DeskMark>], device: CloudDevice) async throws -> [CloudPushResult<DeskMark>]
    func pushObligations(_ changes: [CloudChange<ObligationCloudPayload>], device: CloudDevice) async throws
        -> [CloudPushResult<ObligationCloudPayload>]
    func pushVendors(_ changes: [CloudChange<VendorCloudPayload>], device: CloudDevice) async throws -> [CloudPushResult<VendorCloudPayload>]
    /// Replaces the ledger reading of version `expectedVersion` (0: none yet).
    func replaceLedger(expectedVersion: Int64, reading: CloudLedgerUpload) async throws -> CloudLedgerPushResult
}

/// The Desk sync tables on Supabase, through the admin-only RPCs `desk_sync_pull`, `push_desk_state`,
/// `push_obligations`, `push_vendors` and `replace_desk_items` (supabase/migrations/20261019090000_desk_sync.sql).
public struct SupabaseDeskCloud: DeskCloudRemote {
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

    private struct PushBody<P: CloudPayload>: Encodable {
        let changes: [CloudChange<P>]
        let device: CloudDevice
    }

    private func push<P: CloudPayload>(_ name: String, _ changes: [CloudChange<P>], device: CloudDevice) async throws -> [CloudPushResult<P>] {
        guard !changes.isEmpty else { return [] }
        let body = try InventoryCoding.encoder().encode(PushBody(changes: changes, device: device))
        return try InventoryCoding.decoder().decode([CloudPushResult<P>].self, from: await rpc(name, body: body))
    }

    public func pull() async throws -> DeskCloudPull {
        try InventoryCoding.decoder().decode(DeskCloudPull.self, from: await rpc("desk_sync_pull", body: Data("{}".utf8)))
    }

    public func pushMarks(_ changes: [CloudChange<DeskMark>], device: CloudDevice) async throws -> [CloudPushResult<DeskMark>] {
        try await push("push_desk_state", changes, device: device)
    }

    public func pushObligations(_ changes: [CloudChange<ObligationCloudPayload>], device: CloudDevice) async throws
        -> [CloudPushResult<ObligationCloudPayload>] {
        try await push("push_obligations", changes, device: device)
    }

    public func pushVendors(_ changes: [CloudChange<VendorCloudPayload>], device: CloudDevice) async throws
        -> [CloudPushResult<VendorCloudPayload>] {
        try await push("push_vendors", changes, device: device)
    }

    private struct LedgerBody: Encodable {
        let expected_version: Int64
        let reading: CloudLedgerUpload
    }

    public func replaceLedger(expectedVersion: Int64, reading: CloudLedgerUpload) async throws -> CloudLedgerPushResult {
        let body = try InventoryCoding.encoder().encode(LedgerBody(expected_version: expectedVersion, reading: reading))
        return try InventoryCoding.decoder().decode(CloudLedgerPushResult.self, from: await rpc("replace_desk_items", body: body))
    }
}
