import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only: stubbed Supabase responses, never shown as real data.

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]
    func read(_ key: SecretKey) throws -> String? { lock.withLock { values[key] } }
    func write(_ value: String, for key: SecretKey) throws { lock.withLock { values[key] = value } }
    func delete(_ key: SecretKey) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class Recorder: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let config = SupabaseConfig(url: URL(string: "https://sample.supabase.co")!, publishableKey: "sb_publishable_SAMPLE")
private func token(_ access: String, expiresAt: Double) -> String {
    #"{"access_token":"\#(access)","refresh_token":"r-\#(access)","expires_at":\#(expiresAt),"user":{"id":"user-1","email":"owner@example.com"}}"#
}

@Suite("Supabase auth")
struct SupabaseAuthTests {
    @Test func signInSendsIdTokenAndNonceAndStoresSession() async throws {
        let secrets = MemorySecrets()
        let t = Recorder { _ in (200, token("a1", expiresAt: 2_000_000_000)) }
        let manager = SupabaseSessionManager(config: config, secrets: secrets, transport: t)
        let session = try await manager.signInWithApple(idToken: "apple-jwt", rawNonce: "raw-nonce")
        #expect(session.userID == "user-1")
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString == "https://sample.supabase.co/auth/v1/token?grant_type=id_token")
        #expect(r.value(forHTTPHeaderField: "apikey") == "sb_publishable_SAMPLE")
        let body = try JSONDecoder().decode([String: String].self, from: r.httpBody!)
        #expect(body == ["provider": "apple", "id_token": "apple-jwt", "nonce": "raw-nonce"])
        // Persisted: a new manager on the same Keychain is already signed in.
        let reloaded = SupabaseSessionManager(config: config, secrets: secrets, transport: t)
        #expect(await reloaded.current?.accessToken == "a1")
    }

    @Test func refreshesAnExpiringToken() async throws {
        let secrets = MemorySecrets()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let t = Recorder { req in
            req.url!.query!.contains("refresh_token") ? (200, token("a2", expiresAt: 1_900_003_600)) : (200, token("a1", expiresAt: 1_900_000_030))
        }
        let manager = SupabaseSessionManager(config: config, secrets: secrets, transport: t, now: { now })
        try await manager.signInWithApple(idToken: "x", rawNonce: nil)
        #expect(try await manager.accessToken() == "a2", "a token expiring within a minute is refreshed")
        #expect(t.requests.last?.url?.query == "grant_type=refresh_token")
        #expect(try await manager.accessToken() == "a2")
        #expect(t.requests.count == 2, "a fresh token isn't refreshed again")
    }

    @Test func signOutForgetsTheSession() async throws {
        let secrets = MemorySecrets()
        let manager = SupabaseSessionManager(config: config, secrets: secrets, transport: Recorder { _ in (200, token("a1", expiresAt: 2_000_000_000)) })
        try await manager.signInWithApple(idToken: "x", rawNonce: nil)
        await manager.signOut()
        #expect(await manager.current == nil)
        #expect(try secrets.read(.supabaseSession) == nil)
        await #expect(throws: SupabaseError.notSignedIn) { try await manager.accessToken() }
    }

    @Test func nonceHashIsSHA256Hex() {
        #expect(AppleSignInNonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleSignInNonce.make().count == 64)
    }
}

@Suite("Supabase inventory store")
struct RemoteInventoryStoreTests {
    @Test func exportAndImportUseTheRPCs() async throws {
        let sample = Inventory(products: [Product(id: "s", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: Date(timeIntervalSince1970: 0)))])
        let exported = String(decoding: try InventoryCoding.encoder().encode(sample), as: UTF8.self)
        let t = Recorder { req in req.url!.path.hasSuffix("export_inventory") ? (200, exported) : (200, "") }
        let store = RemoteInventoryStore(config: config, transport: t, token: { "user-jwt" })
        #expect(try await store.load() == sample)
        try await store.save(sample)
        let importRequest = try #require(t.requests.last)
        #expect(importRequest.url?.path == "/rest/v1/rpc/import_inventory")
        #expect(importRequest.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        let body = try JSONSerialization.jsonObject(with: importRequest.httpBody!) as! [String: Any]
        #expect((body["doc"] as? [String: Any])?["schemaVersion"] as? Int == 2)
    }

    @Test func emptyServerLoadsAsNil() async throws {
        let t = Recorder { _ in (200, #"{"schemaVersion":2,"seedRevision":1,"products":[],"unresolved":[],"market":{"sources":[],"evidence":[],"findings":[]},"content":[]}"#) }
        #expect(try await RemoteInventoryStore(config: config, transport: t, token: { "x" }).load() == nil)
    }

    @Test func nonAdminIsReportedAsNotAuthorized() async {
        let t = Recorder { _ in (403, #"{"code":"42501","message":"Not authorised: Linumic Command Center admins only"}"#) }
        await #expect(throws: SupabaseError.notAuthorized) {
            try await RemoteInventoryStore(config: config, transport: t, token: { "x" }).load()
        }
    }
}

@Suite("Hybrid store (cloud + offline cache)")
struct HybridInventoryStoreTests {
    private actor FlakyRemote: InventoryStore {
        var stored: Inventory?
        var failing = false
        func setFailing(_ f: Bool) { failing = f }
        func load() async throws -> Inventory? { if failing { throw URLError(.notConnectedToInternet) }; return stored }
        func save(_ inventory: Inventory) async throws { if failing { throw URLError(.notConnectedToInternet) }; stored = inventory }
        func archive() async throws -> URL? { nil }
    }

    private func sample(_ name: String) -> Inventory {
        Inventory(products: [Product(id: name, name: name, provenance: Provenance(source: "t", recordedAt: Date(timeIntervalSince1970: 0)))])
    }

    @Test func firstConnectionUploadsLocalData() async throws {
        let local = InMemoryInventoryStore(sample("LOCAL"))
        let remote = FlakyRemote()
        let flag = FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())/pending")
        let hybrid = HybridInventoryStore(local: local, remote: remote, pendingFlag: flag)
        #expect(try await hybrid.load() == sample("LOCAL"))
        #expect(await remote.stored == sample("LOCAL"))
    }

    @Test func offlineEditsAreKeptAndPushedBeforeReadingTheServer() async throws {
        let local = InMemoryInventoryStore(sample("A"))
        let remote = FlakyRemote()
        let flag = FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())/pending")
        defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }
        let hybrid = HybridInventoryStore(local: local, remote: remote, pendingFlag: flag)
        _ = try await hybrid.load()                      // uploads A
        await remote.setFailing(true)
        try await hybrid.save(sample("B"))               // offline edit
        #expect(try await local.load() == sample("B"))
        #expect(await remote.stored == sample("A"))
        if case .pendingUpload = await hybrid.status {} else { Issue.record("expected pendingUpload") }

        await remote.setFailing(false)
        let next = HybridInventoryStore(local: local, remote: remote, pendingFlag: flag)  // e.g. next launch
        #expect(try await next.load() == sample("B"), "the offline edit wins over the older server copy")
        #expect(await remote.stored == sample("B"))
    }

    @Test func serverWinsWhenNothingIsPending() async throws {
        let local = InMemoryInventoryStore(sample("OLD"))
        let remote = FlakyRemote()
        try await remote.save(sample("NEW"))
        let hybrid = HybridInventoryStore(local: local, remote: remote, pendingFlag: FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())/pending"))
        #expect(try await hybrid.load() == sample("NEW"))
        #expect(try await local.load() == sample("NEW"), "the local cache is refreshed")
    }

    @Test func offlineLoadFallsBackToTheCache() async throws {
        let remote = FlakyRemote()
        await remote.setFailing(true)
        let hybrid = HybridInventoryStore(local: InMemoryInventoryStore(sample("CACHE")), remote: remote,
                                          pendingFlag: FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())/pending"))
        #expect(try await hybrid.load() == sample("CACHE"))
        if case .offline = await hybrid.status {} else { Issue.record("expected offline") }
    }
}
