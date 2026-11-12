import Foundation
import Testing
@testable import LinumicCore

// The operational readiness scorecard: each check's states from fixtures shaped like the owner's products on
// 2026-11-12, and the rule that matters most: what was not read is Unknown, never passed, never "ready".

private let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
private let utc = Calendar.utc

private func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
private func at(_ day: String) -> Date { ISO8601DateFormatter().date(from: day + "T09:00:00Z")! }
private func day(_ s: String) -> KeyDay { KeyDay(s)! }

private func known<T>(_ value: T, readAt: Date? = ago(minutes: 5)) -> Sourced<T> { .known(value, source: "fixture", readAt: readAt) }

private func slot(_ platform: Platform, compared: Bool = false) -> ProductSlot {
    ProductSlot(id: "p.\(platform.rawValue)", platform: platform, label: "part", build: .store, compared: compared, source: "fixture")
}

private func card(_ id: String = "worktrack", title: String = "WorkTrack", platforms: [Platform] = [.android, .iOS],
                  level: ProductLevelState = .level, pulls: Sourced<PullSummary> = .unknown("Pull requests not read."),
                  ci: Sourced<CISummary> = .unknown("CI not read."), health: Sourced<HealthSummary> = .unknown("Not checked yet."),
                  licence: LicenceProduct? = nil) -> ProductCard {
    let slots = platforms.map { slot($0) }
    let tracks = slots.isEmpty ? [] : [ProductTrack(id: "app", title: title, slots: slots)]
    let product = CompanyProduct(id: id, title: title, inventoryID: nil, licence: licence, tracks: tracks, source: "fixture")
    return ProductCard(product: product, tracks: [], level: level, repos: [], pulls: pulls, ci: ci, licences: nil, health: health, readAt: nil)
}

private func input(_ cards: [ProductCard], ledgers: [DeskSourceStatus] = [], keys: KeysRegistry? = nil, keyResults: [String: KeyCheckResult] = [:],
                   obligations: ObligationsRegister? = nil, continuity: ContinuityLog? = nil, installed: [InstalledAppStatus]? = nil,
                   at time: Date = now) -> ReadinessInput {
    ReadinessInput(now: time, calendar: utc, cards: cards, ledgers: ledgers, keys: keys, keyResults: keyResults, obligations: obligations,
                   continuity: continuity, installed: installed)
}

private func check(_ id: ReadinessCheckID, _ card: ProductCard, ledgers: [DeskSourceStatus] = [], keys: KeysRegistry? = nil,
                   keyResults: [String: KeyCheckResult] = [:], obligations: ObligationsRegister? = nil, continuity: ContinuityLog? = nil,
                   installed: [InstalledAppStatus]? = nil) -> ReadinessResult {
    ReadinessBuilder.build(input([card], ledgers: ledgers, keys: keys, keyResults: keyResults, obligations: obligations,
                                 continuity: continuity, installed: installed))[0].result(id)!
}

private func pull(_ number: Int, opened: String?, draft: Bool = false) -> ProductPull {
    ProductPull(repo: "aminullah-dev/WorkTrack",
                pull: GitHubPullInfo(number: number, title: "PR \(number)", base: "main", head: "b\(number)", headSHA: "s", isDraft: draft,
                                     url: URL(string: "https://github.com/aminullah-dev/WorkTrack/pull/\(number)")!, createdAt: opened.map(at)))
}

private func pulls(_ list: [ProductPull], open: Int? = nil) -> PullSummary {
    PullSummary(open: open ?? list.count, drafts: list.count { $0.pull.isDraft }, byAgents: 0, pulls: list)
}

private func ci(passing: [String] = [], failing: [String] = [], running: [String] = [], noRuns: [String] = []) -> CISummary {
    CISummary(passing: passing, failing: failing, running: running, noRuns: noRuns)
}

private func ledger(_ id: String, domain: DeskDomain, _ state: DeskSourceStatus.State) -> DeskSourceStatus {
    DeskSourceStatus(source: LedgerSource(id, "Projects/Multiplatform/\(id)/PRIORITIES.md", domain), displayPath: "~/Projects/Multiplatform/\(id)/PRIORITIES.md",
                     state: state, readAt: now)
}

private func obligation(_ id: String, product: String? = "WorkTrack", due: String?, done: Bool = false) -> Obligation {
    Obligation(id: id, title: "Row \(id)", product: product, area: .other, due: due.map(day), source: "fixture.md:1", recordedOn: day("2026-10-19"),
               origin: .owner,
               completion: done ? ObligationCompletion(obligationID: id, due: due.map(day), on: day("2026-11-01"), evidence: "receipt", enteredAt: now) : nil)
}

private func register(_ rows: [Obligation], unread: [ObligationLiveSource] = []) -> ObligationsRegister {
    ObligationsRegister(obligations: rows, accounts: [], issues: [], builtAt: now, unread: unread)
}

private func export(_ name: String, outside: [String] = []) -> ContinuityExportRecord {
    ContinuityExportRecord(fileName: name, folder: "USB", folderKind: .external, createdAt: at("2026-10-19"), verifiedAt: at("2026-10-19"),
                           fileBytes: 1, fileSHA256: "a", plaintextBytes: 1, plaintextSHA256: "b", workFactor: 18, formatVersion: 1, counts: [:],
                           outsideChecks: outside.map { ContinuityOutsideCheck(on: day($0), evidence: "age -d on another PC, SHA-256 matched", enteredAt: at($0)) })
}

private func installedStatus(_ productID: String, _ verdict: InstalledVerdict) -> InstalledAppStatus {
    let spec = InstalledAppCatalog.apps.first { $0.productID == productID }!
    return InstalledAppStatus(spec: spec, installed: .known(InstalledAppInfo(bundleID: spec.bundleID, version: "1.12.1"), source: "/Applications/\(spec.bundleName)", readAt: now),
                              newest: .unknown("fixture"), verdict: verdict)
}

@Suite("Readiness: the checks")
struct ReadinessCheckTests {
    @Test func everyProductGetsTheSameChecksInTheSameOrder() {
        let all = ReadinessBuilder.build(input([card(), card("radarsystem", title: "Radar-system", platforms: [])]))
        for product in all {
            #expect(product.results.map(\.check) == ReadinessCheckID.allCases)
            #expect(product.results.allSatisfy { !$0.evidence.isEmpty && !$0.source.isEmpty }, "every result says what and where")
        }
    }

    // MARK: CI

    @Test func ciStates() {
        let repo = "aminullah-dev/WorkTrack"
        #expect(check(.ci, card(ci: known(ci(passing: [repo])))).state == .passed)
        let failing = check(.ci, card(ci: known(ci(passing: ["a/b"], failing: [repo]))))
        #expect(failing.state == .failed)
        #expect(failing.evidence == "CI is failing on the default branch of aminullah-dev/WorkTrack.")
        #expect(check(.ci, card(ci: known(ci(passing: ["a/b"], running: [repo])))).state == .unknown, "a run in progress has no result yet")
        #expect(check(.ci, card(ci: known(ci(noRuns: [repo])))).state == .needsAttention, "no CI at all can't be green")
        #expect(check(.ci, card(ci: .none("No code repository is recorded for this product.", source: nil, readAt: nil))).state == .notApplicable)
        let unread = check(.ci, card(ci: .unknown("CI of aminullah-dev/WorkTrack has not been read yet.")))
        #expect(unread.state == .unknown)
        #expect(unread.evidence == "CI of aminullah-dev/WorkTrack has not been read yet.", "unknown says which reading is missing")
        #expect(unread.date == nil)
    }

    @Test func anOldGreenReadingIsNotCountedAsPassedButAnOldFailureStays() {
        let window = ReadinessRules.releasesWindow
        #expect(window == 90 * 60, "three cadences of the Release Center job")
        let old = ago(minutes: 91)
        let green = check(.ci, card(ci: known(ci(passing: ["a/b"]), readAt: old)))
        #expect(green.state == .unknown)
        #expect(green.evidence.contains("more than 1 hours ago"))
        #expect(green.date == .read(old), "the old reading keeps its date")
        #expect(check(.ci, card(ci: known(ci(passing: ["a/b"]), readAt: ago(minutes: 89)))).state == .passed)
        #expect(check(.ci, card(ci: known(ci(failing: ["a/b"]), readAt: at("2026-11-01")))).state == .failed, "old bad news holds until a new reading clears it")
    }

    // MARK: Pull requests

    @Test func pullRequestStates() {
        #expect(check(.pullRequests, card(pulls: known(pulls([])))).state == .passed)
        // Opened 2026-10-28: 15 days before 2026-11-12, one more than the line.
        let old = check(.pullRequests, card(pulls: known(pulls([pull(88, opened: "2026-11-10"), pull(75, opened: "2026-10-28")]))))
        #expect(old.state == .needsAttention)
        #expect(old.evidence == "1 of 2 open pull requests have waited more than 14 days. The oldest is aminullah-dev/WorkTrack#75, opened 2026-10-28 (15 days ago).")
        // Exactly 14 days is not yet long.
        let line = check(.pullRequests, card(pulls: known(pulls([pull(76, opened: "2026-10-29")]))))
        #expect(line.state == .passed)
        #expect(line.evidence == "1 open, none waiting more than 14 days. The oldest is aminullah-dev/WorkTrack#76, opened 2026-10-29.")
        #expect(ReadinessRules.pullWaitingDays == 14)
    }

    @Test func aDraftDoesNotWaitOnTheOwner() {
        let drafts = check(.pullRequests, card(pulls: known(pulls([pull(1, opened: "2026-09-01", draft: true)]))))
        #expect(drafts.state == .passed)
        #expect(drafts.evidence == "1 open, all drafts: none waits for a merge.")
    }

    @Test func aCountWithoutDatesIsUnknownNotPassed() {
        // The Platforms hub read a count only: 3 open, none listed.
        let counted = check(.pullRequests, card(pulls: known(pulls([], open: 3))))
        #expect(counted.state == .unknown)
        #expect(counted.evidence.hasPrefix("3 open."))
        // GitHub gave no opening day.
        #expect(check(.pullRequests, card(pulls: known(pulls([pull(5, opened: nil)])))).state == .unknown)
        // A known old one is still said, whatever else is missing.
        #expect(check(.pullRequests, card(pulls: known(pulls([pull(5, opened: "2026-09-01")], open: 4)))).state == .needsAttention)
        #expect(check(.pullRequests, card(pulls: .unknown("The Release Center does not watch x/y, so its pull requests are not read."))).state == .unknown)
        #expect(check(.pullRequests, card(pulls: .none("No code repository is recorded for this product.", source: nil, readAt: nil))).state == .notApplicable)
        #expect(check(.pullRequests, card(pulls: known(pulls([]), readAt: at("2026-11-10")))).state == .unknown, "an old 'none open' is not today's")
    }

    // MARK: Level

    @Test func levelStates() {
        #expect(check(.level, card(level: .level)).state == .passed)
        let finding = LevelFinding(kind: .behindMain, track: "WorkTrack", text: "Android 1.9.0 behind main 1.9.1", key: "k1")
        let other = LevelFinding(kind: .buildsDiffer, track: "WorkTrack", text: "Built versions differ", key: "k2")
        let notLevel = check(.level, card(level: .notLevel([finding, other])))
        #expect(notLevel.state == .needsAttention)
        #expect(notLevel.evidence == "Android 1.9.0 behind main 1.9.1 (and 1 more)")
        let unknown = check(.level, card(level: .unknown(["iOS build: no key"])))
        #expect(unknown.state == .unknown)
        #expect(unknown.evidence == "Not read, so not known: iOS build: no key")
        #expect(check(.level, card(level: .nothingShipped)).state == .notApplicable)
    }

    @Test func noPlatformComparedIsNeverPassed() {
        // BE-PAYA on 2026-11-12: iOS and Android listed, nothing of them read.
        #expect(check(.level, card("bepaya", title: "BE-PAYA", platforms: [.iOS, .android], level: .nothingCompared)).state == .unknown)
        // Radar-system: no platform at all. A web-only project has no app to level either.
        #expect(check(.level, card("radarsystem", title: "Radar-system", platforms: [], level: .nothingCompared)).state == .notApplicable)
        #expect(check(.level, card("site", title: "Site", platforms: [.web], level: .nothingCompared)).state == .notApplicable)
    }

    // MARK: Monitoring

    @Test func monitoringStates() {
        func health(_ up: Int, _ degraded: Int = 0, _ down: Int = 0, _ unchecked: Int = 0, readAt: Date? = ago(minutes: 5)) -> Sourced<HealthSummary> {
            known(HealthSummary(up: up, degraded: degraded, down: down, unchecked: unchecked), readAt: readAt)
        }
        let up = check(.monitoring, card(health: health(4)))
        #expect(up.state == .passed)
        #expect(up.evidence == "All 4 checks up.")
        #expect(check(.monitoring, card(health: health(3, 0, 1))).state == .failed)
        #expect(check(.monitoring, card(health: health(3, 1))).state == .needsAttention)
        #expect(check(.monitoring, card(health: health(3, 0, 0, 1))).state == .unknown, "an address not checked is not up")
        #expect(check(.monitoring, card(health: .unknown("Not checked yet. The Monitor checks when the app opens."))).state == .unknown)
        // Healthy an hour and a minute ago is not "on now"; down then is still said.
        #expect(ReadinessRules.monitorWindow == 60 * 60)
        #expect(check(.monitoring, card(health: health(4, readAt: ago(minutes: 61)))).state == .unknown)
        #expect(check(.monitoring, card(health: health(3, 0, 1, readAt: ago(minutes: 600)))).state == .failed)
    }

    @Test func nothingMonitoredIsAGapOnlyWhereSomethingIsServed() {
        let none: Sourced<HealthSummary> = .none("No public address of this product is monitored.", source: nil, readAt: nil)
        #expect(check(.monitoring, card(platforms: [.android, .backend], health: none)).state == .needsAttention)
        #expect(check(.monitoring, card(platforms: [.android, .iOS], health: none)).state == .notApplicable)
    }

    // MARK: Signing key

    private func key(_ id: String, product: String? = "WorkTrack", backups: [String], kind: KeyKind = .androidSigning, deleted: Bool = false) -> TrackedKey {
        TrackedKey(id: id, title: "Key \(id)", product: product, kind: kind, path: "~/Keys/\(id).jks", backupIDs: backups, source: "fixture",
                   recordedOn: day("2026-10-09"), deletedOn: deleted ? day("2026-10-10") : nil)
    }

    private func backup(_ id: String, made: String = "2026-11-03", tested: String?) -> BackupRecord {
        BackupRecord(id: id, title: "Backup \(id)", location: "USB", fileName: "\(id).tgz.enc", archive: .tarGzip, createdOn: day(made),
                     encryption: "AES-256-CBC", restoreTests: tested.map { [RestoreTest(on: day($0), by: "Owner", source: "fixture")] } ?? [],
                     source: "fixture", recordedOn: day(made))
    }

    @Test func signingKeyStates() {
        let covered = KeysRegistry(keys: [key("a", backups: ["b1"]), key("b", backups: ["b1", "b2"])],
                                   backups: [backup("b1", tested: "2026-11-03"), backup("b2", tested: nil)])
        let passed = check(.signingKey, card(), keys: covered)
        #expect(passed.state == .passed)
        #expect(passed.evidence == "2 keys recorded, each in a backup that was restore-tested on 2026-11-03.")
        #expect(passed.date == .day(day("2026-11-03")))

        let unbacked = KeysRegistry(keys: [key("a", backups: ["b1"]), key("b", backups: [])], backups: [backup("b1", tested: "2026-11-03")])
        let failed = check(.signingKey, card(), keys: unbacked)
        #expect(failed.state == .failed)
        #expect(failed.evidence == "1 of 2 keys are in no backup: Key b.")

        // A backup named but not in the registry is no backup.
        #expect(check(.signingKey, card(), keys: KeysRegistry(keys: [key("a", backups: ["gone"])], backups: [])).state == .failed)

        let untested = KeysRegistry(keys: [key("a", backups: ["b2"])], backups: [backup("b2", tested: nil)])
        #expect(check(.signingKey, card(), keys: untested).state == .needsAttention, "in a backup nobody has restored")

        // 2026-08-13 is 91 days before 2026-11-12.
        let stale = KeysRegistry(keys: [key("a", backups: ["b1"])], backups: [backup("b1", made: "2026-08-13", tested: "2026-08-13")])
        #expect(check(.signingKey, card(), keys: stale).state == .needsAttention)
        let edge = KeysRegistry(keys: [key("a", backups: ["b1"])], backups: [backup("b1", made: "2026-08-14", tested: "2026-08-14")])
        #expect(check(.signingKey, card(), keys: edge).state == .passed, "90 days is still within the rule")
    }

    @Test func aKeyChangedOrMissingOnThisMacNeedsALook() {
        let registry = KeysRegistry(keys: [key("a", backups: ["b1"])], backups: [backup("b1", tested: "2026-11-03")])
        let changed = KeyCheckResult(keyID: "a", status: .present([KeyFileInfo(path: "/Users/x/Keys/a.jks", size: 2742, modifiedAt: at("2026-11-08"))]))
        #expect(check(.signingKey, card(), keys: registry, keyResults: ["a": changed]).state == .needsAttention)
        #expect(check(.signingKey, card(), keys: registry, keyResults: ["a": KeyCheckResult(keyID: "a", status: .missing)]).state == .needsAttention)
        let same = KeyCheckResult(keyID: "a", status: .present([KeyFileInfo(path: "/Users/x/Keys/a.jks", size: 2742, modifiedAt: at("2026-10-01"))]))
        #expect(check(.signingKey, card(), keys: registry, keyResults: ["a": same]).state == .passed)
    }

    @Test func noKeyOnRecordIsUnknownNotPassed() {
        let others = KeysRegistry(keys: [key("v", product: "VELRO", backups: ["b1"]), key("gone", backups: ["b1"], deleted: true),
                                         key("copy", backups: [], kind: .passphraseCopy), key("asc", product: nil, backups: ["b1"])],
                                  backups: [backup("b1", tested: "2026-11-03")])
        let none = check(.signingKey, card(), keys: others)
        #expect(none.state == .unknown, "another product's key, a deleted key, a passphrase copy and a key of no product say nothing about this one")
        #expect(check(.signingKey, card("radarsystem", title: "Radar-system", platforms: []), keys: others).state == .notApplicable)
        #expect(check(.signingKey, card(), keys: nil).state == .unknown, "a registry that could not be read")
    }

    @Test func theSeedRegistryCoversTheProductsItNames() {
        // The facts recorded on 2026-11-03: every key of these products is in the signing-keys bundle, restore-tested that day.
        for (id, title) in [("worktrack", "WorkTrack"), ("velro", "VELRO"), ("safebeauty", "SafeBeauty"), ("khayatyar", "KhayatYar"), ("talar", "Talar"),
                            ("namazia", "Namazia"), ("mediflow", "MediFlow")] {
            let result = check(.signingKey, card(id, title: title), keys: .seed)
            #expect(result.state == .passed, "\(title): \(result.evidence)")
            #expect(result.date == .day(day("2026-11-03")))
        }
        // No key file of these is in the registry (NerkhTimes' and DukanPro's are recorded as gaps, not as keys).
        for (id, title) in [("nerkhtimes", "NerkhTimes"), ("dukanpro", "DukanPro"), ("linumicos", "Linumic OS")] {
            #expect(check(.signingKey, card(id, title: title), keys: .seed).state == .unknown, "\(title)")
        }
    }

    // MARK: Restore test

    @Test func restoreTestIsUnknownWhereLinumicOSHoldsNoRecord() {
        let result = check(.restoreTest, card(), continuity: ContinuityLog(exports: [export("a.json.age", outside: ["2026-11-01"])]))
        #expect(result.state == .unknown, "Linumic OS's own export says nothing about WorkTrack's database")
        #expect(result.evidence.contains("WorkTrack"))
        #expect(check(.restoreTest, card("radarsystem", title: "Radar-system", platforms: [])).state == .notApplicable)
    }

    @Test func linumicOSRestoreTestIsTheExportOpenedOutsideThisMac() {
        let os = card("linumicos", title: "Linumic OS", platforms: [.macOS, .iOS])
        #expect(check(.restoreTest, os, continuity: nil).state == .unknown, "iPhone, or continuity.json unreadable")
        #expect(check(.restoreTest, os, continuity: ContinuityLog()).state == .failed)
        #expect(check(.restoreTest, os, continuity: ContinuityLog(exports: [export("verified-only.json.age")])).state == .failed,
                "read back on this Mac is not opened outside it")
        let passed = check(.restoreTest, os, continuity: ContinuityLog(exports: [export("b.json.age", outside: ["2026-11-01"]), export("a.json.age", outside: ["2026-10-20"])]))
        #expect(passed.state == .passed)
        #expect(passed.evidence == "b.json.age was opened outside this Mac on 2026-11-01.")
        #expect(passed.date == .day(day("2026-11-01")))
        #expect(check(.restoreTest, os, continuity: ContinuityLog(exports: [export("old.json.age", outside: ["2026-08-13"])])).state == .needsAttention)
    }

    // MARK: Ledger

    @Test func ledgerReviewStates() {
        func reviewed(_ on: String?) -> [DeskSourceStatus] {
            [ledger("WorkTrack", domain: .worktrack, .read(open: 12, ticked: 3, skipped: [], reviewedOn: on.map(day))),
             ledger("Talar", domain: .talar, .read(open: 1, ticked: 0, skipped: [], reviewedOn: day("2020-01-01")))]
        }
        let fresh = check(.ledgerReview, card(), ledgers: reviewed("2026-11-05"))
        #expect(fresh.state == .passed, "exactly 7 days: not yet due")
        #expect(fresh.evidence == "Last reviewed on 2026-11-05, 7 days ago (a review is due every 7 days). 12 open items.")
        #expect(fresh.source == "~/Projects/Multiplatform/WorkTrack/PRIORITIES.md")
        #expect(fresh.date == .day(day("2026-11-05")))
        #expect(check(.ledgerReview, card(), ledgers: reviewed("2026-11-04")).state == .needsAttention)
        #expect(check(.ledgerReview, card(), ledgers: reviewed(nil)).state == .unknown, "no review day line")
        #expect(check(.ledgerReview, card(), ledgers: reviewed("2026-11-20")).evidence.contains("0 days ago"), "a day after today is not minus days")
    }

    @Test func aLedgerNotReadIsUnknown() {
        for state: DeskSourceStatus.State in [.notRead, .notGranted, .notFound, .unsupported, .unreadable("Permission denied")] {
            #expect(check(.ledgerReview, card(), ledgers: [ledger("WorkTrack", domain: .worktrack, state)]).state == .unknown)
        }
        // MediFlow has no PRIORITIES.md on the Desk's list.
        let none = check(.ledgerReview, card("mediflow", title: "MediFlow"), ledgers: [ledger("WorkTrack", domain: .worktrack, .notRead)])
        #expect(none.state == .unknown)
        #expect(none.evidence.contains("MediFlow"))
        // The NEXT-ACTIONS report is no product's ledger.
        let report = DeskSourceStatus(source: LedgerSource("next-actions", "Projects/Multiplatform", .worktrack, kind: .nextActions), displayPath: "~/x",
                                      state: .report(today: 1, thisWeek: 1, skipped: [], day: day("2026-11-12")), readAt: now)
        #expect(check(.ledgerReview, card(), ledgers: [report]).state == .unknown)
    }

    // MARK: Obligations

    @Test func obligationStatesNearestFirst() {
        let overdue = check(.obligations, card(), obligations: register([obligation("late", due: "2026-10-26"), obligation("soon", due: "2026-11-20")]))
        #expect(overdue.state == .failed)
        #expect(overdue.evidence == "2 open. Overdue by 17 days: Row late (due 2026-10-26).")
        #expect(overdue.source == "Obligations register: fixture.md:1")
        #expect(overdue.date == .day(day("2026-10-19")))

        let soon = check(.obligations, card(), obligations: register([obligation("soon", due: "2026-11-26"), obligation("far", due: "2027-02-01")]))
        #expect(soon.state == .needsAttention, "14 days is inside the window")
        #expect(soon.evidence == "2 open. Due in 14 days: Row soon (2026-11-26).")

        let far = check(.obligations, card(), obligations: register([obligation("far", due: "2026-11-27")]))
        #expect(far.state == .passed)
        #expect(far.evidence == "1 open, none due within 14 days. The nearest: Row far (2026-11-27).")

        let undated = check(.obligations, card(), obligations: register([obligation("far", due: "2027-02-01"), obligation("queue", due: nil)]))
        #expect(undated.state == .needsAttention, "a date not recorded is itself to find out")
        #expect(undated.evidence == "2 open, 1 of them with no date recorded. The first of those: Row queue.")
    }

    @Test func nothingRecordedIsNotCountedAsPassed() {
        // Another product's row, a row of no product and a closed row say nothing about WorkTrack.
        let rows = [obligation("velro", product: "VELRO", due: "2026-10-01"), obligation("company", product: nil, due: "2026-10-01"),
                    obligation("done", due: "2026-10-01", done: true)]
        let none = check(.obligations, card(), obligations: register(rows))
        #expect(none.state == .notApplicable)
        #expect(none.evidence.contains("not proof that nothing is due"))
        #expect(check(.obligations, card(), obligations: nil).state == .unknown, "obligations.json unreadable")
    }

    @Test func aLiveSourceNotReadIsUnknownForTheProductItFeeds() {
        let khayatYar = card("khayatyar", title: "KhayatYar", licence: .khayatyar)
        #expect(check(.obligations, khayatYar, obligations: register([], unread: [.licences])).state == .unknown, "its licence end dates are missing")
        #expect(check(.obligations, card(), obligations: register([], unread: [.licences])).state == .notApplicable, "WorkTrack sells no licence file")
        let os = card("linumicos", title: "Linumic OS")
        #expect(check(.obligations, os, obligations: register([], unread: [.continuity])).state == .unknown)
        // A known deadline is still said when another part is unread.
        #expect(check(.obligations, khayatYar, obligations: register([obligation("late", product: "KhayatYar", due: "2026-11-01")], unread: [.licences])).state == .failed)
    }

    // MARK: Installed on this Mac

    @Test func installedStates() {
        let khayatYar = card("khayatyar", title: "KhayatYar", platforms: [.android, .macOS])
        func state(_ verdict: InstalledVerdict) -> ReadinessState { check(.installed, khayatYar, installed: [installedStatus("khayatyar", verdict)]).state }
        #expect(state(.current(release: "v1.13.1")) == .passed)
        #expect(state(.behind(installed: "1.12.1", release: "v1.13.0", testBuild: true)) == .needsAttention)
        #expect(state(.testBuild(installed: "1.13.0", release: "v1.13.0", why: "channel dev")) == .needsAttention)
        #expect(state(.unreleased(installed: "1.14.0", release: "v1.13.1")) == .needsAttention, "newer than every release is not a release")
        #expect(state(.unreleased(installed: "0.3.0", release: nil)) == .notApplicable, "no release to compare with")
        #expect(state(.sameVersion(release: "v1.13.1")) == .unknown, "how it was built is not recorded: grey, never green")
        #expect(state(.unknown("Info.plist could not be read.")) == .unknown)
        #expect(state(.notInstalled) == .notApplicable)
        let behind = check(.installed, khayatYar, installed: [installedStatus("khayatyar", .behind(installed: "1.12.1", release: "v1.13.0", testBuild: false))])
        #expect(behind.evidence == "1.12.1 is behind the newest release, v1.13.0.")
        #expect(behind.source == "/Applications/KhayatYar.app")
    }

    @Test func installedAppliesOnlyToTheCataloguedMacApps() {
        #expect(check(.installed, card(), installed: []).state == .notApplicable, "WorkTrack has no Mac app compared with a tag")
        let khayatYar = card("khayatyar", title: "KhayatYar")
        #expect(check(.installed, khayatYar, installed: nil).state == .unknown, "iPhone and iPad can't read /Applications")
        #expect(check(.installed, khayatYar, installed: []).state == .unknown)
    }
}

@Suite("Readiness: the summary and the portfolio")
struct ReadinessSummaryTests {
    private func result(_ check: ReadinessCheckID, _ state: ReadinessState) -> ReadinessResult {
        ReadinessResult(check, state, "evidence", source: "fixture")
    }

    private func product(_ id: String, _ states: [ReadinessState]) -> ProductReadiness {
        ProductReadiness(productID: id, title: id, results: zip(ReadinessCheckID.allCases, states).map { result($0, $1) })
    }

    private func summary(_ states: [ReadinessState]) -> ReadinessSummary { product("p", states).summary }

    @Test func unknownIsNeverCountedAsPassed() {
        let s = summary([.passed, .passed, .passed, .passed, .passed, .unknown, .unknown, .unknown, .notApplicable])
        #expect(s.passed == 5)
        #expect(s.unknown == 3)
        #expect(s.applicable == 8, "not applicable is outside the denominator")
        #expect(s.known == 5)
        #expect(s.headline == "5 of 8 known · 5 passed · 3 unknown")
        #expect(s.standing == .partlyKnown, "every known check passed, but it is not called ready")
    }

    @Test func oneUnknownKeepsAProductFromReady() {
        #expect(summary([.passed, .passed, .passed, .passed, .passed, .passed, .passed, .passed, .unknown]).standing == .partlyKnown)
        #expect(summary(Array(repeating: .passed, count: 9)).standing == .ready)
        #expect(summary([.passed, .passed, .notApplicable, .notApplicable, .notApplicable, .notApplicable, .notApplicable, .notApplicable, .notApplicable]).standing == .ready)
    }

    @Test func mostlyUnknownReadsAsNotKnown() {
        let s = summary([.passed, .passed, .unknown, .unknown, .unknown, .unknown, .unknown, .notApplicable, .notApplicable])
        #expect(s.standing == .notKnown)
        #expect(s.headline == "2 of 7 known · 2 passed · 5 unknown")
        #expect(summary(Array(repeating: .unknown, count: 9)).standing == .notKnown)
        #expect(summary(Array(repeating: .unknown, count: 9)).headline == "0 of 9 known · 9 unknown")
        // Half and half is still partly known; one more unknown tips it.
        #expect(summary([.passed, .passed, .unknown, .unknown]).standing == .partlyKnown)
        #expect(summary([.passed, .passed, .unknown, .unknown, .unknown]).standing == .notKnown)
    }

    @Test func nothingApplicableIsNotReady() {
        let s = summary(Array(repeating: .notApplicable, count: 9))
        #expect(s.standing == .notKnown)
        #expect(s.headline == "No check applies")
    }

    @Test func aFailureOrALookIsSaidEvenWhenMostIsUnknown() {
        let failing = summary([.failed, .needsAttention, .passed, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown])
        #expect(failing.standing == .failing)
        #expect(failing.headline == "3 of 9 known · 1 passed · 1 failed · 1 need attention · 6 unknown")
        #expect(summary([.needsAttention, .passed, .passed]).standing == .attention)
    }

    @Test func concernsAreFailuresThenLooks() {
        let p = product("p", [.passed, .needsAttention, .failed, .unknown, .needsAttention])
        #expect(p.concerns.map(\.check) == [.level, .pullRequests, .signingKey])
    }

    @Test func nothingReadMeansNothingPassedForAnyProduct() {
        // The real catalogue, with no source read on this device and no registry, register or log loaded.
        let report = ProductsBuilder.build(ProductsInput(now: now, products: [], tracking: [], releases: ReleaseCenterSnapshot(),
                                                         licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil), monitor: MonitorSnapshot()))
        let all = ReadinessBuilder.build(input(report.cards))
        #expect(all.count == ProductsCatalog.products.count)
        for product in all {
            #expect(product.summary.passed == 0, "\(product.title): \(product.results.filter { $0.state == .passed }.map(\.check))")
            #expect(product.summary.standing != .ready && product.summary.standing != .partlyKnown, "\(product.title) reads as \(product.summary.standing)")
        }
    }

    // MARK: Portfolio

    @Test func theWeakestComesFirst() {
        let all = [
            product("ready", Array(repeating: .passed, count: 9)),
            product("partly", [.passed, .passed, .passed, .unknown]),
            product("unknown", Array(repeating: .unknown, count: 9)),
            product("look", [.needsAttention, .passed]),
            product("twoLooks", [.needsAttention, .needsAttention]),
            product("failing", [.failed, .passed]),
            product("twoFailures", [.failed, .failed, .unknown]),
        ]
        let portfolio = ReadinessBuilder.portfolio(all) { _ in .maintenance }
        #expect(portfolio.active.map(\.id) == ["twoFailures", "failing", "twoLooks", "look", "unknown", "partly", "ready"])
        #expect(portfolio.archived.isEmpty)
        #expect(portfolio.count(.failing) == 2)
        #expect(portfolio.count(.ready) == 1)
    }

    @Test func archivedProjectsNeverPushAnActiveOneDown() {
        let all = [
            product("archivedFailing", [.failed, .failed, .failed]),
            product("activeReady", Array(repeating: .passed, count: 9)),
            product("archivedUnknown", Array(repeating: .unknown, count: 9)),
            product("activeLook", [.needsAttention]),
        ]
        let portfolio = ReadinessBuilder.portfolio(all) { $0.hasPrefix("archived") ? .archived : .maintenance }
        #expect(portfolio.active.map(\.id) == ["activeLook", "activeReady"], "an archived failure is not above an active project")
        #expect(portfolio.archived.map(\.id) == ["archivedFailing", "archivedUnknown"], "weakest first among themselves")
        #expect(portfolio.count(.failing) == 0, "the counts are of the active projects")
    }

    @Test func aTieGoesToFocusThenToTheGivenOrder() {
        let all = [product("b", [.failed]), product("a", [.failed]), product("focus", [.failed])]
        let portfolio = ReadinessBuilder.portfolio(all) { $0 == "focus" ? .focus : .maintenance }
        #expect(portfolio.active.map(\.id) == ["focus", "b", "a"])
    }

    @Test func theOwnersDefaultTiersArchiveTheProjectsListedOn20261112() {
        let all = ["worktrack", "bepaya", "radarsystem", "velro"].map { product($0, [.unknown]) }
        let portfolio = ReadinessBuilder.portfolio(all)
        #expect(portfolio.active.map(\.id) == ["worktrack", "velro"])
        #expect(portfolio.archived.map(\.id) == ["bepaya", "radarsystem"])
    }
}
