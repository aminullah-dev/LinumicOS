import Foundation
import Testing
@testable import LinumicCore

// Recorded response shapes (trimmed) used as TEST FIXTURES only. They are never shown as real data.

private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let routes: [String: (Int, String, [String: String])]

    init(_ routes: [String: (Int, String, [String: String])]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let path = request.url!.path(percentEncoded: false)
        let (status, body, headers) = routes[path] ?? (404, #"{"message":"Not Found"}"#, [:])
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private let repoPath = "/repos/sample-owner/sample-repo"
private func ok(_ body: String) -> (Int, String, [String: String]) { (200, body, [:]) }

private let fixtureRoutes: [String: (Int, String, [String: String])] = [
    repoPath: ok(#"{"name":"sample-repo","full_name":"sample-owner/sample-repo","private":true,"visibility":"private","description":"SAMPLE","homepage":"","default_branch":"main"}"#),
    "\(repoPath)/commits/main": ok(#"{"sha":"abc1234def","commit":{"message":"First line\n\nbody","author":{"name":"A","date":"2026-09-20T10:00:00Z"},"committer":{"name":"A","date":"2026-09-20T11:00:00Z"}}}"#),
    "\(repoPath)/releases": ok(#"[{"tag_name":"v2.0","name":"Draft","published_at":null,"draft":true,"assets":[]},{"tag_name":"v1.0","name":"One","published_at":"2026-09-01T00:00:00Z","draft":false,"assets":[{"name":"app.apk"}]}]"#),
    "\(repoPath)/pulls": ok(#"[{"number":1}]"#),
    "\(repoPath)/issues": ok(#"[{"number":1,"pull_request":{"url":"x","merged_at":null}},{"number":2},{"number":3}]"#),
    "\(repoPath)/languages": ok(#"{"Swift":100,"Kotlin":5000}"#),
    "\(repoPath)/actions/runs": ok(#"{"workflow_runs":[{"status":"completed","conclusion":"success"}]}"#),
]

@Suite("GitHub client (read-only)")
struct GitHubClientTests {
    let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func parsesSnapshot() async throws {
        let transport = StubTransport(fixtureRoutes)
        let snap = try await GitHubClient(token: "t", transport: transport, now: { [fixedNow] in fixedNow }).snapshot(slug: "sample-owner/sample-repo")
        #expect(snap.visibility == .private)
        #expect(snap.homepage == nil)
        #expect(snap.latestCommit?.sha == "abc1234def")
        #expect(snap.latestCommit?.message == "First line")
        #expect(snap.releaseCount == 1, "drafts are excluded")
        #expect(snap.latestRelease?.tag == "v1.0")
        #expect(snap.latestRelease?.assets == ["app.apk"])
        #expect(snap.openPullRequests == 1)
        #expect(snap.openIssues == 2, "pull requests are not counted as issues")
        #expect(snap.languages == ["Kotlin", "Swift"])
        #expect(snap.ciConclusion == .success)
        #expect(snap.fetchedAt == fixedNow)
    }

    @Test func onlyEverSendsAuthenticatedGETs() async throws {
        let transport = StubTransport(fixtureRoutes)
        _ = try await GitHubClient(token: "secret-token", transport: transport).snapshot(slug: "sample-owner/sample-repo")
        #expect(!transport.requests.isEmpty)
        for r in transport.requests {
            #expect(r.httpMethod == "GET")
            #expect(r.httpBody == nil)
            #expect(r.url?.host() == "api.github.com")
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        }
    }

    @Test func noTokenSendsNoAuthorizationHeader() async throws {
        let transport = StubTransport(fixtureRoutes)
        _ = try await GitHubClient(token: "  ", transport: transport).snapshot(slug: "sample-owner/sample-repo")
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func mapsErrors() async {
        let unauthorized = StubTransport([repoPath: (401, "{}", [:])])
        await #expect(throws: GitHubError.unauthorized) {
            try await GitHubClient(token: "t", transport: unauthorized).snapshot(slug: "sample-owner/sample-repo")
        }
        let limited = StubTransport([repoPath: (403, "{}", ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"])])
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_000_000))) {
            try await GitHubClient(token: nil, transport: limited).snapshot(slug: "sample-owner/sample-repo")
        }
        await #expect(throws: GitHubError.notFound("repos/nobody/none")) {
            try await GitHubClient(token: nil, transport: StubTransport([:])).snapshot(slug: "nobody/none")
        }
        await #expect(throws: GitHubError.invalidSlug("not-a-slug")) {
            try await GitHubClient(token: nil, transport: StubTransport([:])).snapshot(slug: "not-a-slug")
        }
    }

    @Test func syncUpdatesSnapshotsOnlyAndReportsFailures() async {
        let link = Verification(status: .partiallyVerified, sources: [Source(kind: .ownerStatement, reference: "test")], verifiedAt: Date(timeIntervalSince1970: 0), notes: "keep me")
        let products = [Product(id: "s", name: "SAMPLE", repositories: [
            RepositoryRecord(name: "sample-repo", url: URL(string: "https://github.com/sample-owner/sample-repo"), type: .monorepo, link: link),
            RepositoryRecord(name: "missing", url: URL(string: "https://github.com/sample-owner/missing"), type: .website),
            RepositoryRecord(name: "local folder", host: .other, type: .marketing),
        ])]
        let client = GitHubClient(token: nil, transport: StubTransport(fixtureRoutes))
        let (updated, report) = await RepositorySync.refresh(products, using: client)
        #expect(report.updated == ["sample-owner/sample-repo"])
        #expect(report.failed.keys.sorted() == ["sample-owner/missing"])
        #expect(report.skipped == ["local folder"])
        let repo = updated[0].repositories[0]
        #expect(repo.gitHub?.latestRelease?.tag == "v1.0")
        #expect(repo.link == link, "a sync never changes verification")
        #expect(repo.type == .monorepo)
    }

    /// Live, read-only check against api.github.com. Runs only when GITHUB_TOKEN is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil))
    func liveReadOnlySnapshot() async throws {
        let slug = ProcessInfo.processInfo.environment["LCC_LIVE_REPO"] ?? "aminullah-dev/DukanPro"
        let snap = try await GitHubClient(token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"]).snapshot(slug: slug)
        #expect(snap.slug.lowercased() == slug.lowercased())
        #expect(snap.latestCommit != nil)
        print("LIVE \(snap.slug): \(snap.visibility?.rawValue ?? "?") branch=\(snap.defaultBranch) commit=\(snap.latestCommit?.sha.prefix(7) ?? "-") releases=\(snap.releaseCount ?? -1) PRs=\(snap.openPullRequests ?? -1) issues=\(snap.openIssues ?? -1) CI=\(snap.ciConclusion?.rawValue ?? "-") langs=\(snap.languages.prefix(3))")
    }
}

// MARK: - App Store public lookup (TEST FIXTURES only)

private final class LookupStub: HTTPTransport, @unchecked Sendable {
    let bodies: [String: String]  // "bundle|country" -> JSON
    init(_ bodies: [String: String]) { self.bodies = bodies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let key = "\(items.first { $0.name == "bundleId" }!.value!)|\(items.first { $0.name == "country" }!.value!)"
        let body = bodies[key] ?? #"{"resultCount":0,"results":[]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("App Store public lookup")
struct AppStoreLookupTests {
    @Test func refreshUpdatesListingAndFallsBackToAfghanStorefront() async {
        let owner = Source(kind: .ownerStatement, reference: "screenshot")
        let products = [Product(id: "s", name: "SAMPLE", storeListings: [
            StoreListing(store: .appStore, appIdentifier: "sample.af.only", verification: Verification(status: .partiallyVerified, sources: [owner], verifiedAt: Date(timeIntervalSince1970: 0))),
            StoreListing(store: .appStore, appIdentifier: "sample.pending"),
            StoreListing(store: .googlePlay, appIdentifier: "sample.android"),
        ])]
        let stub = LookupStub(["sample.af.only|af": #"{"resultCount":1,"results":[{"trackName":"Sample","version":"1.2","currentVersionReleaseDate":"2026-09-20T07:00:00Z","trackViewUrl":"https://apps.apple.com/af/app/sample/id1?uo=4","sellerName":"SAMPLE SELLER"}]}"#])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let (updated, report) = await StoreSync.refreshAppStore(products, using: AppStoreLookupClient(transport: stub), now: now)
        #expect(report.updated == ["sample.af.only"])
        #expect(report.notPublic == ["sample.pending"])
        let l = updated[0].storeListings[0]
        #expect(l.productionVersion == "1.2")
        #expect(l.storefront == "AF")
        #expect(l.url?.absoluteString == "https://apps.apple.com/af/app/sample/id1")
        #expect(l.verification.status == .verified)
        #expect(l.verification.sources.contains(owner), "owner evidence is kept")
        #expect(l.verification.sources.count { $0.kind == .appStore } == 1)
        // A not-public listing is left exactly as it was.
        #expect(updated[0].storeListings[1] == products[0].storeListings[1])
        #expect(updated[0].storeListings[2] == products[0].storeListings[2])
    }

    /// Live check against Apple's public lookup. Runs only when LCC_LIVE_APPSTORE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCC_LIVE_APPSTORE"] == "1"))
    func liveLookup() async throws {
        let client = AppStoreLookupClient()
        for (bundle, country) in [("app.worktrack", "us"), ("com.safebeauty.app", "af"), ("af.velro.ops", "us")] {
            let r = try await client.lookup(bundleID: bundle, country: country)
            print("LIVE \(bundle) [\(country)]: \(r.map { "\($0.trackName) v\($0.version) seller=\($0.seller ?? "-")" } ?? "not public")")
        }
    }
}
