import Foundation
import Testing
@testable import LinumicCore

// `release-gh-tags-afghanjama.json` is KhayatYar's real tag list, read with `gh api repos/aminullah-dev/AfghanJama/tags`
// on 2026-11-04 and reduced to name and commit. Everything else here is synthetic, shaped like the real readings.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let readAt = Date(timeIntervalSince1970: 1_800_000_000)
private let khayatYar = InstalledAppCatalog.apps.first { $0.productID == "khayatyar" }!

/// A folder of Info.plists in memory.
private struct FakeApplications: InstalledAppFileSystem {
    var names: [String]?
    var files: [String: Data] = [:]

    func names(in folder: String) throws -> [String] {
        guard folder == "/Applications", let names else { throw CocoaError(.fileReadNoPermission) }
        return names
    }

    func contents(of path: String) throws -> Data {
        guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
}

private func plist(_ values: [String: String]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
}

private func installed(_ version: String?, build: String? = nil, channel: String? = nil, commit: String? = nil,
                       bundleID: String = "com.afghanjama.khayatyar") -> Sourced<InstalledAppInfo> {
    .known(InstalledAppInfo(bundleID: bundleID, version: version, build: build, channel: channel, commit: commit),
           source: "/Applications/KhayatYar.app/Contents/Info.plist", readAt: readAt)
}

private func release(_ tag: String, kind: GitHubReleaseRef.Kind = .tag, commit: String? = nil, complete: Bool = true) -> Sourced<ReleaseMark> {
    .known(ReleaseMark(tag: tag, version: SemanticVersion(tag)!, kind: kind, commit: commit, complete: complete),
           source: "GitHub tags and releases of aminullah-dev/AfghanJama", readAt: readAt)
}

private let repo = ReleaseRepo(slug: "aminullah-dev/AfghanJama", productName: "KhayatYar", source: "test")

@Suite("Installed on this Mac: the comparison")
struct InstalledVerdictTests {
    @Test func theThirdOfNovemberIsBehind() {
        // 1.12.1 in /Applications while tag v1.13.0 existed.
        #expect(InstalledAppCheck.compare(installed: installed("1.12.1"), newest: release("v1.13.0"))
            == .behind(installed: "1.12.1", release: "v1.13.0", testBuild: false))
        // And when the app says it is a test build, the line says that too.
        let verdict = InstalledAppCheck.compare(installed: installed("1.12.1", channel: "test build"), newest: release("v1.13.0"))
        #expect(verdict == .behind(installed: "1.12.1", release: "v1.13.0", testBuild: true))
        #expect(verdict.needsOwner)
    }

    @Test func versionsCompareAsNumbersNotAsText() {
        #expect(InstalledAppCheck.compare(installed: installed("1.9.0"), newest: release("v1.10.0"))
            == .behind(installed: "1.9.0", release: "v1.10.0", testBuild: false))
        #expect(InstalledAppCheck.compare(installed: installed("1.13.0"), newest: release("v1.12.10"))
            == .unreleased(installed: "1.13.0", release: "v1.12.10"))
        // 1.13 and 1.13.0 are the same version.
        #expect(InstalledAppCheck.compare(installed: installed("1.13", channel: "release"), newest: release("v1.13.0"))
            == .current(release: "v1.13.0"))
    }

    @Test func theSameVersionIsCurrentOnlyWhenTheAppSaysItWasBuiltFromTheTag() {
        #expect(InstalledAppCheck.compare(installed: installed("1.13.0", channel: "release"), newest: release("v1.13.0"))
            == .current(release: "v1.13.0"))
        // KhayatYar's real Info.plist records neither: same version, never "current", never green.
        let unrecorded = InstalledAppCheck.compare(installed: installed("1.13.0", build: "1.13.0"), newest: release("v1.13.0"))
        #expect(unrecorded == .sameVersion(release: "v1.13.0"))
        #expect(!unrecorded.needsOwner)
    }

    @Test func aTestBuildOfTheSameVersionIsATestBuild() {
        let channel = InstalledAppCheck.compare(installed: installed("1.13.0", channel: "test build"), newest: release("v1.13.0"))
        guard case .testBuild(let v, let r, let why) = channel else { Issue.record("not a test build: \(channel)"); return }
        #expect(v == "1.13.0" && r == "v1.13.0")
        #expect(why.contains("test build"))
        #expect(channel.needsOwner)

        // Built from another commit than the tag's (dba44af, the 2026-11-03 build, against v1.13.0's e7ed4e6).
        let commit = InstalledAppCheck.compare(installed: installed("1.13.0", commit: "dba44af"),
                                               newest: release("v1.13.0", commit: "e7ed4e6076d7b624a83929c20a7643d1ef14b055"))
        guard case .testBuild(_, _, let because) = commit else { Issue.record("not a test build: \(commit)"); return }
        #expect(because.contains("dba44af") && because.contains("e7ed4e6"))

        // The tag's own commit is the release, even with no channel recorded.
        #expect(InstalledAppCheck.compare(installed: installed("1.13.0", commit: "E7ED4E6"),
                                          newest: release("v1.13.0", commit: "e7ed4e6076d7b624a83929c20a7643d1ef14b055"))
            == .current(release: "v1.13.0"))
        // A channel that says release but a commit that isn't the tag's: the commit wins.
        #expect(InstalledAppCheck.compare(installed: installed("1.13.0", channel: "release", commit: "dba44af"),
                                          newest: release("v1.13.0", commit: "e7ed4e6"))
            .needsOwner)
    }

    @Test func aCommitThatIsNotACommitSaysNothing() {
        // KhayatYar writes "local" when git was missing at build time.
        #expect(InstalledAppCheck.compare(installed: installed("1.13.0", commit: "local"), newest: release("v1.13.0", commit: "e7ed4e6"))
            == .sameVersion(release: "v1.13.0"))
        #expect(InstalledAppCheck.commit("abc") == nil)
        #expect(InstalledAppCheck.commit(" DBA44AF ") == "dba44af")
    }

    @Test func newerThanEveryReleaseOrNoReleaseIsUnreleased() {
        #expect(InstalledAppCheck.compare(installed: installed("1.14.0"), newest: release("v1.13.0"))
            == .unreleased(installed: "1.14.0", release: "v1.13.0"))
        let none: Sourced<ReleaseMark> = .none("aminullah-dev/LinumicOS has no release and no version tag.", source: "GitHub", readAt: readAt)
        let linumicOS = InstalledAppCheck.compare(installed: installed("0.3.0", build: "3", bundleID: "com.linumic.commandcenter"), newest: none)
        #expect(linumicOS == .unreleased(installed: "0.3.0", release: nil))
        #expect(!linumicOS.needsOwner)
    }

    @Test func missingDataStaysUnknown() {
        // The app was not read.
        #expect(InstalledAppCheck.compare(installed: .unknown("not read"), newest: release("v1.13.0")) == .unknown("not read"))
        // No version in the Info.plist, or one that is not a number.
        guard case .unknown = InstalledAppCheck.compare(installed: installed(nil), newest: release("v1.13.0")) else {
            Issue.record("a missing version was compared"); return
        }
        guard case .unknown = InstalledAppCheck.compare(installed: installed("1.13.0-beta"), newest: release("v1.13.0")) else {
            Issue.record("a version that is not a number was compared"); return
        }
        // The release was not read.
        #expect(InstalledAppCheck.compare(installed: installed("1.12.1"), newest: .unknown("tags not read")) == .unknown("tags not read"))
        // Not installed is a fact of its own, not unknown and not a problem.
        let absent = InstalledAppCheck.compare(installed: .none("Not installed", source: "/Applications", readAt: readAt), newest: release("v1.13.0"))
        #expect(absent == .notInstalled && !absent.needsOwner)
    }

    @Test func withoutTheTagsOnlyBehindCanBeTold() {
        // Only releases/latest was read (a cache from before the tags were read): v1.12.1 there, and a newer tag may exist.
        #expect(InstalledAppCheck.compare(installed: installed("1.12.0"), newest: release("v1.12.1", kind: .release, complete: false))
            == .behind(installed: "1.12.0", release: "v1.12.1", testBuild: false))
        guard case .unknown = InstalledAppCheck.compare(installed: installed("1.12.1", channel: "release"),
                                                         newest: release("v1.12.1", kind: .release, complete: false)) else {
            Issue.record("called current without the tags"); return
        }
        guard case .unknown = InstalledAppCheck.compare(installed: installed("1.13.0"), newest: release("v1.12.1", kind: .release, complete: false)) else {
            Issue.record("called unreleased without the tags"); return
        }
    }

    @Test func everyVerdictHasATitleAndASentence() {
        let all: [InstalledVerdict] = [
            .current(release: "v1"), .sameVersion(release: "v1"), .behind(installed: "1", release: "v2", testBuild: false),
            .behind(installed: "1", release: "v2", testBuild: true), .testBuild(installed: "1", release: "v1", why: "w"),
            .unreleased(installed: "2", release: "v1"), .unreleased(installed: "2", release: nil), .notInstalled, .unknown("why"),
        ]
        for v in all {
            #expect(!v.title.isEmpty && !v.sentence.isEmpty)
        }
        #expect(all.filter(\.needsOwner).count == 3)
    }
}

@Suite("Installed on this Mac: the newest release")
struct NewestReleaseTests {
    @Test func theNewestVersionTagBeatsAnOlderPublishedRelease() throws {
        // KhayatYar on 2026-11-04: the latest GitHub release was v1.12.1, the tags reach v1.13.0.
        let tags = try ReleaseCenterParser.gitHubVersionTags(try fixture("release-gh-tags-afghanjama"), slug: repo.slug)
        #expect(tags.tagCount == 6)
        #expect(tags.newest?.tag == "v1.13.0")
        #expect(tags.newest?.commit == "e7ed4e6076d7b624a83929c20a7643d1ef14b055")
        let status = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: GitHubReleaseRef(kind: .release, tag: "v1.12.1"),
                                       lastReleaseRead: true, versionTags: tags, fetchedAt: readAt)
        let newest = InstalledAppCheck.newestRelease(of: "aminullah-dev/afghanjama", in: ReleaseCenterSnapshot(repos: [status]))
        let mark = try #require(newest.value)
        #expect(mark.tag == "v1.13.0" && mark.kind == .tag && mark.complete)
        #expect(newest.readAt == readAt)
        #expect(newest.source?.contains("tags") == true)
    }

    @Test func aReleaseAndATagOfTheSameVersionAreTheReleaseWithTheTagsCommit() throws {
        let tags = VersionTagsReading(newest: GitHubReleaseRef(kind: .tag, tag: "v0.2.0", commit: "0123456789abcdef"), tagCount: 1)
        let status = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: GitHubReleaseRef(kind: .release, tag: "v0.2.0"),
                                       lastReleaseRead: true, versionTags: tags, fetchedAt: readAt)
        let mark = try #require(InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot(repos: [status])).value)
        #expect(mark.kind == .release && mark.commit == "0123456789abcdef")
    }

    @Test func tagsThatAreNotVersionsAreNeverReleases() throws {
        // Synthetic: SafeBeauty-style names and a release candidate.
        let data = Data(#"[{"name":"salon-desktop","commit":{"sha":"a"}},{"name":"v1.14.0-rc1","commit":{"sha":"b"}},{"name":"android-app","commit":{"sha":"c"}}]"#.utf8)
        let tags = try ReleaseCenterParser.gitHubVersionTags(data, slug: repo.slug)
        #expect(tags.newest == nil && tags.tagCount == 3)
        let status = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: GitHubReleaseRef(kind: .tag, tag: "salon-desktop"),
                                       lastReleaseRead: true, versionTags: tags, fetchedAt: readAt)
        guard case .none = InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot(repos: [status])) else {
            Issue.record("a name that is not a version became a release"); return
        }
    }

    @Test func notReadIsUnknownAndSaysWhy() {
        guard case .unknown = InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot()) else {
            Issue.record("an unread repository has a release"); return
        }
        let failed = RepoReleaseStatus(repo: repo, defaultBranch: nil, fetchedAt: readAt, error: "Bad credentials")
        guard case .unknown(let why) = InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot(repos: [failed])) else {
            Issue.record("a failed read has a release"); return
        }
        #expect(why.contains("Bad credentials"))
        // A reading from before the tags were read, with no release: not "none", unknown.
        let old = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: nil, lastReleaseRead: true, fetchedAt: readAt)
        guard case .unknown = InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot(repos: [old])) else {
            Issue.record("no tags read became no release"); return
        }
        // And with a release: known, but incomplete.
        let withRelease = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: GitHubReleaseRef(kind: .release, tag: "v1.12.1"),
                                            lastReleaseRead: true, fetchedAt: readAt)
        #expect(InstalledAppCheck.newestRelease(of: repo.slug, in: ReleaseCenterSnapshot(repos: [withRelease])).value?.complete == false)
    }

    @Test func aCachedReadingFromBeforeTheTagsStillDecodes() throws {
        // `release-center.json` written before 2026-11-04 has no versionTags and no commit.
        let old = RepoReleaseStatus(repo: repo, defaultBranch: "main", lastRelease: GitHubReleaseRef(kind: .release, tag: "v1.12.1"),
                                    lastReleaseRead: true, fetchedAt: readAt)
        var json = try #require(try JSONSerialization.jsonObject(with: InventoryCoding.encoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "versionTags")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try InventoryCoding.decoder().decode(RepoReleaseStatus.self, from: data)
        #expect(decoded.versionTags == nil && decoded.lastRelease?.commit == nil)
    }
}

@Suite("Installed on this Mac: reading /Applications")
struct InstalledAppReaderTests {
    @Test func readsOnlyTheInfoPlist() throws {
        let fs = FakeApplications(names: ["KhayatYar.app", "Safari.app"], files: [
            khayatYar.infoPlistPath: try plist(["CFBundleIdentifier": "com.afghanjama.khayatyar", "CFBundleShortVersionString": "1.13.0",
                                                "CFBundleVersion": "1.13.0", "CFBundleName": "KhayatYar"]),
        ])
        let read = InstalledAppReader.read([khayatYar], using: fs, now: readAt)
        let info = try #require(read[khayatYar.id]?.value)
        #expect(info.version == "1.13.0" && info.channel == nil && info.commit == nil)
        #expect(info.label == "1.13.0")
        #expect(read[khayatYar.id]?.source == "/Applications/KhayatYar.app/Contents/Info.plist")
    }

    @Test func theChannelAndCommitAreReadWhenTheAppRecordsThem() throws {
        let fs = FakeApplications(names: ["KhayatYar.app"], files: [
            khayatYar.infoPlistPath: try plist(["CFBundleIdentifier": "com.afghanjama.khayatyar", "CFBundleShortVersionString": "1.12.1",
                                                "CFBundleVersion": "16", "LinumicBuildChannel": "test build", "LinumicBuildCommit": "dba44af"]),
        ])
        let info = try #require(InstalledAppReader.read([khayatYar], using: fs, now: readAt)[khayatYar.id]?.value)
        #expect(info.channel == "test build" && info.commit == "dba44af")
        #expect(info.label == "1.12.1 (16)")
    }

    @Test func notInstalledOnlyWhenTheFolderWasListed() {
        let listed = InstalledAppReader.read([khayatYar], using: FakeApplications(names: ["Safari.app"]), now: readAt)
        guard case .none? = listed[khayatYar.id] else { Issue.record("absent app is not 'not installed'"); return }
        // /Applications could not be listed: never "not installed".
        let refused = InstalledAppReader.read([khayatYar], using: FakeApplications(names: nil), now: readAt)
        guard case .unknown = refused[khayatYar.id] else { Issue.record("an unlisted folder became 'not installed'"); return }
    }

    @Test func anUnreadableOrForeignInfoPlistIsUnknown() throws {
        let broken = InstalledAppReader.read([khayatYar], using: FakeApplications(names: ["KhayatYar.app"]), now: readAt)
        guard case .unknown = broken[khayatYar.id] else { Issue.record("an unread Info.plist was used"); return }
        let garbage = FakeApplications(names: ["KhayatYar.app"], files: [khayatYar.infoPlistPath: Data("not a plist".utf8)])
        guard case .unknown = InstalledAppReader.read([khayatYar], using: garbage, now: readAt)[khayatYar.id] else {
            Issue.record("a broken Info.plist was used"); return
        }
        let other = FakeApplications(names: ["KhayatYar.app"], files: [
            khayatYar.infoPlistPath: try plist(["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "9.9.9"]),
        ])
        guard case .unknown(let why) = InstalledAppReader.read([khayatYar], using: other, now: readAt)[khayatYar.id] else {
            Issue.record("another app's version was compared"); return
        }
        #expect(why.contains("com.example.other"))
    }

    @Test func aSpecThatWasNotReadIsUnknown() {
        let statuses = InstalledAppCheck.statuses([khayatYar], installed: [:], releases: ReleaseCenterSnapshot())
        guard case .unknown = statuses.first?.verdict else { Issue.record("an unread app has a verdict"); return }
    }

    @Test func theCatalogPointsAtRealProductsAndPlatforms() {
        let slots = Set(ProductsCatalog.products.flatMap(\.slots).map(\.id))
        for spec in InstalledAppCatalog.apps {
            #expect(slots.contains(spec.slotID), "\(spec.slotID) is not a platform of the products catalog")
            #expect(ProductsCatalog.product(spec.productID) != nil)
            #expect(spec.bundleName.hasSuffix(".app") && !spec.bundleName.contains("/"))
            #expect(!spec.source.isEmpty)
        }
        #expect(Set(InstalledAppCatalog.apps.map(\.id)).count == InstalledAppCatalog.apps.count)
        #expect(InstalledAppCatalog.apps.contains { $0.bundleID == "com.afghanjama.khayatyar" })
        #expect(InstalledAppCatalog.apps.contains { $0.bundleID == "com.linumic.commandcenter" })
    }
}

@Suite("Installed on this Mac: the Center")
struct InstalledCenterTests {
    private func status(_ verdict: InstalledVerdict) -> InstalledAppStatus {
        InstalledAppStatus(spec: khayatYar, installed: installed("1.12.1"), newest: release("v1.13.0"), verdict: verdict)
    }

    private var emptyDesk: Desk {
        Desk(generatedAt: readAt, today: [], thisWeek: [], later: [], markedNotTicked: [], hidden: [], sources: [], obsoleteMarks: [])
    }

    @Test func onlyBehindAndTestBuildsReachTheCenter() {
        let all = [status(.behind(installed: "1.12.1", release: "v1.13.0", testBuild: false)), status(.sameVersion(release: "v1.13.0")),
                   status(.notInstalled), status(.unknown("not read")), status(.unreleased(installed: "0.3.0", release: nil)),
                   status(.testBuild(installed: "1.13.0", release: "v1.13.0", why: "w"))]
        let report = CenterBuilder.build(desk: emptyDesk, products: ProductsReport(cards: [], generatedAt: readAt, nothingRead: false), installed: all)
        #expect(report.installedAttention.map(\.verdict) == [all[0].verdict, all[5].verdict])
        #expect(!report.isAllClear(staleSources: 0), "an app behind its release is not all clear")
        let calm = CenterBuilder.build(desk: emptyDesk, products: ProductsReport(cards: [], generatedAt: readAt, nothingRead: false),
                                       installed: [all[1], all[2], all[3], all[4]])
        #expect(calm.installedAttention.isEmpty && calm.isAllClear(staleSources: 0))
    }

    @Test func theLineNamesTheAppAndTheRelease() {
        #expect(status(.behind(installed: "1.12.1", release: "v1.13.0", testBuild: false)).centerLine == "KhayatYar on this Mac is 1.12.1, behind v1.13.0")
        #expect(status(.behind(installed: "1.12.1", release: "v1.13.0", testBuild: true)).centerLine.contains("test build"))
        #expect(status(.testBuild(installed: "1.13.0", release: "v1.13.0", why: "w")).centerLine == "KhayatYar on this Mac is a test build of v1.13.0")
    }
}
