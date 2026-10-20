import Foundation
import Testing
@testable import LinumicCore

// The "platforms not level" rule, with versions and days shaped like the owner's own (KhayatYar on 2026-10-20: every
// build said 1.9.0 but each was made on a different day, and main had moved on).

private var readAt: Date { ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")! }

private func day(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso + "T09:00:00Z")! }

private func v(_ name: String, code: String? = nil, on: String? = nil) -> Sourced<VersionStamp> {
    .known(VersionStamp(name: name, code: code, date: on.map(day)), source: "fixture", readAt: readAt)
}

private let notInStore: Sourced<VersionStamp> = .none("Not in a store.", source: nil, readAt: nil)
private let noDate: Sourced<BehindMain> = .none("Google Play gives no date for this build.", source: nil, readAt: nil)

private func behind(_ commits: Int, days: Int, atLeast: Bool = false) -> Sourced<BehindMain> {
    .known(BehindMain(commits: commits, atLeast: atLeast, days: days, newestCommit: readAt), source: "fixture", readAt: readAt)
}

private func slot(_ platform: Platform, compared: Bool = true) -> ProductSlot {
    ProductSlot(id: "p.app.\(platform.rawValue)", platform: platform, label: "app", build: .store, compared: compared, source: "fixture")
}

private func reading(_ platform: Platform, live: Sourced<VersionStamp> = notInStore, build: Sourced<VersionStamp>,
                     main: Sourced<VersionStamp>, behind: Sourced<BehindMain> = noDate, compared: Bool = true) -> SlotReading {
    SlotReading(slot: slot(platform, compared: compared), live: live, build: build, main: main, behind: behind)
}

private func track(_ title: String, _ slots: [SlotReading]) -> [TrackReading] {
    [TrackReading(track: ProductTrack(id: "app", title: title, slots: slots.map(\.slot)), slots: slots)]
}

private func track(_ slots: [SlotReading]) -> [TrackReading] { track("KhayatYar", slots) }

@Suite("Products: platforms level or not")
struct ProductsLevelTests {
    @Test func allBuildsSayTheSameVersionButMainMovedOn() {
        // The owner's KhayatYar: Android 1.9.0 built 10-13, macOS 1.9.0 built 10-15, main says 1.9.1.
        let state = ProductLevelRule.evaluate(track([
            reading(.android, build: v("1.9.0", on: "2026-10-13"), main: v("1.9.1", code: "15"), behind: behind(6, days: 7)),
            reading(.macOS, build: v("1.9.0", on: "2026-10-15"), main: v("1.9.1", code: "15"), behind: behind(4, days: 5)),
        ]))
        let texts = state.findings.map(\.text)
        #expect(texts.contains("Android 1.9.0 (2026-10-13) behind main 1.9.1 (15) by 6 commits, 7 days"))
        #expect(texts.contains("macOS 1.9.0 (2026-10-15) behind main 1.9.1 (15)"), "behind by version; 5 days is not yet behind by age")
        #expect(!state.findings.contains { $0.kind == .buildsDiffer }, "the same version name is not a difference")
    }

    @Test func theExampleSentence() {
        let state = ProductLevelRule.evaluate(track([
            reading(.android, build: v("1.9.0", on: "2026-10-13"), main: v("1.9.1"), behind: behind(2, days: 1)),
        ]))
        #expect(state.findings.map(\.text) == ["Android 1.9.0 (2026-10-13) behind main 1.9.1"])
    }

    @Test func sameVersionBuiltDaysApartIsBehindByCommits() {
        // iOS 1.9.0 was made on 10-09; main has 14 commits after it and its newest is 11 days later.
        let state = ProductLevelRule.evaluate(track([
            reading(.android, build: v("1.9.0", on: "2026-10-18"), main: v("1.9.0"), behind: behind(3, days: 2)),
            reading(.iOS, build: v("1.9.0", code: "12", on: "2026-10-09"), main: v("1.9.0"), behind: behind(14, days: 11)),
        ]))
        #expect(state.findings.map(\.text) == ["iOS 1.9.0 (12) (2026-10-09) behind main by 14 commits, 11 days"])
        #expect(state.findings.first?.kind == .behindMain)
    }

    @Test func aWeekIsTheLine() {
        func state(_ days: Int) -> ProductLevelState {
            ProductLevelRule.evaluate(track([reading(.android, build: v("2.1.5", on: "2026-10-01"), main: v("2.1.5"), behind: behind(9, days: days))]))
        }
        #expect(state(6) == .level)
        #expect(!state(7).findings.isEmpty)
        #expect(ProductLevelRule.behindDays == 7)
        // No commit after the build: never behind, however old.
        #expect(ProductLevelRule.evaluate(track([reading(.android, build: v("2.1.5", on: "2026-09-01"), main: v("2.1.5"), behind: behind(0, days: 0))])) == .level)
    }

    @Test func differentVersionsOnTwoPlatforms() {
        // VELRO Ride: Android 1.4.0 (11) in production, iOS 1.3.0 waiting for review and 1.2.1 live.
        let state = ProductLevelRule.evaluate(track("VELRO Ride", [
            reading(.android, live: v("1.4.0", code: "11"), build: v("1.4.0", code: "11"), main: v("1.4.0", code: "11")),
            reading(.iOS, live: v("1.2.1", code: "7"), build: v("1.3.0", code: "9", on: "2026-10-17"), main: v("1.4.0", code: "9"),
                    behind: behind(5, days: 3)),
        ]))
        let byKind = Dictionary(grouping: state.findings, by: \.kind)
        #expect(byKind[.buildsDiffer]?.map(\.text) == ["Built versions differ: Android 1.4.0 (11), iOS 1.3.0 (9) (2026-10-17)"])
        #expect(byKind[.liveDiffer]?.map(\.text) == ["Live versions differ: Android 1.4.0 (11), iOS 1.2.1 (7)"])
        #expect(byKind[.behindMain]?.map(\.text) == ["iOS 1.3.0 (9) (2026-10-17) behind main 1.4.0 (9)"])
        #expect(state.findings.allSatisfy { $0.track == "VELRO Ride" })
    }

    @Test func buildNumbersArePerPlatform() {
        // WorkTrack 1.3.0 is build 6 on Android and build 4 on iOS: the same version, level.
        let state = ProductLevelRule.evaluate(track("WorkTrack", [
            reading(.android, live: v("1.3.0", code: "6"), build: v("1.3.0", code: "6"), main: v("1.3.0", code: "6")),
            reading(.iOS, live: v("1.3.0", code: "4"), build: v("1.3.0", code: "4", on: "2026-10-18"), main: v("1.3.0", code: "4"),
                    behind: behind(3, days: 2)),
        ]))
        #expect(state == .level)
    }

    @Test func aTagThatIsNoVersionIsNeverCompared() {
        let state = ProductLevelRule.evaluate(track([
            reading(.macOS, build: v("salon-desktop", on: "2026-07-16"), main: .none("No version file.", source: nil, readAt: nil)),
            reading(.windows, build: v("1.0.0", on: "2026-07-16"), main: .none("No version file.", source: nil, readAt: nil)),
        ]))
        #expect(state == .level, "one real version is nothing to compare")
    }

    @Test func aPlatformWithNoBuildWhileAnotherHasOne() {
        // MediFlow: the Windows ZIP of v0.2.0, nothing for the Mac.
        let state = ProductLevelRule.evaluate(track("MediFlow", [
            reading(.windows, build: v("0.2.0", on: "2026-08-27"), main: v("0.2.0")),
            reading(.macOS, build: .none("None of the last 1 GitHub releases of aminullah-dev/MediFlow has a mac .dmg / .pkg / .zip file.",
                                         source: "GitHub releases of aminullah-dev/MediFlow", readAt: readAt), main: v("0.2.0")),
        ]))
        #expect(state.findings.map(\.text) == [
            "macOS has no build (None of the last 1 GitHub releases of aminullah-dev/MediFlow has a mac .dmg / .pkg / .zip file.), while Windows 0.2.0 (2026-08-27)",
        ])
    }

    @Test func unknownIsNeverLevel() {
        let state = ProductLevelRule.evaluate(track("NerkhTimes", [
            reading(.android, live: v("1.0.11"), build: v("1.0.11", code: "12"), main: v("1.0.11", code: "12")),
            reading(.iOS, live: .unknown("No App Store Connect key. Add it in Settings → Integrations."),
                    build: .unknown("No App Store Connect key. Add it in Settings → Integrations."), main: v("1.0.11")),
        ]))
        #expect(state.unknowns == [
            "iOS build: No App Store Connect key. Add it in Settings → Integrations.",
            "iOS in the store: No App Store Connect key. Add it in Settings → Integrations.",
        ])
    }

    @Test func aFindingIsNotHiddenByAnUnknown() {
        let state = ProductLevelRule.evaluate(track([
            reading(.android, build: v("1.8.0", on: "2026-09-20"), main: v("1.9.0", code: "14"), behind: behind(100, days: 30, atLeast: true)),
            reading(.iOS, build: .unknown("No App Store listing for com.afghanjama.khayatyar in the inventory, so its builds are not read."),
                    main: .none("iosApp/project.yml on main sets no MARKETING_VERSION.", source: nil, readAt: nil)),
        ]))
        #expect(state.findings.map(\.text) == ["Android 1.8.0 (2026-09-20) behind main 1.9.0 (14) by at least 100 commits, 30 days"])
    }

    @Test func aStoreRecordIsShownButNotCompared() {
        // The console was not read: the live versions are the inventory's record of 2026-09-23 and may lag behind the store.
        func record(_ name: String) -> Sourced<VersionStamp> {
            .known(VersionStamp(name: name, detail: "From the inventory's store listing", unreadReason: "No Google Play service account."),
                   source: "https://play.google.com/store/apps/details?id=com.security.stealthapp", readAt: day("2026-09-23"))
        }
        let state = ProductLevelRule.evaluate(track("SafeBeauty", [
            reading(.android, live: record("2.1.5"), build: v("2.1.5", code: "22"), main: v("2.1.5", code: "22")),
            reading(.iOS, live: record("1.0.1"), build: v("1.0.2", code: "9", on: "2026-10-09"), main: v("1.0.2", code: "9"), behind: behind(2, days: 1)),
        ]))
        #expect(!state.findings.contains { $0.kind == .liveDiffer }, "a record is not compared")
        #expect(state.findings.map(\.text) == ["Built versions differ: Android 2.1.5 (22), iOS 1.0.2 (9) (2026-10-09)"])
        #expect(ProductLevelRule.evaluate(track([reading(.android, live: record("1.0"), build: .unknown("No key."), main: v("1.3.0"))])).unknowns
                == ["Android build: No key.", "Android in the store: No Google Play service account."], "never behind main on a record")
    }

    @Test func partsThatAreNotComparedDontCount() {
        let state = ProductLevelRule.evaluate([
            TrackReading(track: ProductTrack(id: "app", title: "WorkTrack", slots: []), slots: [
                reading(.android, build: v("1.3.0", code: "6"), main: v("1.3.0", code: "6")),
            ]),
            TrackReading(track: ProductTrack(id: "web", title: "Console and server", slots: []), slots: [
                reading(.web, build: .unknown("The deployed version is not published."), main: .unknown("x"), compared: false),
            ]),
        ])
        #expect(state == .level)
    }

    @Test func nothingShipped() {
        // DukanPro: no store listing and no GitHub release on any platform.
        let none: Sourced<VersionStamp> = .none("aminullah-dev/DukanPro has no GitHub release.", source: "GitHub releases", readAt: readAt)
        let state = ProductLevelRule.evaluate(track("DukanPro", [
            reading(.android, build: none, main: v("1.0.0", code: "1")),
            reading(.iOS, build: none, main: v("1.0.0", code: "1")),
        ]))
        #expect(state == .nothingShipped)
    }

    @Test func theFactKeyIgnoresWhatMovesDaily() {
        func key(_ commits: Int, _ days: Int) -> String? {
            ProductLevelRule.evaluate(track([reading(.android, build: v("1.8.0", on: "2026-09-20"), main: v("1.9.0"), behind: behind(commits, days: days))]))
                .findings.first?.key
        }
        #expect(key(40, 25) == key(55, 30), "more commits on main is the same fact")
        #expect(key(40, 25) != nil)
    }
}
