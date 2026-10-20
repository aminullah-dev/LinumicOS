import Foundation

/// Where the Sentinel's results live. Supabase in the app, a stub in tests.
public protocol SentinelRemote: Sendable {
    /// Last round, every target with its window counts, unacknowledged events, newest snapshot.
    func overview(hours: Int) async throws -> SentinelOverview
    /// Newest first, at most `limit` (the server caps it at 500).
    func events(limit: Int, includeAcknowledged: Bool) async throws -> [SentinelEvent]
    /// Marks an event as seen. Idempotent.
    func acknowledge(eventID: Int) async throws
    /// Asks the server for one round now. False when a round was requested in the last 2 minutes.
    func requestRound() async throws -> Bool
}

/// The Sentinel tables on Supabase, through the admin-only RPCs `sentinel_overview`, `sentinel_recent_events`,
/// `ack_sentinel_event` and `request_sentinel_round`. Reads only, apart from acknowledging and asking for a round;
/// the checks themselves are written by the Edge Function, never by the app.
public struct SentinelClient: SentinelRemote {
    private let config: SupabaseConfig
    private let transport: HTTPTransport
    private let token: @Sendable () async throws -> String

    public init(config: SupabaseConfig, transport: HTTPTransport = URLSessionTransport(), token: @escaping @Sendable () async throws -> String) {
        self.config = config
        self.transport = transport
        self.token = token
    }

    private func rpc(_ name: String, body: [String: Any] = [:]) async throws -> Data {
        var request = URLRequest(url: config.url.appending(path: "rest/v1/rpc/\(name)"))
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SupabaseREST.error(from: data, status: response.statusCode) }
        return data
    }

    public func overview(hours: Int = 24) async throws -> SentinelOverview {
        try InventoryCoding.decoder().decode(SentinelOverview.self, from: await rpc("sentinel_overview", body: ["hours": hours]))
    }

    /// Obligation events are asked for too. A server without the obligation sweep (before 20261019090100) has no such
    /// argument and answers 404; it is then asked as before.
    public func events(limit: Int = 50, includeAcknowledged: Bool = true) async throws -> [SentinelEvent] {
        let data: Data
        do {
            data = try await rpc("sentinel_recent_events", body: ["max_rows": limit, "include_acknowledged": includeAcknowledged,
                                                                  "include_obligations": true])
        } catch SupabaseError.server(let status, _) where status == 404 {
            data = try await rpc("sentinel_recent_events", body: ["max_rows": limit, "include_acknowledged": includeAcknowledged])
        }
        return try InventoryCoding.decoder().decode([SentinelEvent].self, from: data)
    }

    public func acknowledge(eventID: Int) async throws {
        _ = try await rpc("ack_sentinel_event", body: ["event_id": eventID])
    }

    public func requestRound() async throws -> Bool {
        let data = try await rpc("request_sentinel_round")
        return try JSONDecoder().decode(Bool.self, from: data)
    }
}
