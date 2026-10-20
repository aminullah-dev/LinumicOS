import Foundation
import Testing
@testable import LinumicCore

// Proof that the Products and Agents pages only read: the real GitHub client runs over a real URLSession whose only
// protocol is the recorder below, so every request the network layer would send is seen here and answered from recorded
// fixtures (or 404). Nothing leaves the process. A whole refresh (`ProductsSync.refresh`) runs through it.

final class ProductsGuardProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let url: URL
        let body: String
        let authorization: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock {
            Self._seen.append(Seen(method: request.httpMethod ?? "GET", url: url, body: MoneyGuardProtocol.body(of: request),
                                   authorization: request.value(forHTTPHeaderField: "Authorization")))
        }
        func file(_ name: String) -> Data {
            (Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")).flatMap { try? Data(contentsOf: $0) } ?? Data()
        }
        let (status, data): (Int, Data) = {
            switch url.path {
            case "/repos/aminullah-dev/LinumicOS": return (200, file("products-repo-linumicos"))
            case "/repos/aminullah-dev/LinumicOS/commits": return (200, file("products-commits-linumicos"))
            case "/repos/aminullah-dev/LinumicOS/pulls":
                // The open-count read of the release tracking, and the agents' page of every state.
                return (200, url.query?.contains("state=all") == true ? file("products-pulls-linumicos") : Data("[]".utf8))
            case "/repos/aminullah-dev/talar/pulls": return (200, file("products-pulls-talar"))
            default: return (404, Data(#"{"message":"Not Found"}"#.utf8))
            }
        }()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What the two pages may send: GETs to api.github.com, under /repos/<owner>/<name>, on these paths only.
enum ProductsReadPolicy {
    static var allowed: [Regex<Substring>] { [
        #/\/repos\/[^\/]+\/[^\/]+/#,
        #/\/repos\/[^\/]+\/[^\/]+\/commits/#,
        #/\/repos\/[^\/]+\/[^\/]+\/pulls/#,
        #/\/repos\/[^\/]+\/[^\/]+\/releases(?:\/latest)?/#,
        #/\/repos\/[^\/]+\/[^\/]+\/actions\/workflows(?:\/\d+\/runs)?/#,
        #/\/repos\/[^\/]+\/[^\/]+\/contents\/project\.yml/#,
    ] }

    static func violations(_ seen: [ProductsGuardProtocol.Seen]) -> [String] {
        var bad: [String] = []
        for r in seen {
            let what = "\(r.method) \(r.url.absoluteString)"
            if r.method != "GET" { bad.append("not a GET: \(what)") }
            if !r.body.isEmpty { bad.append("a body: \(what)") }
            if r.url.host != "api.github.com" || r.url.scheme != "https" { bad.append("not GitHub's API: \(what)") }
            if !allowed.contains(where: { r.url.path.wholeMatch(of: $0) != nil }) { bad.append("not a read of these pages: \(what)") }
            if r.authorization != "Bearer test-token" { bad.append("not the existing token: \(what)") }
        }
        return bad
    }
}

@Suite("Products and Agents only read", .serialized)
struct ProductsReadOnlyTests {
    private func client() -> GitHubClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ProductsGuardProtocol.self]
        c.urlCache = nil
        return GitHubClient(token: "test-token", transport: URLSessionTransport(session: URLSession(configuration: c)),
                            now: { ISO8601DateFormatter().date(from: "2026-10-20T15:00:00Z")! })
    }

    @Test func everyRequestOfAFullRefreshIsAGitHubGET() async throws {
        ProductsGuardProtocol.reset()
        let products = try SeedInventory.load().products
        let (file, report) = await ProductsSync.refresh(products: products, file: ProductsFile(), using: client())
        let seen = ProductsGuardProtocol.seen
        #expect(!seen.isEmpty)
        #expect(ProductsReadPolicy.violations(seen) == [])

        // The commits page: the default branch, 100 at a time; only the dates and the newest sha are kept.
        let commits = try #require(seen.first { $0.url.path == "/repos/aminullah-dev/LinumicOS/commits" })
        #expect(commits.url.query == "sha=main&per_page=100")
        let history = try #require(file.history.first { $0.repo == "aminullah-dev/LinumicOS" })
        #expect(history.commitDates.count == 100 && !history.isComplete && history.branch == "main")
        #expect(history.newestSHA == "cd8c72bc7cd8f922431cf49791eb3b44d3232d06")
        #expect(history.newest == ISO8601DateFormatter().date(from: "2026-10-20T10:50:43Z"))

        // The agents' page: every state, newest first, 50.
        let pulls = try #require(seen.first { $0.url.path == "/repos/aminullah-dev/talar/pulls" })
        #expect(pulls.url.query == "state=all&sort=created&direction=desc&per_page=50")
        #expect(file.pullWindows.first { $0.repo == "aminullah-dev/talar" }?.pulls.map(\.number) == [7, 6])
        #expect(file.pullWindows.first { $0.repo == "aminullah-dev/LinumicOS" }?.pulls.map(\.number) == [30])

        // Repositories the fixtures don't answer failed and are said to have failed, never read as empty.
        #expect(report.failed["aminullah-dev/velro"] != nil)
        #expect(file.historyErrors["aminullah-dev/velro"] != nil)
        #expect(!file.pullWindows.contains { $0.repo == "aminullah-dev/velro" })
        #expect(file.extraTracking.first?.slug == "aminullah-dev/LinumicOS")
    }

    @Test func aFailedRepositoryKeepsItsLastReading() async throws {
        ProductsGuardProtocol.reset()
        let old = RepoPullWindow(repo: "aminullah-dev/velro", pulls: [], pageCount: 4, oldestCreatedAt: nil, isComplete: true,
                                 readAt: ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!)
        let (file, _) = await ProductsSync.refresh(products: try SeedInventory.load().products, file: ProductsFile(pullWindows: [old]), using: client())
        let kept = try #require(file.pullWindows.first { $0.repo == "aminullah-dev/velro" })
        #expect(kept.readAt == old.readAt && kept.error != nil)
        #expect(ProductsReadPolicy.violations(ProductsGuardProtocol.seen) == [])
    }

    @Test func theGuardCatchesWritesAndOtherHosts() {
        func seen(_ method: String, _ url: String, body: String = "", auth: String? = "Bearer test-token") -> ProductsGuardProtocol.Seen {
            .init(method: method, url: URL(string: url)!, body: body, authorization: auth)
        }
        let bad = [
            seen("POST", "https://api.github.com/repos/a/b/pulls", body: "{}"),
            seen("PATCH", "https://api.github.com/repos/a/b/pulls/1"),
            seen("PUT", "https://api.github.com/repos/a/b/pulls/1/merge"),
            seen("DELETE", "https://api.github.com/repos/a/b/git/refs/heads/x"),
            seen("GET", "https://api.github.com/repos/a/b/issues"),
            seen("GET", "https://claude.ai/api/routines"),
            seen("GET", "https://api.github.com/repos/a/b/commits", auth: nil),
        ]
        for r in bad { #expect(!ProductsReadPolicy.violations([r]).isEmpty, "\(r.method) \(r.url)") }
        #expect(ProductsReadPolicy.violations([seen("GET", "https://api.github.com/repos/a/b/commits?sha=main&per_page=100")]).isEmpty)
    }
}
