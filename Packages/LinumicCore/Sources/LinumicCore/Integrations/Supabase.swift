import CryptoKit
import Foundation

// Minimal Supabase client for Linumic OS: native Sign in with Apple (GoTrue id_token
// grant), session refresh, and the two inventory RPCs. No third-party dependency.
// Only the *publishable* key is used here. The service-role key never belongs in the app.

public struct SupabaseConfig: Sendable, Equatable {
    public var url: URL
    public var publishableKey: String

    public init(url: URL, publishableKey: String) {
        self.url = url
        self.publishableKey = publishableKey
    }
}

public struct SupabaseSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

public enum SupabaseError: Error, LocalizedError, Equatable {
    case notSignedIn
    case notAuthorized
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: L("Not signed in.")
        case .notAuthorized: L("Signed in, but this account doesn't have admin access to Linumic OS yet.")
        case .server(let status, let message): LF("Server error %ld: %@", status, message)
        }
    }
}

/// Nonce helpers for Sign in with Apple. Apple gets the SHA-256 hash and Supabase gets the raw value.
public enum AppleSignInNonce {
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    public static func sha256(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds the signed-in session, persists it in the Keychain, and refreshes it before it expires.
public actor SupabaseSessionManager {
    private let config: SupabaseConfig
    private let transport: HTTPTransport
    private let secrets: SecretStore
    private let now: @Sendable () -> Date
    private var session: SupabaseSession?

    public init(config: SupabaseConfig, secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.config = config
        self.transport = transport
        self.secrets = secrets
        self.now = now
        if let stored = try? secrets.read(.supabaseSession), let data = stored.data(using: .utf8) {
            session = try? JSONDecoder.supabase.decode(SupabaseSession.self, from: data)
        }
    }

    public var current: SupabaseSession? { session }

    /// Exchanges Apple's identity token (and the raw nonce whose hash was sent to Apple) for a Supabase session.
    @discardableResult
    public func signInWithApple(idToken: String, rawNonce: String?) async throws -> SupabaseSession {
        var body: [String: String] = ["provider": "apple", "id_token": idToken]
        if let rawNonce { body["nonce"] = rawNonce }
        let s = try await tokenRequest(grant: "id_token", body: body)
        try store(s)
        return s
    }

    /// A valid access token, refreshed if it expires within a minute.
    public func accessToken() async throws -> String {
        guard let s = session else { throw SupabaseError.notSignedIn }
        if s.expiresAt.timeIntervalSince(now()) > 60 { return s.accessToken }
        let refreshed = try await tokenRequest(grant: "refresh_token", body: ["refresh_token": s.refreshToken])
        try store(refreshed)
        return refreshed.accessToken
    }

    public func signOut() async {
        if let s = session {
            var request = URLRequest(url: config.url.appending(path: "auth/v1/logout"))
            request.httpMethod = "POST"
            request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await transport.send(request)  // Best effort. The local session is removed either way.
        }
        session = nil
        try? secrets.delete(.supabaseSession)
    }

    private func store(_ s: SupabaseSession) throws {
        session = s
        let data = try JSONEncoder.supabase.encode(s)
        try secrets.write(String(decoding: data, as: UTF8.self), for: .supabaseSession)
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
        let expires_at: Double?
        let user: User
    }

    private func tokenRequest(grant: String, body: [String: String]) async throws -> SupabaseSession {
        var components = URLComponents(url: config.url.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw SupabaseREST.error(from: data, status: response.statusCode) }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = t.expires_at.map(Date.init(timeIntervalSince1970:)) ?? now().addingTimeInterval(t.expires_in ?? 3600)
        return SupabaseSession(accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: expiry, userID: t.user.id, email: t.user.email)
    }
}

enum SupabaseREST {
    private struct ErrorBody: Decodable {
        let message: String?
        let msg: String?
        let error_description: String?
        let code: String?
    }

    static func error(from data: Data, status: Int) -> SupabaseError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        if status == 401 || status == 403 || body?.code == "42501" { return .notAuthorized }
        let message = body?.message ?? body?.msg ?? body?.error_description ?? String(decoding: data.prefix(200), as: UTF8.self)
        return .server(status: status, message: message)
    }
}

/// The inventory on the Supabase backend, read and written through the export/import RPCs.
public actor RemoteInventoryStore: InventoryStore {
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

    /// Returns nil when the server holds no data yet, so the caller can upload its local inventory.
    public func load() async throws -> Inventory? {
        let inventory = try InventoryCoding.decode(try await rpc("export_inventory", body: Data("{}".utf8)))
        return inventory.products.isEmpty && inventory.unresolved.isEmpty ? nil : inventory
    }

    public func save(_ inventory: Inventory) async throws {
        var body = Data(#"{"doc":"#.utf8)
        body.append(try InventoryCoding.encoder().encode(inventory))
        body.append(Data("}".utf8))
        _ = try await rpc("import_inventory", body: body)
    }

    /// The server keeps an audit log instead of archive files.
    public func archive() async throws -> URL? { nil }
}

/// Cloud inventory with the local file as an offline cache.
///
/// - load: the server wins when reachable. If it's empty, the local inventory is uploaded. If an earlier
///   upload failed (the pending flag), local edits are pushed first so they aren't lost.
/// - save: always written locally, then uploaded. A failed upload leaves the pending flag for next time.
/// Concurrent edits on two devices resolve as last-writer-wins for the whole inventory (single-owner use).
public actor HybridInventoryStore: InventoryStore {
    public enum Status: Sendable, Equatable {
        case synced(Date)
        case offline(String)
        case pendingUpload(String)
    }

    private let local: InventoryStore
    private let remote: InventoryStore
    private let pendingFlag: URL
    private let now: @Sendable () -> Date
    public private(set) var status: Status?

    public init(local: InventoryStore, remote: InventoryStore, pendingFlag: URL, now: @escaping @Sendable () -> Date = { .now }) {
        self.local = local
        self.remote = remote
        self.pendingFlag = pendingFlag
        self.now = now
    }

    private var hasPendingUpload: Bool { FileManager.default.fileExists(atPath: pendingFlag.path(percentEncoded: false)) }

    private func setPending(_ pending: Bool) {
        if pending {
            try? FileManager.default.createDirectory(at: pendingFlag.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: pendingFlag.path(percentEncoded: false), contents: Data())
        } else {
            try? FileManager.default.removeItem(at: pendingFlag)
        }
    }

    public func load() async throws -> Inventory? {
        let localInventory = try await local.load()
        do {
            if hasPendingUpload, let localInventory {
                try await remote.save(localInventory)
                setPending(false)
                status = .synced(now())
                return localInventory
            }
            if let remoteInventory = try await remote.load() {
                try await local.save(remoteInventory)
                status = .synced(now())
                return remoteInventory
            }
            if let localInventory {
                try await remote.save(localInventory)  // First connection: the server starts with our data.
            }
            status = .synced(now())
            return localInventory
        } catch {
            status = .offline(error.localizedDescription)
            return localInventory
        }
    }

    public func save(_ inventory: Inventory) async throws {
        try await local.save(inventory)
        do {
            try await remote.save(inventory)
            setPending(false)
            status = .synced(now())
        } catch {
            setPending(true)
            status = .pendingUpload(error.localizedDescription)
        }
    }

    public func archive() async throws -> URL? { try await local.archive() }
}

extension JSONEncoder {
    static var supabase: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var supabase: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
