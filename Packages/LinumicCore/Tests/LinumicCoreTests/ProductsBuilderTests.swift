import Foundation
import Testing
@testable import LinumicCore

// The Products page built from readings shaped like the app's own (Release Center, Platforms hub, commits on main) and the
// seed inventory: every value with its source and read time, Unknown with a reason, and the Brief line and Desk item of
// a product whose platforms are not level.

private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private let readAt = at("2026-10-20T12:00:00Z")

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func app(_ store: AppStore, _ id: String, _ name: String, product: String) -> ReleaseApp {
    ReleaseApp(store: store, appIdentifier: id, name: name, productID: product, productName: product, source: "fixture")
}

private func snapshot() -> ReleaseCenterSnapshot {
    let build4 = AppStoreBuildInfo(id: "b-wt-4", number: "4", version: "1.3.0", platform: "IOS", uploadedAt: at("2026-10-18T07:40:00Z"),
                                   processingState: "VALID")
    let worktrackIOS = AppStoreAppStatus(
        app: app(.appStore, "app.worktrack", "Linumic WorkTrack", product: "worktrack"), ascAppID: "6810004398",
        versions: [
            AppStoreVersionInfo(id: "v-1.3.0", versionString: "1.3.0", platform: "IOS", state: "READY_FOR_SALE", releaseType: "MANUAL",
                                createdAt: at("2026-10-18T08:00:00Z"), build: build4),
            AppStoreVersionInfo(id: "v-1.2.0", versionString: "1.2.0", platform: "IOS", state: "REPLACED_WITH_NEW_VERSION",
                                createdAt: at("2026-10-06T08:00:00Z")),
        ],
        builds: [build4], fetchedAt: readAt)
    let worktrackPlay = PlayAppStatus(
        app: app(.googlePlay, "app.worktrack", "Linumic WorkTrack", product: "worktrack"),
        tracks: [
            PlayTrackInfo(track: "production", releases: [PlayTrackRelease(name: "6 (1.3.0)", versionCodes: [6], status: .completed, rawStatus: "completed")]),
            PlayTrackInfo(track: "internal", releases: [PlayTrackRelease(name: "6 (1.3.0)", versionCodes: [6], status: .completed, rawStatus: "completed")]),
        ], detail: .edit, fetchedAt: readAt)
    let pull = GitHubPullInfo(number: 29, title: "[agent:worktrack-backend] Unit tests for geofence validation (services/geo)", base: "main",
                              head: "agent/worktrack-backend/2026-10-20-geofence-tests", headSHA: "4f2c9a1",
                              url: URL(string: "https://github.com/aminullah-dev/WorkTrack/pull/29")!, mergeable: true, mergeableState: "clean",
                              createdAt: at("2026-10-20T05:04:48Z"), ci: .success)
    let worktrackRepo = RepoReleaseStatus(repo: ReleaseRepo(slug: "aminullah-dev/WorkTrack", productName: "WorkTrack", source: "fixture"),
                                          defaultBranch: "main", pulls: [pull], mainCI: .success, lastReleaseRead: true, fetchedAt: readAt)
    let kyRepo = RepoReleaseStatus(repo: ReleaseRepo(slug: "aminullah-dev/AfghanJama", productName: "AfghanJama", source: "fixture"),
                                   defaultBranch: "main", pulls: [], mainCI: .failure, lastReleaseRead: true, fetchedAt: readAt)
    return ReleaseCenterSnapshot(appStore: [worktrackIOS], play: [worktrackPlay], repos: [kyRepo, worktrackRepo],
                                 appStoreReadAt: readAt, playReadAt: readAt, gitHubReadAt: readAt)
}

private func tracking() -> [RepoReleaseTracking] {
    let v180 = GitHubRelease(tag: "v1.8.0", name: "KhayatYar 1.8.0", publishedAt: at("2026-09-20T05:08:23Z"),
                             url: URL(string: "https://github.com/aminullah-dev/AfghanJama/releases/tag/v1.8.0"),
                             assets: [.init(name: "KhayatYar-1.8.0.apk", downloadCount: 41), .init(name: "KhayatYar-1.8.0.dmg", downloadCount: 9),
                                      .init(name: "KhayatYar-1.8.0.msi", downloadCount: 17)])
    let v170 = GitHubRelease(tag: "v1.7.0", publishedAt: at("2026-08-27T03:10:48Z"),
                             assets: [.init(name: "KhayatYar-1.7.0.apk", downloadCount: 30)])
    return [
        RepoReleaseTracking(slug: "aminullah-dev/WorkTrack", defaultBranch: "main", latestRelease: RepoReleaseTracking.LatestRelease.none, versions: [
            VersionReading(specID: "aminullah-dev/WorkTrack|app/build.gradle.kts|Android", repo: "aminullah-dev/WorkTrack", path: "app/build.gradle.kts",
                           ref: "main", versionName: "1.3.0", versionCode: "6", line: 92, fetchedAt: readAt),
            VersionReading(specID: "aminullah-dev/WorkTrack|ios/project.yml|iOS", repo: "aminullah-dev/WorkTrack", path: "ios/project.yml",
                           ref: "main", versionName: "1.3.0", versionCode: "4", line: 20, fetchedAt: readAt),
        ], fetchedAt: readAt),
        RepoReleaseTracking(slug: "aminullah-dev/AfghanJama", defaultBranch: "main", latestRelease: .release(v180), recentReleases: [v180, v170],
                            openPullRequests: 0, versions: [
            VersionReading(specID: "aminullah-dev/AfghanJama|gradle.properties|Android, Windows, macOS", repo: "aminullah-dev/AfghanJama",
                           path: "gradle.properties", ref: "main", versionName: "1.9.0", versionCode: "14", line: 20, fetchedAt: readAt),
        ], fetchedAt: readAt),
    ]
}

private func history() -> [MainHistory] {
    // WorkTrack: four commits, the newest on 10-20. AfghanJama: a full page of 100, every one after the v1.8.0 release.
    let wt = MainHistory(repo: "aminullah-dev/WorkTrack", branch: "main",
                         commitDates: [at("2026-10-20T10:00:00Z"), at("2026-10-19T16:00:00Z"), at("2026-10-18T12:00:00Z"), at("2026-10-17T09:00:00Z")],
                         newestSHA: "a1b2c3d", isComplete: false, readAt: readAt)
    let ky = MainHistory(repo: "aminullah-dev/AfghanJama", branch: "main",
                         commitDates: (0..<100).map { at("2026-10-20T10:00:00Z").addingTimeInterval(-Double($0) * 6 * 3600) },
                         newestSHA: "e4f5a6b", isComplete: false, readAt: readAt)
    return [wt, ky]
}

private func input(running: RunningBuild? = RunningBuild(platform: .macOS, version: "0.2.0", build: "2")) throws -> ProductsInput {
    ProductsInput(now: readAt, products: try SeedInventory.load().products, tracking: tracking(), releases: snapshot(),
                  licences: BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: readAt), monitor: MonitorSnapshot(),
                  history: history(), runningApp: running)
}

@Suite("Products: the page, the Brief and the Desk")
struct ProductsBuilderTests {
    @Test func theCatalogueCoversEveryProductAndReusesTheInventory() throws {
        let catalog = ProductsCatalog.products
        #expect(catalog.map(\.title) == ["WorkTrack", "SafeBeauty", "VELRO", "Talar", "KhayatYar", "MediFlow", "NerkhTimes", "Namazia", "DukanPro", "Linumic OS"])
        let inventory = try SeedInventory.load().products
        let specs = Set((PlatformCatalog.profiles.flatMap(\.versionFiles) + ProductsCatalog.extraVersionFiles).map(\.id))
        for product in catalog {
            if let id = product.inventoryID {
                let record = try #require(inventory.first { $0.id == id }, "\(id) is an inventory product")
                // Every store app of a slot is the inventory's own listing; a slot with an id is one of its platforms.
                for slot in product.slots {
                    if let spec = slot.versionSpec { #expect(specs.contains(spec), "\(slot.id): \(spec) is a catalogued version file") }
                    else { #expect(slot.noVersionFile != nil, "\(slot.id) says why it has no version file") }
                    if let appID = slot.appIdentifier {
                        #expect(record.platforms.contains { $0.identifier == appID } || record.storeListings.contains { $0.appIdentifier == appID },
                                "\(slot.id): \(appID) is in the inventory")
                    }
                    #expect(record.platforms.contains { $0.platform == slot.platform }, "\(slot.id): the inventory lists \(slot.platform)")
                }
            } else {
                #expect(product.id == "linumicos" && product.extraRepos == ["aminullah-dev/LinumicOS"])
            }
            #expect(Set(product.slots.map(\.id)).count == product.slots.count)
        }
        // The one version file added for Linumic OS reads this repository's own project.yml.
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../project.yml"), encoding: .utf8)
        let parsed = VersionFileParser.parse(text, format: ProductsCatalog.linumicOSVersionFile.format)
        #expect(parsed.name != nil && parsed.code != nil)
    }

    @Test func aLevelProductWithEverySourceNamed() throws {
        let report = ProductsBuilder.build(try input())
        let card = try #require(report.card("worktrack"))
        #expect(card.level == .level)
        let app = try #require(card.tracks.first { $0.track.id == "app" })
        let android = try #require(app.slots.first { $0.slot.platform == .android })
        let ios = try #require(app.slots.first { $0.slot.platform == .iOS })
        #expect(android.live.value?.label == "1.3.0 (6)")
        #expect(android.build.value?.label == "1.3.0 (6)" && android.build.value?.date == nil, "Google Play gives no date")
        #expect(android.behind.reason?.contains("gives no date") == true)
        #expect(ios.live.value?.label == "1.3.0 (4)" && ios.live.value?.detail == "Live")
        #expect(ios.build.value?.date == at("2026-10-18T07:40:00Z"))
        #expect(ios.main.source == "aminullah-dev/WorkTrack ios/project.yml:20 @ main")
        #expect(ios.behind.value == BehindMain(commits: 3, atLeast: false, days: 2, newestCommit: at("2026-10-20T10:00:00Z")))
        for s in [android, ios] {
            for value in [s.live, s.build, s.main] {
                #expect(value.isKnown)
                #expect(!(value.source ?? "").isEmpty && value.readAt == readAt, "\(s.id): every value has its source and read time")
            }
        }
        // Pull requests and CI from the Release Center, the agent's pull request counted as one.
        #expect(card.pulls.value?.open == 1 && card.pulls.value?.byAgents == 1)
        #expect(card.ci.value?.passing == ["aminullah-dev/WorkTrack"])
        // The Monitor was never run here: Unknown with why, never zero.
        #expect(card.health.isUnknown && card.health.reason == "Not checked yet. The Monitor checks when the app opens.")
        #expect(card.licences == nil, "WorkTrack is not sold with a licence")
        // The console and server are listed, never compared.
        let web = try #require(card.tracks.first { $0.track.id == "console" }?.slots.first { $0.slot.platform == .web })
        #expect(!web.slot.compared && web.health != nil)
    }

    @Test func khayatYarIsNotLevelAndSaysWhy() throws {
        let report = ProductsBuilder.build(try input())
        let card = try #require(report.card("khayatyar"))
        let texts = card.level.findings.map(\.text)
        #expect(texts == [
            "Android 1.8.0 (2026-09-20) behind main 1.9.0 (14) by at least 100 commits, 30 days",
            "macOS 1.8.0 (2026-09-20) behind main 1.9.0 (14) by at least 100 commits, 30 days",
            "Windows 1.8.0 (2026-09-20) behind main 1.9.0 (14) by at least 100 commits, 30 days",
        ])
        let android = try #require(card.slots.first { $0.slot.platform == .android })
        #expect(android.build.source == "GitHub release v1.8.0 of aminullah-dev/AfghanJama" && android.build.value?.detail == "KhayatYar-1.8.0.apk")
        #expect(android.live.reason == "Not in a store: the inventory has no Google Play listing for com.afghanjama.")
        let ios = try #require(card.slots.first { $0.slot.platform == .iOS })
        #expect(ios.build.reason == "No App Store listing for com.afghanjama.khayatyar in the inventory, so its builds are not read.")
        #expect(ios.main.reason?.hasPrefix("iosApp/project.yml on main sets no MARKETING_VERSION") == true)
        // The ledger was synced and holds no KhayatYar licence: zero is a reading here, not a guess.
        #expect(card.licences?.value?.total == 0)
        #expect(card.ci.value?.failing == ["aminullah-dev/AfghanJama"])
    }

    @Test func unreadSourcesMakeUnknownNotLevel() throws {
        let report = ProductsBuilder.build(try input())
        // Namazia: the consoles did not list it and its repository was not read in this reading.
        let namazia = try #require(report.card("namazia"))
        #expect(namazia.level.unknowns.contains("Android build: Google Play did not list af.namazia.app."))
        #expect(namazia.level.unknowns.contains("Android on main: aminullah-dev/-Namazia has not been read from GitHub yet."))
        // SafeBeauty: the consoles did not list it either, so its live versions are the inventory listings' own, with
        // their sources; they differ (2.1.5 and 1.0.1), and an unread part never hides that.
        let safeBeauty = try #require(report.card("safebeauty"))
        #expect(safeBeauty.level.findings.map(\.text) == ["Live versions differ: Android 2.1.5, iOS 1.0.1"])
        let sbAndroid = try #require(safeBeauty.slots.first { $0.slot.platform == .android })
        #expect(sbAndroid.live.value?.detail == "From the inventory's store listing")
        #expect(sbAndroid.live.source == "https://play.google.com/store/apps/details?id=com.security.stealthapp")
        // Linumic OS: the Mac build is this app; the iPhone build is not known on a Mac.
        let os = try #require(report.card("linumicos"))
        let mac = try #require(os.slots.first { $0.slot.platform == .macOS })
        #expect(mac.build.value?.label == "0.2.0 (2)" && mac.build.source == "This app's Info.plist (the build running now)")
        #expect(os.level.unknowns.contains { $0.hasPrefix("iOS build: Only the build running on this device is known here") })
        // Nothing read at all: the whole page says so.
        let empty = ProductsBuilder.build(ProductsInput(now: readAt, products: [], tracking: [], releases: ReleaseCenterSnapshot(),
                                                        licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                                        monitor: MonitorSnapshot()))
        #expect(empty.nothingRead)
        guard case .neverRead = ProductsBrief.section(empty).state else {
            Issue.record("nothing read is never read")
            return
        }
    }

    @Test func briefLineAndDeskItemPerProductNotLevel() throws {
        let report = ProductsBuilder.build(try input())
        let section = ProductsBrief.section(report)
        let line = try #require(section.lines.first { $0.id == "products.notLevel.khayatyar" })
        #expect(line.text == "KhayatYar: platforms not level" && line.product == "KhayatYar" && line.destination == .products("khayatyar"))
        #expect(line.detail?.contains("Android 1.8.0 (2026-09-20) behind main 1.9.0 (14)") == true)
        #expect(!section.lines.contains { $0.id == "products.notLevel.worktrack" }, "WorkTrack is level")
        #expect(section.gaps.contains { $0.key == "namazia" && $0.product == "Namazia" }, "unknown is an item, never level")
        #expect(section.lines.contains { $0.id == "products.notLevel.safebeauty" })
        #expect(!section.gaps.contains { $0.key == "worktrack" })

        var brief = BriefInput(now: readAt, monitor: MonitorSnapshot(), releases: snapshot(),
                               licences: BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: readAt),
                               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                               operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []))
        brief.products = report
        let built = DailyBriefBuilder.build(brief, changes: [])
        #expect(built.sections.map(\.kind) == BriefSourceKind.allCases)
        let desk = DeskBuilder.build(brief: built, ledgers: .unsupported, state: DeskState(), now: readAt, calendar: utc)
        let item = try #require(desk.open.first { $0.id == "brief.products|products.notLevel.khayatyar|fact" })
        #expect(item.item.domain == .khayatYar && item.item.destination == .screen(.products("khayatyar")))
        #expect(item.item.evidence.cadence == AutomationCatalog.spec(.products).cadence)
        // The fact stays the same while main gains commits, so a dismissal holds until a version changes.
        var later = try input()
        later.history = history().map { h in
            var h = h
            h.commitDates.insert(at("2026-10-21T09:00:00Z"), at: 0)
            return h
        }
        let again = ProductsBrief.section(ProductsBuilder.build(later)).lines.first { $0.id == line.id }
        #expect(again?.factKey == line.factKey)
    }
}
