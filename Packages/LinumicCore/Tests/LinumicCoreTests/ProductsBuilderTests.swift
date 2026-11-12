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
        #expect(catalog.map(\.title) == ["WorkTrack", "SafeBeauty", "VELRO", "Talar", "KhayatYar", "MediFlow", "NerkhTimes", "Namazia", "DukanPro", "Linumic OS", "Pashto Likman",
                                         "BE-PAYA", "Family Fund Management", "Spin Cake", "Kabul Signal", "Radar-system"])
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
                // Not inventory products: each repository is the git remote of the project's own folder (2026-11-12);
                // Kabul Signal's folder is no git repository, so it has none.
                let remotes = ["linumicos": ["aminullah-dev/LinumicOS"], "pashtolikman": ["aminullah-dev/PashtoKey"],
                               "bepaya": ["aminullah-dev/BE-PAYA"], "familyfund": ["aminullah-dev/FAMILY-FUND-MANAGEMENT"],
                               "spincake": ["aminullah-dev/SpinCake"], "kabulsignal": [], "radarsystem": ["aminullah-dev/Radar-system"]]
                #expect(remotes[product.id] == product.extraRepos, "\(product.id)")
                #expect(!product.source.isEmpty && product.slots.allSatisfy { !$0.source.isEmpty })
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
        // SafeBeauty: the consoles did not list it either, so its live versions are the inventory listings' own, shown with
        // their sources and dates (2.1.5 and 1.0.1, recorded 2026-09-23); a record can lag behind the store, so it is not
        // compared and the level is unknown, with why.
        let safeBeauty = try #require(report.card("safebeauty"))
        #expect(safeBeauty.level.unknowns.contains("Android in the store: Google Play did not list com.security.stealthapp."))
        #expect(safeBeauty.level.findings.isEmpty)
        let sbAndroid = try #require(safeBeauty.slots.first { $0.slot.platform == .android })
        #expect(sbAndroid.live.value?.label == "2.1.5" && sbAndroid.live.value?.detail == "From the inventory's store listing")
        #expect(sbAndroid.live.source == "https://play.google.com/store/apps/details?id=com.security.stealthapp")
        #expect(sbAndroid.live.readAt == at("2026-09-23T07:00:00Z"))
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
        #expect(section.gaps.contains { $0.key == "safebeauty" }, "a store record alone never makes a product not level")
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

    @Test func theProjectsListedOn20261112SayOnlyWhatTheirFilesSay() throws {
        let report = ProductsBuilder.build(try input())
        let section = ProductsBrief.section(report)
        let ids = ["bepaya", "familyfund", "spincake", "kabulsignal", "radarsystem"]
        for id in ids {
            let card = try #require(report.card(id), "\(id) has a card")
            // Nothing of it is compared: never "level", never an item on the Desk.
            #expect(card.level == .nothingCompared, "\(id)")
            #expect(!section.gaps.contains { $0.key == id } && !section.lines.contains { $0.id.hasSuffix(".\(id)") }, "\(id)")
            #expect(card.product.source.contains("~/Projects/Multiplatform/") && card.product.source.contains("2026-11-12"), "\(id)")
            #expect(card.health.reason == "No public address of this product is monitored.")
            for s in card.slots {
                #expect(!s.slot.compared && s.slot.source.contains("2026-11-12"), "\(s.slot.id)")
                // A store app without an inventory listing: not in a store by the inventory, its builds not read; no version.
                if let appID = s.slot.appIdentifier, let store = s.slot.store {
                    #expect(s.live.reason == "Not in a store: the inventory has no \(store.title) listing for \(appID).")
                    #expect(s.build.isUnknown && s.build.reason == "No \(store.title) listing for \(appID) in the inventory, so its builds are not read.")
                    #expect(s.main.reason == "No version file is catalogued for this app yet.")
                } else {
                    #expect(!s.build.isKnown && !s.build.isUnknown, "\(s.slot.id): a web or server part says why it has no build")
                }
            }
        }
        // Their repositories are not watched by the Release Center, so pull requests and CI say so instead of "not read yet".
        let bePaya = try #require(report.card("bepaya"))
        #expect(bePaya.repos == ["aminullah-dev/BE-PAYA"])
        #expect(bePaya.pulls.reason == "The Release Center does not watch aminullah-dev/BE-PAYA, so its pull requests are not read.")
        #expect(bePaya.ci.reason == "The Release Center does not watch aminullah-dev/BE-PAYA, so its CI is not read.")
        #expect(bePaya.slots.map(\.slot.appIdentifier) == ["com.linumic.bepaya", "com.linumic.bepaya"])
        // Kabul Signal's folder is no git repository: no repository, which is "none", not "not read".
        let kabul = try #require(report.card("kabulsignal"))
        #expect(kabul.repos.isEmpty && kabul.pulls.reason == "No code repository is recorded for this product." && !kabul.pulls.isUnknown)
        // Radar-system is not a product: listed with no platform.
        #expect(try #require(report.card("radarsystem")).tracks.isEmpty)
        let fund = try #require(report.card("familyfund"))
        #expect(fund.slots.map(\.slot.platform) == [.android, .iOS, .web, .backend])
        #expect(fund.slots.compactMap(\.slot.appIdentifier) == ["af.familyfund.family_fund", "af.familyfund.familyFund"])
        #expect(try #require(report.card("spincake")).slots.map(\.slot.appIdentifier) == ["com.spincake.ordering", nil])
        // A repository the Release Center does watch but has not read yet still says "not read yet".
        let mediflow = try #require(report.card("mediflow"))
        #expect(mediflow.pulls.reason == "The pull requests of aminullah-dev/MediFlow have not been read yet.")
        // None of them is a store app the Release Center reads.
        let apps = Set(ReleaseCatalog.apps(from: try SeedInventory.load().products).map(\.appIdentifier))
        #expect(apps.isDisjoint(with: ["com.linumic.bepaya", "af.familyfund.family_fund", "af.familyfund.familyFund", "com.spincake.ordering", "com.kabulsignal.reader"]))
    }
}
