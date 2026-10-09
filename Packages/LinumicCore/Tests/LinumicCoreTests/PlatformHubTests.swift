import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. File snippets copy the *shape* of the real version files (comments, suffixes,
// per-target overrides); the values are samples and are never shown as real data.

// MARK: - Version files

@Suite("Platforms hub: version files")
struct VersionFileParserTests {
    @Test func gradleIgnoresCommentsAndSuffixes() {
        let text = """
        android {
            defaultConfig {
                applicationId = "sample.app"
                // 5 / 1.3.0: versionCode 4 is spent
                versionCode = 6
                versionName = "1.3.0"
            }
            productFlavors {
                create("demo") {
                    applicationIdSuffix = ".demo"
                    versionNameSuffix = "-demo"
                }
            }
        }
        """
        let r = VersionFileParser.parse(text, format: .gradle)
        #expect(r.name == "1.3.0")
        #expect(r.code == "6")
        #expect(r.line == 6)
    }

    @Test func propertiesWithPersianComments() {
        let text = """
        # `appVersion` رشته است و هر دو سکو همین را می‌گیرند.
        org.gradle.jvmargs=-Xmx2g
        appVersion=1.9.0
        # کد نسخه
        appVersionCode=14
        """
        let r = VersionFileParser.parse(text, format: .properties(nameKey: "appVersion", codeKey: "appVersionCode"))
        #expect(r == .init(name: "1.9.0", code: "14", line: 3))
        #expect(VersionFileParser.parse("velro.versionName=1.2.4\nvelro.versionCode=8", format: .properties(nameKey: "velro.versionName", codeKey: "velro.versionCode")).name == "1.2.4")
    }

    private let xcodegen = """
    name: Sample
    settings:
      base:
        MARKETING_VERSION: "1.1.0"
        CURRENT_PROJECT_VERSION: "5"
    targets:
      Passenger:
        info:
          properties:
            CFBundleShortVersionString: $(MARKETING_VERSION)
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: sample.passenger
      Driver:
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: sample.driver
            MARKETING_VERSION: "1.0.2" # driver
            CURRENT_PROJECT_VERSION: "4" # driver
    """

    @Test func xcodegenTargetOverrideWins() {
        let r = VersionFileParser.parse(xcodegen, format: .xcodegen(bundleID: "sample.driver"))
        #expect(r.name == "1.0.2")
        #expect(r.code == "4")
        #expect(r.line == 18)
    }

    @Test func xcodegenFallsBackToProjectWideSettings() {
        let r = VersionFileParser.parse(xcodegen, format: .xcodegen(bundleID: "sample.passenger"))
        #expect(r.name == "1.1.0", "the $(MARKETING_VERSION) reference is not taken as a value")
        #expect(r.code == "5")
    }

    @Test func xcodegenUnknownBundleReadsNothing() {
        #expect(VersionFileParser.parse(xcodegen, format: .xcodegen(bundleID: "sample.other")).name == nil)
    }

    @Test func pyprojectAndPubspec() {
        #expect(VersionFileParser.parse("[project]\nname = \"sample\"\nversion = \"0.2.0\"\n", format: .pyproject).name == "0.2.0")
        let pub = VersionFileParser.parse("name: sample\ndescription: x\n\nversion: 1.0.0+7\n", format: .pubspec)
        #expect(pub == .init(name: "1.0.0", code: "7", line: 4))
    }
}

@Suite("Platforms hub: versions")
struct SemanticVersionTests {
    @Test func parsesOnlyRealVersions() {
        #expect(SemanticVersion("v1.8.0")?.description == "1.8.0")
        #expect(SemanticVersion("1.0.0+1")?.description == "1.0.0")
        #expect(SemanticVersion("android-app") == nil)
        #expect(SemanticVersion("1.3.0-demo") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test func comparesNumerically() throws {
        #expect(try #require(SemanticVersion("1.0.10")) > #require(SemanticVersion("1.0.9")))
        #expect(SemanticVersion("1.0") == SemanticVersion("1.0.0"))
        #expect(try #require(SemanticVersion("v1.8.0")) < #require(SemanticVersion("1.9.0")))
    }

    @Test func storeLabelsWithOneVersionOnly() {
        #expect(SemanticVersion.single(in: "8 (1.2.4)")?.description == "1.2.4")
        #expect(SemanticVersion.single(in: "iOS 1.0, macOS 1.0")?.description == "1.0")
        #expect(SemanticVersion.single(in: "iOS 1.0, macOS 1.1") == nil, "two different versions: no comparison")
        #expect(SemanticVersion.single(in: nil) == nil)
    }
}

// MARK: - GitHub reads

private final class Routes: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var routes: [String: (Int, String, [String: String])]
    init(_ routes: [String: (Int, String, [String: String])]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let path = request.url!.path(percentEncoded: false)
        let (status, body, headers) = lock.withLock { routes[path] } ?? (404, #"{"message":"Not Found"}"#, [:])
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private let base = "/repos/SAMPLE/app"
private func ok(_ body: String, etag: String? = nil) -> (Int, String, [String: String]) { (200, body, etag.map { ["ETag": $0] } ?? [:]) }

private func trackingRoutes(latest: (Int, String, [String: String])? = nil) -> [String: (Int, String, [String: String])] {
    [
        base: ok(#"{"default_branch":"main"}"#),
        "\(base)/releases/latest": latest ?? ok(#"{"tag_name":"v1.8.0","name":"1.8.0","published_at":"2026-09-20T05:08:23Z","draft":false,"prerelease":false,"html_url":"https://github.com/SAMPLE/app/releases/tag/v1.8.0","assets":[{"name":"SAMPLE-1.8.0.apk","download_count":8,"browser_download_url":"https://github.com/x.apk"},{"name":"SAMPLE-1.8.0.msi","download_count":7,"browser_download_url":null}]}"#),
        "\(base)/releases": ok(#"[{"tag_name":"v1.9.0-draft","name":null,"published_at":null,"draft":true,"prerelease":false,"html_url":null,"assets":[]},{"tag_name":"v1.8.0","name":"1.8.0","published_at":"2026-09-20T05:08:23Z","draft":false,"prerelease":false,"html_url":null,"assets":[]}]"#),
        "\(base)/pulls": ok(#"[{"number":4},{"number":5}]"#),
        "\(base)/actions/workflows": ok(#"{"workflows":[{"id":1,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":2,"name":"Manual","path":".github/workflows/apk.yml","state":"active"},{"id":3,"name":"Dependabot Updates","path":"dynamic/dependabot/dependabot-updates","state":"active"},{"id":4,"name":"Old","path":".github/workflows/old.yml","state":"disabled_manually"}]}"#),
        "\(base)/actions/workflows/1/runs": ok(#"{"workflow_runs":[{"status":"completed","conclusion":"failure","created_at":"2026-10-09T02:15:52Z","html_url":"https://github.com/SAMPLE/app/actions/runs/9","head_sha":"9d1a52d","event":"push"}]}"#),
        "\(base)/actions/workflows/2/runs": ok(#"{"workflow_runs":[]}"#),
        "\(base)/contents/gradle.properties": ok("appVersion=1.9.0\nappVersionCode=14\n", etag: "\"v1\""),
    ]
}

private let spec = VersionFileSpec(repo: "SAMPLE/app", path: "gradle.properties", format: .properties(nameKey: "appVersion", codeKey: "appVersionCode"),
                                   component: "Android", platform: .android, appIdentifier: "sample.app", releaseRepo: "SAMPLE/app",
                                   source: CatalogSource("TEST", checkedAt: .distantPast))

@Suite("Platforms hub: GitHub reads")
struct ReleaseTrackingTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func readsReleasesWorkflowsVersionsAndPulls() async throws {
        let t = Routes(trackingRoutes())
        let tracking = try await GitHubClient(token: "t", transport: t, now: { [now] in now }).releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        let release = try #require(tracking.release)
        #expect(release.tag == "v1.8.0")
        #expect(release.totalDownloads == 15)
        #expect(release.assets.map(\.name) == ["SAMPLE-1.8.0.apk", "SAMPLE-1.8.0.msi"])
        #expect(tracking.recentReleases.map(\.tag) == ["v1.8.0"], "drafts are left out")
        #expect(tracking.openPullRequests == 2)
        #expect(tracking.workflows?.map(\.name) == ["CI", "Manual"], "dynamic and disabled workflows are left out")
        #expect(tracking.workflows?.first?.latestRun?.outcome == .failure)
        #expect(tracking.workflows?.last?.latestRun == nil, "never ran on main: no run, not a guess")
        #expect(tracking.versions.first?.label == "1.9.0 (14)")
        #expect(tracking.versions.first?.sourceReference == "SAMPLE/app gradle.properties:1 @ main")
        #expect(tracking.problems.isEmpty)
        #expect(tracking.fetchedAt == now)

        for r in t.requests {
            #expect(r.httpMethod == "GET" && r.httpBody == nil)
            #expect(r.url?.host() == "api.github.com")
        }
        let runs = try #require(t.requests.first { $0.url!.path().hasSuffix("/workflows/1/runs") })
        #expect(runs.url?.query()?.contains("branch=main") == true)
        let contents = try #require(t.requests.first { $0.url!.path().contains("/contents/") })
        #expect(contents.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        #expect(contents.url?.query() == "ref=main")
    }

    @Test func noReleaseIsAFactNotAnError() async throws {
        let t = Routes(trackingRoutes(latest: (404, #"{"message":"Not Found"}"#, [:])))
        let tracking = try await GitHubClient(token: nil, transport: t).releaseTracking(slug: "SAMPLE/app", versionFiles: [])
        #expect(tracking.latestRelease == RepoReleaseTracking.LatestRelease.none)
        #expect(tracking.problems.isEmpty)
    }

    @Test func aFailingPartIsReportedAndTheRestKept() async throws {
        var routes = trackingRoutes()
        routes["\(base)/actions/workflows"] = (500, "{}", [:])
        let tracking = try await GitHubClient(token: "t", transport: Routes(routes)).releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        #expect(tracking.workflows == nil, "unread stays Unknown, not an empty list")
        #expect(tracking.problems.count == 1)
        #expect(tracking.release != nil)
    }

    @Test func etagMakesTheSecondReadConditional() async throws {
        let t = Routes(trackingRoutes())
        let cache = GitHubResponseCache()
        let client = GitHubClient(token: "t", transport: t, cache: cache)
        _ = try await client.releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        t.routes["\(base)/contents/gradle.properties"] = (304, "", ["ETag": "\"v1\""])
        let second = try await client.releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        #expect(second.versions.first?.versionName == "1.9.0", "a 304 is answered from the cache")
        #expect(await cache.notModifiedCount == 1)
        let conditional = t.requests.filter { $0.url!.path().contains("/contents/") }.last
        #expect(conditional?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func cacheIsKeptApartPerTokenAndMediaType() async throws {
        let t = Routes(trackingRoutes())
        let cache = GitHubResponseCache()
        _ = try await GitHubClient(token: "t", transport: t, cache: cache).releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        _ = try await GitHubClient(token: nil, transport: t, cache: cache).releaseTracking(slug: "SAMPLE/app", versionFiles: [spec])
        let anonymous = t.requests.filter { $0.url!.path().contains("/contents/") && $0.value(forHTTPHeaderField: "Authorization") == nil }
        #expect(anonymous.first?.value(forHTTPHeaderField: "If-None-Match") == nil, "an authenticated answer is never replayed without a token")
    }
}

// MARK: - Drift, rows and sync

private let day: TimeInterval = 86_400
private func reading(_ name: String?, spec: VersionFileSpec = spec) -> VersionReading {
    VersionReading(specID: spec.id, repo: spec.repo, path: spec.path, ref: "main", versionName: name, line: 1, fetchedAt: Date(timeIntervalSince1970: 10 * day))
}

private func tracking(release: String? = "v1.8.0", main: String? = "1.9.0", ci: String = "success") -> RepoReleaseTracking {
    RepoReleaseTracking(
        slug: "SAMPLE/app", defaultBranch: "main",
        latestRelease: release.map { .release(GitHubRelease(tag: $0)) } ?? RepoReleaseTracking.LatestRelease.none,
        workflows: [WorkflowStatus(id: 1, name: "CI", path: ".github/workflows/ci.yml", latestRun: .init(status: "completed", conclusion: ci))],
        versions: [reading(main)], fetchedAt: Date(timeIntervalSince1970: 10 * day))
}

private let profile = PlatformProfile(productID: "sample", title: "SAMPLE", businessModel: .licence,
                                      businessModelSource: CatalogSource("TEST", checkedAt: .distantPast), versionFiles: [spec])

private func product(play: String? = nil) -> Product {
    var p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: .distantPast))
    p.repositories = [
        RepositoryRecord(name: "app", owner: "SAMPLE", url: URL(string: "https://github.com/SAMPLE/app"), type: .application),
        RepositoryRecord(name: "site", owner: "SAMPLE", url: URL(string: "https://github.com/SAMPLE/site"), type: .website),
    ]
    if let play {
        p.storeListings = [StoreListing(store: .googlePlay, appName: "SAMPLE", appIdentifier: "sample.app", productionVersion: play,
                                        verification: Verification(status: .verified, sources: [Source(kind: .googlePlay, reference: "Google Play Developer API", observedAt: Date(timeIntervalSince1970: 9 * day))], verifiedAt: Date(timeIntervalSince1970: 9 * day)))]
    }
    return p
}

@Suite("Platforms hub: drift")
struct PlatformDriftTests {
    @Test func mainAheadOfLatestRelease() {
        let flags = PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking()])
        #expect(flags.map(\.kind) == [.releaseBehindMain])
        #expect(flags.first?.evidence.count == 2, "both compared values carry their source")
    }

    @Test func noDriftWhenEqualOrNotComparable() {
        #expect(PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(release: "v1.9.0")]).isEmpty)
        #expect(PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(release: "android-app")]).isEmpty, "a tag that isn't a version is never compared")
        #expect(PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(release: nil)]).isEmpty)
        #expect(PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(main: nil)]).isEmpty, "unknown main version: nothing computed")
    }

    @Test func storeOlderThanMain() {
        let flags = PlatformDrift.flags(profile: profile, product: product(play: "13 (1.8.0)"), tracking: [tracking(release: "v1.9.0")])
        #expect(flags.map(\.kind) == [.storeBehindMain])
        #expect(flags.first?.evidence.last?.contains("Google Play Developer API") == true)
        #expect(PlatformDrift.flags(profile: profile, product: product(play: "1.9.0"), tracking: [tracking(release: "v1.9.0")]).isEmpty)
        #expect(PlatformDrift.flags(profile: profile, product: product(play: "iOS 1.0, Android 1.1"), tracking: [tracking(release: "v1.9.0")]).isEmpty)
    }

    @Test func ciFailingOnMain() {
        let flags = PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(release: "v1.9.0", ci: "failure")])
        #expect(flags.map(\.kind) == [.ciFailing])
        #expect(PlatformDrift.flags(profile: profile, product: product(), tracking: [tracking(release: "v1.9.0", ci: "cancelled")]).isEmpty)
    }
}

@Suite("Platforms hub: rows and sync")
struct PlatformHubRowTests {
    @Test func rowsOnlyForProductsInTheInventoryAndCodeRepositories() {
        #expect(PlatformHub.repositories(profile: profile, product: product()) == ["SAMPLE/app"], "the website repository isn't watched")
        let rows = PlatformHub.rows(products: [product()], tracking: [tracking()], profiles: [profile, PlatformProfile(
            productID: "missing", title: "x", businessModel: .unknown, businessModelSource: CatalogSource("TEST", checkedAt: .distantPast))])
        #expect(rows.map(\.id) == ["sample"], "a profile without an inventory product is not shown")
        #expect(rows.first?.latestRelease?.release.tag == "v1.8.0")
        let summary = PlatformHubSummary(rows: rows)
        #expect(summary.withReleaseDrift == 1 && summary.withCIFailing == 0 && summary.withStoreDrift == 0 && summary.notRead == 0)
        let unread = PlatformHub.rows(products: [product()], tracking: [], profiles: [profile])
        #expect(unread.first?.unreadRepos == ["SAMPLE/app"])
        #expect(PlatformHubSummary(rows: unread).notRead == 1)
    }

    @Test func failedRefreshKeepsThePreviousData() async {
        let t = Routes([:])   // every request 404s, including the repository itself
        let previous = tracking()
        let (result, report) = await PlatformSync.refresh(products: [product()], previous: [previous], using: GitHubClient(token: "t", transport: t), profiles: [profile])
        #expect(result.count == 1)
        #expect(result.first?.release?.tag == "v1.8.0", "the last good read is kept")
        #expect(result.first?.error != nil)
        #expect(report.failed.keys.sorted() == ["SAMPLE/app"])
    }

    @Test func rateLimitStopsTheRound() async {
        let t = Routes([base: (403, "{}", ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1791000000"])])
        var two = product()
        two.repositories.append(RepositoryRecord(name: "other", owner: "SAMPLE", url: URL(string: "https://github.com/SAMPLE/other"), type: .application))
        let (_, report) = await PlatformSync.refresh(products: [two], previous: [], using: GitHubClient(token: "t", transport: t), profiles: [profile])
        #expect(report.failed.count == 2)
        #expect(t.requests.count == 1, "no more requests once the limit is hit")
    }

    @Test func cacheFileRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())/platform-hub.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlatformHubStore(fileURL: url)
        #expect(await store.load() == PlatformHubFile(), "a missing file is an empty cache")
        let file = PlatformHubFile(repos: [tracking()], etags: ["k": .init(etag: "\"e\"", body: Data("x".utf8), storedAt: Date(timeIntervalSince1970: 0))],
                                   lastRefresh: Date(timeIntervalSince1970: 5))
        try await store.save(file)
        #expect(await store.load() == file)
    }
}

// MARK: - Catalogue integrity (against the bundled, verified seed)

@Suite("Platforms hub: catalogue")
struct PlatformCatalogTests {
    @Test func everyProfileIsAnExistingProductAndItsRepositories() throws {
        let seed = try SeedInventory.load()
        #expect(PlatformCatalog.profiles.count == 9)
        for profile in PlatformCatalog.profiles {
            let product = try #require(seed.products.first { $0.id == profile.productID }, "\(profile.productID) is not an inventory product")
            let slugs = product.repositories.compactMap(\.gitHubSlug).map { $0.lowercased() }
            for spec in profile.versionFiles {
                #expect(slugs.contains(spec.repo.lowercased()), "\(spec.repo) is not a repository of \(product.id)")
                if let r = spec.releaseRepo { #expect(slugs.contains(r.lowercased())) }
                #expect(!spec.source.reference.isEmpty)
            }
            #expect((profile.licenceProduct != nil) == (profile.businessModel == .licence))
            for link in profile.links {
                #expect(link.url.scheme == "https")
                #expect(link.source.reference.contains("2026-10-09"), "every link records when it was checked")
            }
        }
    }

    @Test func specIDsAreUnique() {
        let ids = PlatformCatalog.profiles.flatMap(\.versionFiles).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: - Live (opt-in)

@Suite("Platforms hub: live")
struct PlatformHubLiveTests {
    /// Live, read-only sweep of every catalogued product against api.github.com. Runs only when
    /// LCC_LIVE_HUB is set; GITHUB_TOKEN is optional (without it only public repositories answer).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCC_LIVE_HUB"] != nil))
    func liveSweep() async throws {
        let seed = try SeedInventory.load()
        let cache = GitHubResponseCache()
        let client = GitHubClient(token: ProcessInfo.processInfo.environment["GITHUB_TOKEN"], cache: cache)
        let (tracking, report) = await PlatformSync.refresh(products: seed.products, previous: [], using: client, cache: cache)
        print("LIVE HUB updated=\(report.updated.count) failed=\(report.failed)")
        for row in PlatformHub.rows(products: seed.products, tracking: tracking) {
            print("== \(row.profile.title) [\(row.profile.businessModel.rawValue)] PRs=\(row.openPullRequests.map(String.init) ?? "?")")
            if let l = row.latestRelease {
                print("   release \(l.release.tag) \(l.release.publishedAt.map { PlatformDrift.stamp($0) } ?? "?") on \(l.repo): " + l.release.assets.map { "\($0.name)=\($0.downloadCount)" }.joined(separator: ", "))
            } else { print("   release: \(row.hasNoRelease ? "none" : "unknown")") }
            for v in row.versions { print("   main \(v.spec.component): \(v.reading?.label ?? "Unknown") \(v.reading?.error ?? "") [\(v.reading?.sourceReference ?? v.spec.path)]") }
            for w in row.workflows { print("   ci \(w.repo) \(w.workflow.name): \(w.workflow.latestRun.map { "\($0.status)/\($0.conclusion ?? "-") \($0.createdAt.map { PlatformDrift.stamp($0) } ?? "")" } ?? "no run on main")") }
            for f in row.flags { print("   FLAG \(f.kind.rawValue): \(f.detail)") }
            for r in row.repos where !r.problems.isEmpty { print("   problems \(r.slug): \(r.problems)") }
        }
        #expect(report.failed.isEmpty || ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil)
    }
}
