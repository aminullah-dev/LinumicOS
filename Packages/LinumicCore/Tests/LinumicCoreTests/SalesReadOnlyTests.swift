import Foundation
import Testing
@testable import LinumicCore

// Proof that Sales only reads: the real client runs over a real URLSession whose only protocol is the recorder below, so
// every request the network layer would send is seen here and answered from fixtures. Nothing leaves the process, and
// the environment is the local emulator (127.0.0.1), so even a request this guard missed could not reach a real host.
//
// It covers what Sales asks WorkTrack for: Money's reading, which Sales is built from (`WorkTrackMoneyReader.read`), and
// the two reads made only when the owner asks (`crmContacts(accountId:)`, `crmAccountsShape()`). The App's
// `WorkTrackModel.contacts(forAccount:)` and `checkCRMShape()` call exactly these; they are not run here (docs/security.md).
// The recorder keeps its own list: suites run in parallel, and Money's guard is serialized only within its own suite.

final class SalesGuardProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [MoneyGuardProtocol.Seen] = []
    static var seen: [MoneyGuardProtocol.Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = MoneyGuardProtocol.body(of: request)
        Self.lock.withLock { Self._seen.append(MoneyGuardProtocol.Seen(method: request.httpMethod ?? "GET", url: url, body: body)) }
        let path = url.path
        let (status, data): (Int, Data) = {
            func file(_ name: String) -> Data {
                (Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")).flatMap { try? Data(contentsOf: $0) } ?? Data()
            }
            if path.hasSuffix("/securetoken.googleapis.com/v1/token") {
                return (200, Data(#"{"id_token":"id-test","refresh_token":"refresh-test","expires_in":"3600","user_id":"uid-test"}"#.utf8))
            }
            if path.hasSuffix("/v1/vendor/revenue") { return (200, file("worktrack-revenue")) }
            if path.hasSuffix("/v1/vendor/crm/accounts") { return (200, file("worktrack-crm-accounts-sales")) }
            if path.hasSuffix("/v1/vendor/crm/invoices") { return (200, file("worktrack-crm-invoices")) }
            if path.hasSuffix("/v1/vendor/crm/contacts") { return (200, file("worktrack-crm-contacts")) }
            if path.hasSuffix("/license") { return (200, Data(#"{"data":{}}"#.utf8)) }
            return (404, Data(#"{"code":"NOT_FOUND","detail":"not in the guard's fixtures"}"#.utf8))
        }()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What Sales may send. Kept in the tests: the app has no use for it.
enum SalesReadPolicy {
    static let base = "/demo-worktrack/us-central1/api/v1/vendor/"
    static let paths: Set<String> = Set(["revenue", "crm/accounts", "crm/invoices", "crm/contacts"].map { base + $0 })

    /// Every request that breaks the rules, described.
    static func violations(_ seen: [MoneyGuardProtocol.Seen], contactsQuery: String) -> [String] {
        var bad: [String] = []
        for r in seen {
            let what = "\(r.method) \(r.url.absoluteString)"
            let parts = URLComponents(url: r.url, resolvingAgainstBaseURL: false)
            let query = parts?.percentEncodedQuery
            guard r.url.host == "127.0.0.1" else { bad.append("not the local emulator: \(what)"); continue }
            switch r.url.port {
            case 5001:
                if r.method != "GET" { bad.append("not a GET: \(what)") }
                if !r.body.isEmpty { bad.append("a body: \(what)") }
                if !paths.contains(r.url.path) { bad.append("not a Sales read: \(what)") }
                if r.url.path == base + "crm/contacts" {
                    // Without an account the server answers every contact of every account.
                    if query != contactsQuery { bad.append("contacts without exactly one account: \(what)") }
                } else if query != nil {
                    bad.append("a query: \(what)")
                }
            case 9099:
                if r.method != "POST" || !r.url.path.hasSuffix("/securetoken.googleapis.com/v1/token") { bad.append("not a token refresh: \(what)") }
            default:
                bad.append("unexpected port: \(what)")
            }
            if r.url.path.contains("identitytoolkit") { bad.append("a password sign-in: \(what)") }
        }
        return bad
    }
}

@Suite("Sales is read-only", .serialized)
struct SalesReadOnlyTests {
    private func client() async -> WorkTrackVendorClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SalesGuardProtocol.self]
        c.urlCache = nil
        let client = WorkTrackVendorClient(environment: .localEmulator, transport: URLSessionTransport(session: URLSession(configuration: c)))
        await client.restore(refreshToken: "r")
        return client
    }

    @Test func everyWorkTrackRequestIsAGETWithoutABody() async throws {
        SalesGuardProtocol.reset()
        let client = await client()
        let read = await WorkTrackMoneyReader.read(client)
        #expect(read.accounts.value?.rows.count == 21)
        let contacts = try await client.crmContacts(accountId: " acc_lead_today ")
        #expect(contacts.rows.map(\.id) == ["con_1", "con_2"] && contacts.rows.first?.phone == "+93 700 000 001")
        #expect(contacts.skipped == 1, "a contact of another account is dropped, and counted")
        #expect(contacts.rows.map(\.primary) == [true, false], "no primary field: false, as the server's default")
        for never in ["sample@example.invalid", "SENTINEL-CONTACT-NOTES", "acc_other"] {
            #expect(!String(describing: contacts).contains(never), "\(never) is never held")
        }
        let shape = try await client.crmAccountsShape()
        #expect(shape.rows == 21 && shape.unexpectedKeys == ["legacyPhone"])

        let seen = SalesGuardProtocol.seen
        #expect(SalesReadPolicy.violations(seen, contactsQuery: "accountId=acc_lead_today") == [])
        #expect(Set(seen.filter { $0.url.port == 5001 }.map(\.url.path)) == SalesReadPolicy.paths, "exactly the four reads")
        #expect(seen.filter { $0.url.path.hasSuffix("/crm/accounts") }.count == 2, "Money's reading and the one shape check")
        #expect(seen.filter { $0.url.port == 9099 }.count == 1, "the token refresh, once")
    }

    @Test func noAccountMeansNoRequest() async throws {
        SalesGuardProtocol.reset()
        let client = await client()
        await #expect(throws: WorkTrackError.self) { _ = try await client.crmContacts(accountId: "  ") }
        #expect(SalesGuardProtocol.seen.isEmpty, "refused before any request, the token refresh included")
    }

    @Test func theQueryCannotBeBent() {
        let base = URL(string: "http://127.0.0.1:5001/demo-worktrack/us-central1/api/v1")!
        let url = WorkTrackVendorClient.url(base, ["vendor", "crm", "contacts"], query: [URLQueryItem(name: "accountId", value: "a+b&c=d/e é")])
        #expect(url.query(percentEncoded: true) == "accountId=a%2Bb%26c%3Dd%2Fe%20%C3%A9")
        #expect(WorkTrackVendorClient.url(base, ["vendor", "crm", "accounts"]).query == nil)
    }

    @Test func theGuardCatchesEveryWrite() async throws {
        func seen(_ method: String, _ url: String, body: String = "") -> MoneyGuardProtocol.Seen {
            MoneyGuardProtocol.Seen(method: method, url: URL(string: url)!, body: body)
        }
        let api = "http://127.0.0.1:5001/demo-worktrack/us-central1/api/v1/vendor/"
        let bad = [
            seen("POST", api + "crm/accounts", body: "{}"), seen("PUT", api + "crm/accounts/x", body: "{}"), seen("DELETE", api + "crm/contacts/x"),
            seen("PATCH", api + "crm/accounts/x"), seen("GET", api + "crm/contacts"), seen("GET", api + "crm/contacts?accountId="),
            seen("GET", api + "crm/dashboard"), seen("GET", "https://worktrack-prod.web.app/v1/vendor/crm/accounts"),
            seen("GET", api + "crm/accounts?accountId=x"),
        ]
        for r in bad { #expect(!SalesReadPolicy.violations([r], contactsQuery: "accountId=acc_lead_today").isEmpty, "\(r.method) \(r.url)") }

        // A real write through the real client is seen too.
        SalesGuardProtocol.reset()
        let client = await client()
        let write = try WorkTrackRenewal.makeWrite(
            current: WTLicense(plan: .silver, deviceLimit: 30, status: .active, expiresAt: "2026-10-19", enforceDevices: true, enforcePlan: true,
                               employeeLimit: 60, extraFeatures: [], source: "VENDOR"),
            input: WTRenewalInput(plan: .silver, deviceLimit: 30, status: .active, expiry: .date("2026-11-19")), today: "2026-10-09")
        _ = try? await client.putLicense(companyID: "emu_herat", write)
        let violations = SalesReadPolicy.violations(SalesGuardProtocol.seen, contactsQuery: "accountId=acc_lead_today")
        #expect(violations.contains { $0.hasPrefix("not a GET: PUT") }, "the guard can fail: \(violations)")
    }

    /// The client names no CRM write: its only non-GET request is the licence PUT, and Sales' protocol has two GETs.
    @Test func theClientHasNoCRMWrite() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LinumicCore/Integrations/WorkTrackVendor.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let sends = text.components(separatedBy: "send(\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
        #expect(sends.sorted() == ["GET", "PUT"], "\(sends)")
        #expect(text.components(separatedBy: "send(\"PUT\", [\"vendor\", \"companies\", companyID, \"license\"]").count == 2)
        #expect(!text.contains("\"POST\"") && !text.contains("\"DELETE\"") && !text.contains("\"PATCH\""))
        let salesProtocol = try #require(text.range(of: "public protocol WorkTrackSalesReading").map { String(text[$0.lowerBound...].prefix { $0 != "}" }) })
        #expect(salesProtocol.components(separatedBy: "func ").count == 3, "two reads, nothing else")
    }
}
