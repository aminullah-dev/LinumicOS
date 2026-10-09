import Foundation
import Testing
@testable import LinumicCore

// Synthetic inputs only (plus the emulator WorkTrack fixture, see WorkTrackTests). No network.

private let now = Date(timeIntervalSince1970: 1_791_540_000) // 2026-10-09T10:00:00Z
private let hour: TimeInterval = 3600

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private struct Envelope<T: Decodable>: Decodable { let data: T }

private func companies() throws -> [WTCompany] {
    try JSONDecoder().decode(Envelope<[WTCompany]>.self, from: try fixture("worktrack-companies")).data
}

private func emptyInput(_ edit: (inout BriefInput) -> Void = { _ in }) -> BriefInput {
    var input = BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                           licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                           worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                           operations: OperationsProduct.allCases.map { BriefOperationsInput(product: $0, isSignedIn: false, counts: []) },
                           oversight: BriefOversightInput(repos: [], recentChanges: []))
    edit(&input)
    return input
}

private func target(_ id: String) -> MonitorTarget { MonitorCatalog.targets.first { $0.id == id }! }

private func licence(_ id: String, expires: String?, status: LicenceStatus = .active, created: Date = now.addingTimeInterval(-90 * 86_400)) -> LicenceRecord {
    LicenceRecord(product: .mediflow, licenceID: id, customer: "Clinic \(id)", machine: "K7Q2-9XMB-4T1D-WP3C",
                  issued: "2026-01-01", expires: expires, status: status, createdBy: "test", createdAt: created)
}

@Suite("Daily Brief")
struct DailyBriefTests {
    @Test func neverReadSourcesSayGoInsteadOfZero() {
        let brief = DailyBriefBuilder.build(emptyInput(), changes: nil)
        #expect(brief.sections.map(\.kind) == BriefSourceKind.allCases)
        for section in brief.sections {
            guard case .neverRead = section.state else {
                Issue.record("\(section.kind) should be never read")
                continue
            }
            #expect(section.lines.isEmpty)
        }
        #expect(brief.attentionCount == 0)
        #expect(Set(brief.neverRead) == Set(BriefSourceKind.allCases))
    }

    @Test func monitorDownSlowDowntimeAndExpiries() {
        let input = emptyInput { i in
            var s = MonitorSnapshot()
            s.lastRoundAt = now
            s.latest["velro.api.live"] = MonitorResult(targetID: "velro.api.live", checkedAt: now, state: .down, reason: .transport, failure: "timed out")
            s.latest["velro.admin"] = MonitorResult(targetID: "velro.admin", checkedAt: now, state: .degraded, latencyMS: 4200)
            s.latest["safebeauty.app"] = MonitorResult(targetID: "safebeauty.app", checkedAt: now, state: .up, latencyMS: 120)
            for (k, state) in [MonitorState.up, .down, .down, .up].enumerated() {
                s.history.append(MonitorResult(targetID: "safebeauty.app", checkedAt: now.addingTimeInterval(Double(k - 4) * hour), state: state), now: now)
            }
            s.certificates["safebeauty.web.app"] = CertificateReading(host: "safebeauty.web.app", notAfter: now.addingTimeInterval(20 * 86_400 + 60), readAt: now)
            s.certificates["api.velro.linumic.com"] = CertificateReading(host: "api.velro.linumic.com", notAfter: now.addingTimeInterval(90 * 86_400), readAt: now)
            s.domains["linumic.com"] = DomainReading(name: "linumic.com", expiresAt: now.addingTimeInterval(3 * 86_400 + 60), registeredAt: nil,
                                                     registrar: nil, rdapUpdatedAt: nil, sourceURL: "https://rdap.org/domain/linumic.com", fetchedAt: now)
            i.monitor = s
        }
        let section = DailyBriefBuilder.monitor(input)
        #expect(section.state == .items)
        let ids = section.lines.map(\.id)
        #expect(ids.contains("monitor.down.velro.api.live"))
        #expect(ids.contains("monitor.slow.velro.admin"))
        #expect(ids.contains("monitor.downtime.safebeauty.app"))
        #expect(ids.contains("monitor.cert.safebeauty.web.app"))
        #expect(!ids.contains("monitor.cert.api.velro.linumic.com"))   // 90 days: outside the window
        #expect(ids.contains("monitor.domain.linumic.com"))
        // Sorted by severity: the down endpoint and the 3-day domain are high and come first.
        #expect(section.lines.prefix(2).allSatisfy { $0.severity == .high })
        let down = section.lines.first { $0.id == "monitor.down.velro.api.live" }!
        #expect(down.source == "GET https://api.velro.linumic.com/healthz")
        #expect(down.readAt == now)
        #expect(down.detail == "timed out")
        let downtime = section.lines.first { $0.id == "monitor.downtime.safebeauty.app" }!
        #expect(downtime.text.contains("2 of 4"))
        #expect(section.lines.first { $0.id == "monitor.cert.safebeauty.web.app" }?.text.contains("20 days") == true)
        // Not every endpoint was checked: said, not hidden.
        #expect(section.notes.count == 1)
    }

    @Test func monitorAllClear() {
        let input = emptyInput { i in
            var s = MonitorSnapshot()
            s.lastRoundAt = now
            for t in MonitorCatalog.targets { s.latest[t.id] = MonitorResult(targetID: t.id, checkedAt: now, state: .up) }
            i.monitor = s
        }
        let section = DailyBriefBuilder.monitor(input)
        #expect(section.state == .allClear)
        #expect(section.notes.isEmpty)
        #expect(section.readAt == now)
    }

    @Test func releasesUseWaitingOnYouWithSourceAndTime() {
        let repo = ReleaseRepo(slug: "aminullah-dev/WorkTrack", productName: "WorkTrack", source: "test")
        let status = RepoReleaseStatus(repo: repo, defaultBranch: "main", mainCI: .failure,
                                       mainRuns: [GitHubWorkflowRunInfo(id: 1, name: "CI", status: "completed", conclusion: "failure")],
                                       fetchedAt: now)
        let input = emptyInput { $0.releases = ReleaseCenterSnapshot(repos: [status], gitHubReadAt: now, appStoreNote: "No App Store Connect key.") }
        let section = DailyBriefBuilder.releases(input)
        #expect(section.state == .items)
        #expect(section.lines.count == 1)
        #expect(section.lines[0].severity == .high)
        #expect(section.lines[0].text.hasPrefix("aminullah-dev/WorkTrack: CI is failing"))
        #expect(section.lines[0].source.contains("/actions/runs"))
        #expect(section.lines[0].readAt == now)
        #expect(section.lines[0].destination == .releaseCenter)
        #expect(section.notes.contains("No App Store Connect key."))

        let never = DailyBriefBuilder.releases(emptyInput { $0.releases = ReleaseCenterSnapshot(gitHubNote: "Could not read the GitHub token.") })
        #expect(never.state == .neverRead("Could not read the GitHub token."))
    }

    @Test func licencesExpiringExpiredAndRecent() {
        let records = [
            licence("MF-2026-0001", expires: "2026-10-20"),                               // 11 days
            licence("MF-2026-0002", expires: "2026-10-01"),                               // expired
            licence("MF-2026-0003", expires: "2027-12-31", created: now.addingTimeInterval(-2 * 86_400)),  // recent
            licence("MF-2026-0004", expires: "2026-10-12", status: .superseded),          // not active: ignored
            licence("MF-2026-0005", expires: nil),                                        // perpetual
        ]
        let input = emptyInput { $0.licences = BriefLicenceInput(isLoaded: true, records: records, lastSyncedAt: now) }
        let section = DailyBriefBuilder.licences(input)
        #expect(section.lines.map(\.id) == ["licence.expired.MF-2026-0002", "licence.expiring.MF-2026-0001", "licence.issued.MF-2026-0003"])
        #expect(section.lines[1].text.contains("11 days"))
        #expect(section.lines[1].destination == .licence("MF-2026-0001"))
        #expect(section.lines[2].severity == .info)

        let empty = DailyBriefBuilder.licences(emptyInput { $0.licences = BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: nil) })
        #expect(empty.state == .allClear)
        #expect(empty.source.contains("not synced"))
    }

    @Test func workTrackRenewalsFromTheEmulatorList() throws {
        let list = try companies()
        let signedOut = DailyBriefBuilder.worktrack(emptyInput())
        guard case .neverRead = signedOut.state else { Issue.record("expected never read"); return }

        let failed = DailyBriefBuilder.worktrack(emptyInput {
            $0.worktrack = BriefWorkTrackInput(isSignedIn: true, environment: "production", companies: [], lastRead: nil, loadError: "HTTP 500")
        })
        #expect(failed.state == .unavailable("HTTP 500"))

        let section = DailyBriefBuilder.worktrack(emptyInput {
            $0.worktrack = BriefWorkTrackInput(isSignedIn: true, environment: "localEmulator", companies: list, lastRead: now)
        })
        let summary = WTCustomersSummary(companies: list)
        #expect(section.lines.count == summary.expired.count + summary.expiringSoon.count)
        #expect(section.lines.contains { $0.id == "worktrack.expired.emu_mazar" && $0.severity == .high })
        // The TEST-flagged company is never reported.
        #expect(!section.lines.contains { $0.id.hasSuffix("emu_test") })
        #expect(section.notes.count == 1)   // not production
    }

    @Test func operationsQueuesAndPartialSignIn() {
        let counts = [OperationsCount(queue: .talarHalls, count: 3, environment: "production", readAt: now),
                      OperationsCount(queue: .talarReviews, count: 0, environment: "production", readAt: now)]
        let input = emptyInput {
            $0.operations = [BriefOperationsInput(product: .talar, isSignedIn: true, counts: counts),
                             BriefOperationsInput(product: .safeBeauty, isSignedIn: false, counts: []),
                             BriefOperationsInput(product: .velro, isSignedIn: true, counts: [])]
        }
        let section = DailyBriefBuilder.operations(input)
        #expect(section.lines.count == 1)
        #expect(section.lines[0].text == "Talar: 3 halls waiting for approval")
        #expect(section.lines[0].destination == .operations(.talar))
        #expect(section.notes.count == 2)   // SafeBeauty not signed in, VELRO not read yet
        #expect(section.readAt == now)

        let none = DailyBriefBuilder.operations(emptyInput())
        guard case .neverRead = none.state else { Issue.record("expected never read"); return }
    }

    @Test func attentionOrderAndNotificationText() {
        let input = emptyInput { i in
            var s = MonitorSnapshot()
            s.lastRoundAt = now
            let id = MonitorCatalog.targets[0].id
            s.latest[id] = MonitorResult(targetID: id, checkedAt: now, state: .down)
            i.monitor = s
            i.licences = BriefLicenceInput(isLoaded: true, records: [licence("MF-2026-0001", expires: "2026-10-30")], lastSyncedAt: nil)
        }
        let brief = DailyBriefBuilder.build(input, changes: [])
        #expect(brief.attention.first?.severity == .high)
        #expect(brief.attention.first?.kind == .monitor)
        #expect(brief.section(.changes)?.state == .allClear)
        let text = BriefNotificationText.content(brief, asOf: "10:00")
        #expect(text.title == "Daily Brief")
        #expect(text.body.contains("2 items need you"))
        #expect(text.body.contains("Not read: "))
        #expect(!text.body.contains("What changed"))
        #expect(text.body.hasSuffix("As of 10:00."))

        let clear = BriefNotificationText.content(DailyBriefBuilder.build(emptyInput(), changes: nil), asOf: "08:00")
        #expect(clear.body.hasPrefix("Nothing needs you"))
    }

    @Test func nextMorningFire() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kabul")!
        // 10:00 UTC is 14:30 in Kabul: the next 08:00 is tomorrow.
        let next = BriefSchedule.nextFire(after: now, hour: 8, minute: 0, calendar: cal)
        let c = cal.dateComponents([.day, .hour, .minute], from: next)
        #expect(c.day == 10 && c.hour == 8 && c.minute == 0)
        // Before 08:00 local: today.
        let early = BriefSchedule.nextFire(after: now.addingTimeInterval(-10 * hour), hour: 8, minute: 0, calendar: cal)
        #expect(cal.dateComponents([.day], from: early).day == 9)
        // Exactly at the time: the next day, never now.
        #expect(BriefSchedule.nextFire(after: next, hour: 8, minute: 0, calendar: cal) == next.addingTimeInterval(86_400))
    }
}

@Suite("Daily Brief: snapshots and diff")
struct BriefSnapshotTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func captureOnlyWhatWasRead() {
        let snap = BriefDailySnapshot.capture(emptyInput(), calendar: utc)
        #expect(snap.day == "2026-10-09")
        #expect(snap.monitor == nil && snap.appStore == nil && snap.pulls == nil && snap.licenceCount == nil
                && snap.worktrackCompanies == nil && snap.operations == nil)

        let repo = ReleaseRepo(slug: "o/r", productName: "R", source: "t")
        let pr = GitHubPullInfo(number: 7, title: "Brief", base: "main", head: "b", headSHA: "s", url: URL(string: "https://github.com/o/r/pull/7")!)
        let read = BriefDailySnapshot.capture(emptyInput {
            $0.releases = ReleaseCenterSnapshot(repos: [RepoReleaseStatus(repo: repo, defaultBranch: "main", pulls: [pr], mainCI: .success, fetchedAt: now)],
                                                gitHubReadAt: now)
            $0.licences = BriefLicenceInput(isLoaded: true, records: [licence("A", expires: nil), licence("B", expires: nil, status: .void)], lastSyncedAt: nil)
        }, calendar: utc)
        #expect(read.pulls?["o/r"] == ["7": "Brief"])
        #expect(read.mainCI?["o/r"] == "success")
        #expect(read.licenceCount == 2 && read.licenceActive == 1)
    }

    @Test func diffReportsOnlyFieldsReadOnBothDays() {
        let old = BriefDailySnapshot(day: "2026-10-08", takenAt: now.addingTimeInterval(-86_400),
                                     monitor: ["velro.api.live": .up, "velro.admin": .up],
                                     appStore: ["SafeBeauty": "1.2: In review"],
                                     pulls: ["o/r": ["6": "Vault", "7": "Monitor"]], mainCI: ["o/r": "success"],
                                     licenceCount: 5, operations: ["talarHalls": 0])
        let new = BriefDailySnapshot(day: "2026-10-09", takenAt: now,
                                     monitor: ["velro.api.live": .down, "velro.admin": .up],
                                     appStore: ["SafeBeauty": "1.2: Pending developer release"],
                                     pulls: ["o/r": ["7": "Monitor", "8": "Releases"]], mainCI: ["o/r": "failure"],
                                     licenceCount: 7, worktrackCompanies: 12, operations: ["talarHalls": 2])
        let lines = BriefDiff.lines(from: old, to: new)
        let ids = lines.map(\.id)
        #expect(ids.contains("changes.monitor.velro.api.live"))
        #expect(!ids.contains("changes.monitor.velro.admin"))
        #expect(ids.contains("changes.appstore.SafeBeauty"))
        #expect(ids.contains("changes.pr.new.o/r.8"))
        #expect(ids.contains("changes.pr.gone.o/r.6"))
        #expect(ids.contains("changes.ci.o/r"))
        #expect(ids.contains("changes.licences.count"))
        #expect(ids.contains("changes.ops.talarHalls"))
        // WorkTrack wasn't read yesterday: no "0 → 12".
        #expect(!ids.contains { $0.hasPrefix("changes.worktrack") })
        #expect(lines.first { $0.id == "changes.monitor.velro.api.live" }?.text.contains("Up → Down") == true)
        #expect(lines.first { $0.id == "changes.licences.count" }?.text == "Licences in the ledger: 5 → 7")
        #expect(lines.allSatisfy { $0.kind == .changes && $0.readAt == now })
        #expect(BriefDiff.lines(from: new, to: new).isEmpty)
    }

    @Test func historyKeepsOnePerDayFillsGapsAndFindsYesterday() {
        var history = BriefSnapshotHistory()
        history.record(BriefDailySnapshot(day: "2026-10-07", takenAt: now, licenceCount: 1))
        history.record(BriefDailySnapshot(day: "2026-10-08", takenAt: now, licenceCount: 2, worktrackCompanies: 9))
        // Later the same day WorkTrack isn't read yet: yesterday's value is kept for the day.
        history.record(BriefDailySnapshot(day: "2026-10-08", takenAt: now, licenceCount: 3))
        #expect(history.snapshots.count == 2)
        #expect(history.snapshot(for: "2026-10-08")?.licenceCount == 3)
        #expect(history.snapshot(for: "2026-10-08")?.worktrackCompanies == 9)
        #expect(history.baseline(before: "2026-10-09")?.day == "2026-10-08")
        #expect(history.baseline(before: "2026-10-08")?.day == "2026-10-07")
        #expect(history.baseline(before: "2026-10-07") == nil)
        for d in 10...25 { history.record(BriefDailySnapshot(day: "2026-10-\(d)", takenAt: now)) }
        #expect(history.snapshots.count == BriefSnapshotHistory.keepDays)
        #expect(history.snapshots.last?.day == "2026-10-25")
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "brief-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BriefSnapshotStore(fileURL: url)
        #expect(store.load().snapshots.isEmpty)
        var h = BriefSnapshotHistory()
        h.record(BriefDailySnapshot(day: "2026-10-09", takenAt: now, monitor: ["a": .down], pulls: ["o/r": ["1": "x"]]))
        try store.save(h)
        #expect(store.load() == h)
    }
}
