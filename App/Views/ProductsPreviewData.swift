#if DEBUG
import Foundation
import LinumicCore

/// Debug-only screenshot aid: with `-LCCProductsSample 1` (and `-LCCScreen productBoard` or `-LCCScreen agents`), the
/// Products and Agents pages show made-up readings shaped like the real ones; nothing is read and the app starts no job
/// (LinumicOSApp). Never in a release build.
enum ProductsPreviewData {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "LCCProductsSample") != nil }

    private static func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    static func input(now: Date) -> ProductsInput? {
        guard isOn, let products = try? SeedInventory.load().products else { return nil }
        let readAt = now.addingTimeInterval(-20 * 60)
        func app(_ store: AppStore, _ id: String, _ product: String) -> ReleaseApp {
            ReleaseApp(store: store, appIdentifier: id, name: id, productID: product, productName: product, source: "sample")
        }
        func play(_ id: String, _ product: String, _ name: String, _ code: Int) -> PlayAppStatus {
            PlayAppStatus(app: app(.googlePlay, id, product), tracks: [
                PlayTrackInfo(track: "production", releases: [PlayTrackRelease(name: name, versionCodes: [code], status: .completed, rawStatus: "completed")]),
            ], detail: .edit, fetchedAt: readAt)
        }
        func ios(_ id: String, _ product: String, live: String, liveBuild: String, newest: String, newestBuild: String, uploaded: String) -> AppStoreAppStatus {
            let b = AppStoreBuildInfo(id: "\(id)-\(newestBuild)", number: newestBuild, version: newest, platform: "IOS", uploadedAt: at(uploaded), processingState: "VALID")
            return AppStoreAppStatus(app: app(.appStore, id, product), ascAppID: "1", versions: [
                AppStoreVersionInfo(id: "\(id)-live", versionString: live, platform: "IOS", state: "READY_FOR_SALE", createdAt: at("2026-10-01T08:00:00Z"),
                                    build: AppStoreBuildInfo(id: "\(id)-\(liveBuild)", number: liveBuild, version: live, platform: "IOS", uploadedAt: at("2026-10-01T07:00:00Z"))),
                AppStoreVersionInfo(id: "\(id)-next", versionString: newest, platform: "IOS", state: newest == live ? "READY_FOR_SALE" : "WAITING_FOR_REVIEW",
                                    createdAt: at(uploaded), build: b),
            ], builds: [b], fetchedAt: readAt)
        }
        let releases = ReleaseCenterSnapshot(
            appStore: [ios("app.worktrack", "worktrack", live: "1.3.0", liveBuild: "4", newest: "1.3.0", newestBuild: "4", uploaded: "2026-10-18T07:40:00Z"),
                       ios("af.velro.passenger", "velro", live: "1.2.0", liveBuild: "7", newest: "1.3.0", newestBuild: "9", uploaded: "2026-10-17T20:00:00Z")],
            play: [play("app.worktrack", "worktrack", "6 (1.3.0)", 6), play("af.velro.passenger", "velro", "11 (1.4.0)", 11),
                   play("af.velro.driver", "velro", "11 (1.4.0)", 11)],
            repos: [RepoReleaseStatus(repo: ReleaseRepo(slug: "aminullah-dev/WorkTrack", productName: "WorkTrack", source: "sample"), defaultBranch: "main",
                                      mainCI: .success, lastReleaseRead: true, fetchedAt: readAt)],
            appStoreReadAt: readAt, playReadAt: readAt, gitHubReadAt: readAt)
        let v180 = GitHubRelease(tag: "v1.8.0", publishedAt: at("2026-09-20T05:08:23Z"),
                                 assets: [.init(name: "KhayatYar-1.8.0.apk", downloadCount: 0), .init(name: "KhayatYar-1.8.0.dmg", downloadCount: 0),
                                          .init(name: "KhayatYar-1.8.0.msi", downloadCount: 0)])
        func reading(_ spec: String, _ name: String, _ code: String) -> VersionReading {
            let parts = spec.split(separator: "|").map(String.init)
            return VersionReading(specID: spec, repo: parts[0], path: parts[1], ref: "main", versionName: name, versionCode: code, line: 1, fetchedAt: readAt)
        }
        let tracking = [
            RepoReleaseTracking(slug: "aminullah-dev/WorkTrack", defaultBranch: "main", latestRelease: RepoReleaseTracking.LatestRelease.none, versions: [
                reading("aminullah-dev/WorkTrack|app/build.gradle.kts|Android", "1.3.0", "6"), reading("aminullah-dev/WorkTrack|ios/project.yml|iOS", "1.3.0", "4"),
            ], fetchedAt: readAt),
            RepoReleaseTracking(slug: "aminullah-dev/AfghanJama", defaultBranch: "main", latestRelease: .release(v180), recentReleases: [v180], versions: [
                reading("aminullah-dev/AfghanJama|gradle.properties|Android, Windows, macOS", "1.9.0", "14"),
            ], fetchedAt: readAt),
            RepoReleaseTracking(slug: "aminullah-dev/velro", defaultBranch: "main", latestRelease: RepoReleaseTracking.LatestRelease.none, versions: [
                reading("aminullah-dev/velro|mobile/gradle.properties|Android · VELRO Ride", "1.4.0", "11"),
                reading("aminullah-dev/velro|ios/project.yml|iOS · VELRO Ride", "1.4.0", "10"),
            ], fetchedAt: readAt),
        ]
        let history = ["aminullah-dev/WorkTrack", "aminullah-dev/AfghanJama", "aminullah-dev/velro"].map { repo in
            MainHistory(repo: repo, branch: "main", commitDates: (0..<100).map { now.addingTimeInterval(-Double($0) * 8 * 3600) }, newestSHA: "0000000",
                        isComplete: false, readAt: readAt)
        }
        var monitor = MonitorSnapshot()
        monitor.lastRoundAt = readAt
        for t in MonitorCatalog.targets where t.product == .workTrack || t.product == .talar {
            monitor.latest[t.id] = MonitorResult(targetID: t.id, checkedAt: readAt, state: .up, statusCode: 200, latencyMS: 180)
        }
        return ProductsInput(now: now, products: products, tracking: tracking, releases: releases,
                             licences: BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: readAt), monitor: monitor, history: history,
                             runningApp: ProductsModel.runningBuild)
    }

    static func windows(now: Date) -> [RepoPullWindow]? {
        guard isOn else { return nil }
        let registry = AgentRegistry.bundled
        // Pull request titles are of record (never translated), so they are not written as `title: "…"` literals, which the
        // catalogue check would take for strings to translate.
        let titles = ["[agent:linumic-os] Tests for the public App Store lookup and StoreSync", "[agent:talar-web] Sample change from the web agent"]
        let open = AgentPull(slug: "linumic-os", repo: "aminullah-dev/LinumicOS", number: 30, title: titles[0],
                             head: "agent/linumic-os/2026-10-20-app-store-lookup-tests", state: .open, isDraft: false,
                             url: URL(string: "https://github.com/aminullah-dev/LinumicOS/pull/30")!, createdAt: now.addingTimeInterval(-26 * 3600))
        let merged = AgentPull(slug: "talar-web", repo: "aminullah-dev/talar", number: 7, title: titles[1],
                               head: "agent/talar-web/2026-10-20-sample-web", state: .merged, isDraft: false,
                               url: URL(string: "https://github.com/aminullah-dev/talar/pull/7")!, createdAt: now.addingTimeInterval(-30 * 3600),
                               mergedAt: now.addingTimeInterval(-29 * 3600))
        return registry.repositories.map { repo in
            let pulls = [open, merged].filter { $0.repo == repo }
            return RepoPullWindow(repo: repo, pulls: pulls, pageCount: 12, oldestCreatedAt: now.addingTimeInterval(-60 * 86_400),
                                  isComplete: true, readAt: now.addingTimeInterval(-10 * 60))
        }
    }
}
#endif
