import Foundation
import Testing
@testable import LinumicCore

// Test fixtures only. None of this is presented as real data.

private final class OversightStub: HTTPTransport, @unchecked Sendable {
    let routes: [String: (Int, String)]
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path(percentEncoded: false)
        let (status, body) = routes[path] ?? (404, #"{"message":"Not Found"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

private func snapshot(
    ci: RepositorySnapshot.CIConclusion? = nil,
    dependabot: Int? = nil, secrets: Int? = nil, code: Int? = nil, protected: Bool? = nil,
    prs: Int? = nil, issues: Int? = nil
) -> RepositorySnapshot {
    RepositorySnapshot(
        slug: "o/r", defaultBranch: "main",
        openPullRequests: prs, openIssues: issues, ciConclusion: ci,
        security: .init(dependabotAlerts: dependabot, secretScanningAlerts: secrets,
                        codeScanningAlerts: code, defaultBranchProtected: protected, observedAt: fixedNow),
        fetchedAt: fixedNow
    )
}

@Suite("Oversight health")
struct OversightHealthTests {

    @Test func neverScannedIsUnknownNotHealthy() {
        let repo = OversightRepo(slug: "o/unscanned")
        #expect(repo.health() == .unknown, "a repo with no snapshot must be Unknown, never assumed clean")
    }

    @Test func openSecurityAlertMakesItCritical() {
        let repo = OversightRepo(slug: "o/r", snapshot: snapshot(dependabot: 3, protected: true))
        #expect(repo.health() == .critical)
    }

    @Test func failingCIIsCritical() {
        let repo = OversightRepo(slug: "o/r", snapshot: snapshot(ci: .failure, dependabot: 0, protected: true))
        #expect(repo.health() == .critical)
    }

    @Test func unprotectedDefaultBranchIsAttention() {
        let repo = OversightRepo(slug: "o/r", snapshot: snapshot(ci: .success, dependabot: 0, protected: false))
        #expect(repo.health() == .attention)
    }

    @Test func staleRepoIsAttention() {
        let old = fixedNow.addingTimeInterval(-60 * 24 * 3600) // 60 days before
        let repo = OversightRepo(slug: "o/r", pushedAt: old, snapshot: snapshot(ci: .success, dependabot: 0, protected: true))
        #expect(repo.health(staleAfterDays: 30, asOf: fixedNow) == .attention)
    }

    @Test func cleanRecentScannedRepoIsHealthy() {
        let repo = OversightRepo(slug: "o/r", pushedAt: fixedNow, snapshot: snapshot(ci: .success, dependabot: 0, secrets: 0, protected: true))
        #expect(repo.health(asOf: fixedNow) == .healthy)
    }

    @Test func unreadableSecurityDoesNotFalselyClear() {
        // All alert categories Unknown (nil) + no CI + protection nil → not critical, not attention → healthy
        // but openAlertTotal stays nil so it is never reported as "0 alerts".
        let sec = RepositorySnapshot.Security(observedAt: fixedNow)
        #expect(sec.openAlertTotal == nil)
        #expect(sec.hasOpenAlerts == false)
    }
}

@Suite("Oversight summary")
struct OversightSummaryTests {

    @Test func scoreIsShareOfHealthyAndCountsNeverScannedAgainstIt() {
        let repos = [
            OversightRepo(slug: "o/a", pushedAt: fixedNow, snapshot: snapshot(ci: .success, dependabot: 0, protected: true)), // healthy
            OversightRepo(slug: "o/b", snapshot: snapshot(dependabot: 2, protected: true)),                                    // critical
            OversightRepo(slug: "o/c"),                                                                                        // unknown
            OversightRepo(slug: "o/d", pushedAt: fixedNow, snapshot: snapshot(ci: .success, dependabot: 0, protected: false)), // attention
        ]
        let s = OversightSummary(repos: repos, now: fixedNow)
        #expect(s.totalRepos == 4)
        #expect(s.healthyRepos == 1)
        #expect(s.criticalRepos == 1)
        #expect(s.attentionRepos == 1)
        #expect(s.neverScanned == 1)
        #expect(s.healthScore == 25, "only 1 of 4 is healthy")
        #expect(s.openSecurityAlerts == 2)
        #expect(s.reposWithOpenAlerts == 1)
        #expect(s.unprotectedDefaultBranches == 1)
    }

    @Test func emptyRegisterHasNilScore() {
        #expect(OversightSummary(repos: []).healthScore == nil)
    }

    @Test func aggregatesOpenPullRequestsAndIssues() {
        let repos = [
            OversightRepo(slug: "o/a", pushedAt: fixedNow, snapshot: snapshot(ci: .success, dependabot: 0, protected: true, prs: 3, issues: 5)),
            OversightRepo(slug: "o/b", pushedAt: fixedNow, snapshot: snapshot(ci: .success, dependabot: 0, protected: true, prs: 1, issues: 2)),
        ]
        let s = OversightSummary(repos: repos, now: fixedNow)
        #expect(s.totalOpenPullRequests == 4)
        #expect(s.totalOpenIssues == 7)
    }
}

@Suite("Oversight sync (read-only)")
struct OversightSyncTests {

    /// A full set of routes for one repo "o/alpha" so its snapshot succeeds, plus the listing.
    private func routes(listing: String) -> [String: (Int, String)] {
        let base = "/repos/o/alpha"
        return [
            "/user/repos": (200, listing),
            base: (200, #"{"name":"alpha","full_name":"o/alpha","private":true,"visibility":"private","description":null,"homepage":null,"default_branch":"main"}"#),
            "\(base)/commits/main": (200, #"{"sha":"deadbeef","commit":{"message":"m","author":{"name":"A","date":"2026-09-20T10:00:00Z"},"committer":{"name":"A","date":"2026-09-20T10:00:00Z"}}}"#),
            "\(base)/releases": (200, "[]"),
            "\(base)/pulls": (200, "[]"),
            "\(base)/issues": (200, "[]"),
            "\(base)/languages": (200, "{}"),
            "\(base)/actions/runs": (200, #"{"workflow_runs":[]}"#),
            "\(base)/dependabot/alerts": (200, #"[{"number":1},{"number":2}]"#),
            "\(base)/secret-scanning/alerts": (403, #"{"message":"no access"}"#), // unreadable → nil
            "\(base)/code-scanning/alerts": (200, "[]"),
            "\(base)/branches/main/protection": (404, #"{"message":"Branch not protected"}"#), // → false
        ]
    }

    @Test func discoversRepositoriesAndReadsSecurity() async throws {
        let listing = #"[{"full_name":"o/alpha","private":true,"archived":false,"pushed_at":"2026-09-25T00:00:00Z"}]"#
        let client = GitHubClient(token: "t", transport: OversightStub(routes(listing: listing)), now: { fixedNow })
        let (repos, report) = await OversightSync.refresh([], using: client, owner: "o", now: { fixedNow })
        #expect(report.discovered == ["o/alpha"])
        #expect(report.updated == ["o/alpha"])
        #expect(report.listError == nil)
        let alpha = try #require(repos.first)
        #expect(alpha.isPrivate)
        #expect(alpha.snapshot?.security?.dependabotAlerts == 2)
        #expect(alpha.snapshot?.security?.secretScanningAlerts == nil, "403 means Unknown, not zero")
        #expect(alpha.snapshot?.security?.codeScanningAlerts == 0)
        #expect(alpha.snapshot?.security?.defaultBranchProtected == false)
    }

    @Test func listErrorKeepsExistingDataAndReportsIt() async {
        // Listing endpoint fails; a previously scanned repo must be preserved untouched.
        let prior = OversightRepo(slug: "o/alpha", snapshot: snapshot(dependabot: 0, protected: true), observedAt: fixedNow)
        let client = GitHubClient(token: "t", transport: OversightStub(["/user/repos": (500, "{}")]), now: { fixedNow })
        let (repos, report) = await OversightSync.refresh([prior], using: client, owner: "o", now: { fixedNow })
        #expect(report.listError != nil)
        #expect(repos.count == 1)
        #expect(repos.first?.snapshot?.security?.dependabotAlerts == 0, "existing snapshot preserved on list failure")
    }

    @Test func snapshotFailurePreservesPriorSnapshotAndRecordsError() async throws {
        // Listing finds the repo, but its repo endpoint 500s → scanError set, prior snapshot kept.
        let listing = #"[{"full_name":"o/alpha","private":true,"archived":false,"pushed_at":"2026-09-25T00:00:00Z"}]"#
        let prior = OversightRepo(slug: "o/alpha", snapshot: snapshot(dependabot: 7, protected: true), observedAt: fixedNow)
        let client = GitHubClient(token: "t", transport: OversightStub(["/user/repos": (200, listing), "/repos/o/alpha": (500, "{}")]), now: { fixedNow })
        let (repos, report) = await OversightSync.refresh([prior], using: client, owner: "o", now: { fixedNow })
        #expect(report.failed["o/alpha"] != nil)
        let alpha = try #require(repos.first)
        #expect(alpha.scanError != nil)
        #expect(alpha.snapshot?.security?.dependabotAlerts == 7, "a failed refresh never blanks the last good snapshot")
    }
}
