import Foundation
import Testing
@testable import LinumicCore

// Proof that Money only reads: the real clients run over a real URLSession whose only protocol is the recorder below,
// so every request the network layer would send is seen here and answered from fixtures. Nothing leaves the process,
// and the environments are the local emulators (127.0.0.1), so even a request this guard missed could not reach a
// production host.
//
// It covers the Core readers (`WorkTrackMoneyReader`, `SafeBeautyAdminClient.balanceTotals`). The App's
// `WorkTrackModel.refresh` and `SafeBeautyModel.refreshBalances` call exactly these; they are not run here
// (docs/security.md).

/// Records every request that reaches the URL loading system and answers it from the fixtures.
final class MoneyGuardProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let url: URL
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = Self.body(of: request)
        let method = request.httpMethod ?? "GET"
        Self.lock.withLock { Self._seen.append(Seen(method: method, url: url, body: body)) }
        let path = url.path
        let (status, data): (Int, Data) = {
            func file(_ name: String) -> Data {
                (Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")).flatMap { try? Data(contentsOf: $0) } ?? Data()
            }
            if path.hasSuffix("/securetoken.googleapis.com/v1/token") {
                return (200, Data(#"{"id_token":"id-test","refresh_token":"refresh-test","expires_in":"3600","user_id":"uid-test"}"#.utf8))
            }
            if path.hasSuffix("/v1/vendor/revenue") { return (200, file("worktrack-revenue")) }
            if path.hasSuffix("/v1/vendor/crm/accounts") { return (200, file("worktrack-crm-accounts")) }
            if path.hasSuffix("/v1/vendor/crm/invoices") { return (200, file("worktrack-crm-invoices")) }
            if path.hasSuffix(":runAggregationQuery") {
                return (200, file(body.contains("LESS_THAN") ? "safebeauty-balance-owing" : "safebeauty-balance-owed"))
            }
            if path.hasSuffix("/license") { return (200, Data(#"{"data":{}}"#.utf8)) }
            return (404, Data(#"{"code":"NOT_FOUND","detail":"not in the guard's fixtures"}"#.utf8))
        }()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What Money may send. Kept in the tests: the app has no use for it.
enum MoneyReadPolicy {
    static let worktrackPaths: Set<String> = [
        "/demo-worktrack/us-central1/api/v1/vendor/revenue",
        "/demo-worktrack/us-central1/api/v1/vendor/crm/accounts",
        "/demo-worktrack/us-central1/api/v1/vendor/crm/invoices",
    ]

    /// Every request that breaks the rules, described.
    static func violations(_ seen: [MoneyGuardProtocol.Seen]) -> [String] {
        var bad: [String] = []
        for r in seen {
            let path = r.url.path
            let what = "\(r.method) \(r.url.absoluteString)"
            guard r.url.host == "127.0.0.1" else { bad.append("not the local emulator: \(what)"); continue }
            if ["PUT", "PATCH", "DELETE"].contains(r.method) { bad.append("write method: \(what)") }
            for write in [":commit", ":batchWrite", ":write", ":beginTransaction"] where path.contains(write) { bad.append("Firestore write: \(what)") }
            switch r.url.port {
            case 5001:
                if path.contains("/demo-safebeauty/") { bad.append("SafeBeauty callable: \(what)") }
                else if r.method != "GET" || !path.hasPrefix("/demo-worktrack/us-central1/api/v1/vendor/") { bad.append("not a vendor GET: \(what)") }
            case 9099:
                if r.method != "POST" || !path.hasSuffix("/securetoken.googleapis.com/v1/token") { bad.append("not a token refresh: \(what)") }
            case 8080:
                if r.method != "POST" || !path.hasSuffix(":runAggregationQuery") { bad.append("not an aggregation read: \(what)") }
            default:
                bad.append("unexpected port: \(what)")
            }
        }
        return bad
    }
}

@Suite("Money is read-only", .serialized)
struct MoneyReadOnlyTests {
    private func transport() -> URLSessionTransport {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MoneyGuardProtocol.self]
        c.urlCache = nil
        return URLSessionTransport(session: URLSession(configuration: c))
    }

    @Test func moneyReadsAreGETsOrReadOnlyQueries() async throws {
        MoneyGuardProtocol.reset()
        let t = transport()
        let worktrack = WorkTrackVendorClient(environment: .localEmulator, transport: t)
        await worktrack.restore(refreshToken: "r")
        let read = await WorkTrackMoneyReader.read(worktrack)
        #expect(read.revenue.value != nil && read.accounts.value != nil && read.invoices.value?.rows.count == 13)

        let safeBeauty = SafeBeautyAdminClient(environment: .localEmulator, transport: t)
        await safeBeauty.restore(refreshToken: "r")
        let totals = try await safeBeauty.balanceTotals()
        #expect(totals.owedToSalons == 4500 && totals.owedBySalons == 300)

        let seen = MoneyGuardProtocol.seen
        #expect(!seen.isEmpty)
        #expect(MoneyReadPolicy.violations(seen) == [])
        let vendor = Set(seen.filter { $0.url.port == 5001 }.map(\.url.path))
        #expect(vendor == MoneyReadPolicy.worktrackPaths, "exactly the three reads")
        #expect(seen.filter { $0.url.port == 8080 }.count == 2)
        #expect(!seen.contains { $0.url.path.contains("identitytoolkit") }, "a stored session is refreshed, never signed in with a password")
    }

    @Test func theGuardCatchesAWrite() async throws {
        MoneyGuardProtocol.reset()
        let client = WorkTrackVendorClient(environment: .localEmulator, transport: transport())
        await client.restore(refreshToken: "r")
        let write = try WorkTrackRenewal.makeWrite(
            current: WTLicense(plan: .silver, deviceLimit: 30, status: .active, expiresAt: "2026-10-19", enforceDevices: true, enforcePlan: true,
                               employeeLimit: 60, extraFeatures: [], source: "VENDOR"),
            input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), today: "2026-10-09")
        _ = try? await client.putLicense(companyID: "emu_herat", write)
        let violations = MoneyReadPolicy.violations(MoneyGuardProtocol.seen)
        #expect(violations.contains { $0.hasPrefix("write method: PUT") }, "the guard can fail: \(violations)")
        #expect(MoneyReadPolicy.violations([MoneyGuardProtocol.Seen(method: "GET", url: URL(string: "https://worktrack-prod.web.app/v1/vendor/revenue")!, body: "")])
            .first?.hasPrefix("not the local emulator") == true)
        #expect(MoneyReadPolicy.violations([MoneyGuardProtocol.Seen(method: "POST", url: URL(string: "http://127.0.0.1:8080/v1/projects/p/databases/(default)/documents:commit")!, body: "")]).count == 2)
    }

    /// The guard sees only what goes through a transport. Every Core request does: `URLSessionTransport` (in
    /// GitHubClient.swift) is the one place that holds a URLSession, so a client that made a session of its own would
    /// fail here rather than slip past the guard.
    @Test func onlyTheTransportHoldsAURLSession() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the sources were found")
        let patterns = ["URLSession.shared", "URLSession(configuration", ".data(for:", "dataTask(", ".upload(for:", ".download(for:"]
        for file in files where file.lastPathComponent != "GitHubClient.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns { #expect(!text.contains(pattern), "\(file.lastPathComponent): \(pattern)") }
        }
    }
}
