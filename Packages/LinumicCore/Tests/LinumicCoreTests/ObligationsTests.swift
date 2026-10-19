import Foundation
import Testing
@testable import LinumicCore

// Synthetic inputs plus the seed as shipped. No network.

private let now = Date(timeIntervalSince1970: 1_792_411_200) // 2026-10-19T12:00:00Z
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private let today = KeyDay("2026-10-19")!

private func day(_ s: String) -> KeyDay { KeyDay(s)! }

private func row(_ id: String, due: String?, origin: ObligationOrigin = .owner, source: String = "a receipt",
                 recorded: KeyDay? = today) -> Obligation {
    Obligation(id: id, title: id, area: .other, due: due.flatMap(KeyDay.init), source: source, recordedOn: recorded, origin: origin)
}

private func build(_ file: ObligationsFile = ObligationsFile(), live: ObligationLiveInput = ObligationLiveInput(),
                   seed: [Obligation] = ObligationSeed.obligations, accounts: [VendorAccount] = ObligationSeed.accounts) -> ObligationsRegister {
    ObligationsBuilder.build(file: file, live: live, now: now, calendar: utc, seed: seed, seedAccounts: accounts)
}

private func briefInput(_ register: ObligationsRegister, loadError: String? = nil) -> BriefInput {
    BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
               licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
               operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
               obligations: BriefObligationsInput(register: register, loadError: loadError))
}

@Suite("Obligations: the seed")
struct ObligationSeedTests {
    @Test func everySeedRowHasASourceAndADayAndTheSeedValidates() {
        let register = build()
        #expect(register.issues.isEmpty, "\(register.issues.map(\.text))")
        for o in ObligationSeed.obligations {
            #expect(!o.source.isEmpty && o.recordedOn != nil, "\(o.id)")
            #expect(o.origin == .seed)
        }
        for a in ObligationSeed.accounts {
            #expect(!a.source.isEmpty && a.recordedOn != nil, "\(a.id)")
            #expect(a.holder == nil || a.holderSource?.isEmpty == false, "\(a.id)")
        }
        #expect(Set(ObligationSeed.obligations.map(\.id)).count == ObligationSeed.obligations.count)
        #expect(Set(ObligationSeed.accounts.map(\.id)).count == ObligationSeed.accounts.count)
    }

    @Test func theRoadmapsTwoDatesAreThereWithTheirSources() throws {
        let register = build()
        // The Mac profile is the 2027-09-23 date of NEXT-ACTIONS:147; the Developer ID certificate itself ends sooner.
        let profile = try #require(register.obligation("signing.linumicos-mac-profile"))
        #expect(profile.due == day("2027-09-23"))
        #expect(profile.source.contains("NEXT-ACTIONS-2026-10-19.md:147"))
        let certificate = try #require(register.obligation("signing.developer-id-certificate"))
        #expect(certificate.due == day("2027-02-01"))
        let pashto = try #require(register.obligation("marketing.safebeauty-dst-pashto"))
        #expect(pashto.due == day("2026-10-31"))
        #expect(pashto.source.contains("NEXT-ACTIONS-2026-10-19.md:119"))
        #expect(pashto.consequence != nil)
        // An unknown date stays unknown: its own lane, never a guess.
        #expect(register.obligation("stores.play-target-api")?.due == nil)
        #expect(ObligationRules.lane(register.obligation("stores.play-target-api")!, today: today) == .dateUnknown)
    }

    @Test func accountsSayWhoseNameTheyAreInOrThatItIsNotRecorded() throws {
        let register = build()
        let apple = try #require(register.accounts.first { $0.id == "apple-developer" })
        #expect(apple.holder == .personal)
        #expect(register.accounts.first { $0.id == "hetzner" }?.holder == nil)
        // Every account's renewal is an obligation; unknown renewals are "date unknown", never invented.
        let renewal = try #require(register.obligation(apple.renewalObligationID))
        #expect(renewal.due == nil)
        #expect(renewal.origin == .account)
    }
}

@Suite("Obligations: validate() and the owner's entries")
struct ObligationValidationTests {
    @Test func aRowWithoutASourceOrDayIsRefused() {
        let issues = ObligationsBuilder.validate(obligations: [row("a", due: nil, source: "  "), row("b", due: nil, recorded: nil),
                                                                row("c", due: nil), row("c", due: nil)],
                                                 accounts: [VendorAccount(id: "x", name: "X", purpose: "", source: "", recordedOn: today, origin: .owner),
                                                            VendorAccount(id: "y", name: "Y", purpose: "", holder: .company, source: "s",
                                                                          recordedOn: today, origin: .owner)],
                                                 file: ObligationsFile())
        #expect(Set(issues) == [.noSource("a"), .noSource("b"), .duplicateID("c"), .noSource("x"), .valueWithoutSource("y")])
    }

    @Test func aDoneWithoutEvidenceIsRefused() {
        var file = ObligationsFile()
        file.completions = [ObligationCompletion(obligationID: "a", due: nil, on: today, evidence: " ", enteredAt: now)]
        file.dates = [ObligationDateEntry(obligationID: "b", due: today, source: "", enteredAt: now)]
        let register = build(file, seed: [row("a", due: nil), row("b", due: nil)], accounts: [])
        #expect(Set(register.issues) == [.doneWithoutEvidence("a"), .valueWithoutSource("b")])
        // The Brief shows every refusal as a high line.
        let section = DailyBriefBuilder.obligations(briefInput(register))
        #expect(section.lines.filter { $0.severity == .high }.count == 2)
    }

    @Test func changesNeedTheirSourceOrEvidence() throws {
        var file = ObligationsFile()
        #expect(throws: ObligationError.missingSource) {
            try file.add(title: "Renew X", product: nil, area: .other, due: nil, consequence: nil, source: " ", now: now, calendar: utc)
        }
        #expect(throws: ObligationError.missingTitle) {
            try file.add(title: "", product: nil, area: .other, due: nil, consequence: nil, source: "invoice 12", now: now, calendar: utc)
        }
        let added = try file.add(title: "Renew X", product: "WorkTrack", area: .accounts, due: day("2026-11-01"), consequence: nil,
                                 source: "invoice 12", now: now, calendar: utc)
        #expect(added.id.hasPrefix("owner."))
        #expect(added.recordedOn == today)
        #expect(throws: ObligationError.missingEvidence) {
            try file.complete(added.id, due: added.due, on: today, evidence: "", now: now, calendar: utc)
        }
        #expect(throws: ObligationError.futureDay) {
            try file.complete(added.id, due: added.due, on: day("2026-10-20"), evidence: "receipt", now: now, calendar: utc)
        }
        #expect(throws: ObligationError.missingSource) { try file.setDate(added.id, due: today, source: "", now: now) }
        #expect(throws: ObligationError.missingSource) {
            try file.editAccount("hetzner", renewal: day("2027-01-01"), renewalSource: nil, holder: nil, holderSource: nil, now: now)
        }
        try file.complete(added.id, due: added.due, on: today, evidence: "receipt 7781", now: now, calendar: utc)
        let register = build(file, seed: [], accounts: [])
        #expect(register.obligation(added.id)?.isClosed == true)
        #expect(register.issues.isEmpty)
    }

    @Test func doneHoldsForItsDueDayOnly() throws {
        var file = ObligationsFile()
        try file.complete("a", due: day("2026-10-25"), on: today, evidence: "paid", now: now, calendar: utc)
        #expect(build(file, seed: [row("a", due: "2026-10-25")], accounts: []).obligation("a")?.isClosed == true)
        // The next period (a new due day) is open again.
        #expect(build(file, seed: [row("a", due: "2027-10-25")], accounts: []).obligation("a")?.isClosed == false)
        // A date the owner sets replaces the seed's, with its source.
        try file.setDate("a", due: day("2026-12-01"), source: "renewal email 2026-10-19", now: now)
        let moved = try #require(build(file, seed: [row("a", due: nil, origin: .seed)], accounts: []).obligation("a"))
        #expect(moved.due == day("2026-12-01"))
        #expect(moved.dueSource == "renewal email 2026-10-19")
    }

    @Test func anAccountsRenewalAndHolderComeWithTheirSources() throws {
        var file = ObligationsFile()
        try file.editAccount("hetzner", renewal: day("2026-11-05"), renewalSource: "Hetzner invoice 2026-10", holder: .personal,
                             holderSource: "Hetzner account page", now: now)
        let register = build(file)
        let hetzner = try #require(register.accounts.first { $0.id == "hetzner" })
        #expect(hetzner.holder == .personal && hetzner.renewal == day("2026-11-05"))
        let renewal = try #require(register.obligation("account.hetzner.renewal"))
        #expect(renewal.due == day("2026-11-05"))
        #expect(renewal.source == "Hetzner invoice 2026-10")
    }

    @Test func theFileSurvivesARestartAndABadFileIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "obligations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ObligationsStore(fileURL: url)
        guard case .empty = store.load() else { Issue.record("no file is empty"); return }
        var file = ObligationsFile()
        try file.add(title: "Pay hosting", product: nil, area: .accounts, due: day("2026-11-01"), consequence: "Site goes down",
                     source: "GoDaddy email", now: now, calendar: utc)
        try store.save(file)
        guard case .loaded(let back) = store.load() else { Issue.record("not loaded"); return }
        #expect(back == file)
        try Data("not json".utf8).write(to: url)
        guard case .unreadable = store.load() else { Issue.record("a bad file must be reported"); return }
    }
}

@Suite("Obligations: lead days, lanes and live dates")
struct ObligationTimingTests {
    @Test func leadWindowsAt30_14_7_1() {
        let lead = { ObligationRules.lead(daysLeft: $0, leadDays: Obligation.defaultLeadDays) }
        #expect(lead(31) == nil)
        #expect(lead(30) == 30 && lead(15) == 30)
        #expect(lead(14) == 14 && lead(8) == 14)
        #expect(lead(7) == 7 && lead(2) == 7)
        #expect(lead(1) == 1)
        #expect(lead(0) == 0 && lead(-3) == 0)
    }

    @Test func severityAndLanes() {
        let cases: [(String?, BriefSeverity, ObligationLane)] = [
            ("2026-10-17", .high, .overdue), ("2026-10-19", .high, .week), ("2026-10-20", .high, .week),
            ("2026-10-26", .normal, .week), ("2026-11-02", .normal, .month), ("2026-11-18", .info, .month),
            ("2027-02-01", .info, .later), (nil, .info, .dateUnknown),
        ]
        for (due, severity, lane) in cases {
            let o = row("x", due: due)
            #expect(ObligationRules.severity(o, today: today) == severity, "\(String(describing: due))")
            #expect(ObligationRules.lane(o, today: today) == lane, "\(String(describing: due))")
        }
    }

    @Test func liveDatesBecomeObligationsAndTheMonitorsReadingReplacesTheSeed() throws {
        var snapshot = MonitorSnapshot()
        let rdap = DomainReading(name: "linumic.com", expiresAt: utc.date(from: DateComponents(year: 2029, month: 8, day: 15)),
                                 registeredAt: nil, registrar: "GoDaddy.com, LLC", rdapUpdatedAt: nil,
                                 sourceURL: "https://rdap.verisign.com/com/v1/domain/linumic.com", fetchedAt: now)
        snapshot.domains["linumic.com"] = rdap
        snapshot.certificates["api.velro.af"] = CertificateReading(host: "api.velro.af", notAfter: now.addingTimeInterval(80 * 86_400), readAt: now)
        snapshot.certificates["elsewhere.example"] = CertificateReading(host: "elsewhere.example", notAfter: now, readAt: now)
        let licence = LicenceRecord(product: .khayatyar, licenceID: "KY-2026-0001", customer: "A tailor", machine: "M",
                                    issued: "2026-10-17", expires: "2028-10-17", createdBy: "test", createdAt: now)
        let live = ObligationLiveInput(monitor: snapshot, monitorHosts: ["api.velro.af"], licences: [licence], licencesReadAt: now,
                                       licencesSynced: true, keys: KeysRegistry.seed, continuity: ContinuityLog())
        let register = build(live: live)
        #expect(register.unread.isEmpty)
        let domain = try #require(register.obligation("domain.linumic.com"))
        #expect(domain.origin == .domain && domain.due == day("2029-08-15"))
        #expect(domain.source.contains("rdap.verisign.com"))
        #expect(register.obligations.filter { $0.id == "domain.linumic.com" }.count == 1)
        #expect(register.obligation("tls.api.velro.af")?.due != nil)
        #expect(register.obligation("tls.elsewhere.example") == nil)
        let ky = try #require(register.obligation("licence.KY-2026-0001"))
        #expect(ky.due == day("2028-10-17"))
        #expect(!ky.title.contains("A tailor"))   // no customer name in the register
        #expect(ky.destination == .licence("KY-2026-0001"))
        let export = try #require(register.obligation("continuity.export"))
        #expect(export.due == nil)
        #expect(register.issues.isEmpty, "\(register.issues.map(\.text))")
    }

    @Test func unreadSourcesAreGapsNotZeros() {
        let register = build()
        #expect(register.unread == ObligationLiveSource.allCases)
        let section = DailyBriefBuilder.obligations(briefInput(register))
        #expect(Set(section.gaps.map(\.key)) == Set(ObligationLiveSource.allCases.map(\.rawValue)))
        // Without live readings the seed's linumic.com date stands, with its own source.
        #expect(register.obligation("domain.linumic.com")?.origin == .seed)
    }
}

@Suite("Obligations on the Brief and the Desk")
struct ObligationDeskTests {
    @Test func dueAndLeadWindowsDecideTodayThisWeekAndLater() throws {
        var file = ObligationsFile()
        try file.add(title: "Overdue bill", product: nil, area: .accounts, due: day("2026-10-15"), consequence: nil, source: "bill 1",
                     now: now, calendar: utc)
        try file.add(title: "Tomorrow", product: nil, area: .other, due: day("2026-10-20"), consequence: nil, source: "email", now: now,
                     calendar: utc)
        let register = build(file)
        let brief = DailyBrief(sections: [DailyBriefBuilder.obligations(briefInput(register))], generatedAt: now)
        let desk = DeskBuilder.build(brief: brief, ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        func bucket(_ id: String) -> DeskBucket? {
            (desk.today.map { ($0, DeskBucket.today) } + desk.thisWeek.map { ($0, .thisWeek) } + desk.later.map { ($0, .later) })
                .first { $0.0.item.subjectKey == "obligation.\(id)" }?.1
        }
        #expect(bucket(register.obligations.first { $0.title == "Overdue bill" }!.id) == .today)
        #expect(bucket(register.obligations.first { $0.title == "Tomorrow" }!.id) == .today)
        #expect(bucket("marketing.worktrack-queue-end") == .thisWeek)       // 7 days
        #expect(bucket("marketing.safebeauty-dst-pashto") == .thisWeek)     // 12 days: the 14-day window
        #expect(bucket("marketing.safebeauty-dst-reels") == .later)         // 22 days: the 30-day window
        #expect(bucket("signing.developer-id-certificate") == .later)
        #expect(bucket("signing.linumicos-mac-profile") == .later)
        #expect(bucket("stores.play-target-api") == .later)                 // date unknown
        // Each row says where it comes from and when it is due.
        let profile = try #require(desk.later.first { $0.item.subjectKey == "obligation.signing.linumicos-mac-profile" })
        #expect(profile.item.evidence.source.contains("NEXT-ACTIONS-2026-10-19.md:147"))
        #expect(profile.item.due == day("2027-09-23"))
        #expect(profile.item.destination == .screen(.obligation("signing.linumicos-mac-profile")))
        #expect(profile.item.domain == .linumicOS)
    }

    @Test func otherSectionsWindowsAreNotRepeated() {
        let soon = row("domain.example.com", due: "2026-11-01", origin: .domain)
        let far = row("domain.linumic.com", due: "2029-08-15", origin: .domain)
        let keysDue = row("keys.restore.drive", due: "2026-10-01", origin: .keys)
        let keysNext = row("keys.restore.usb", due: "2026-12-01", origin: .keys)
        let keysUnknown = row("keys.second-copy", due: nil, origin: .keys)
        let tls = row("tls.api.velro.af", due: "2027-01-01", origin: .certificate)
        #expect(!ObligationsBriefRules.showsInBrief(tls, today: today))    // renews by itself; the Monitor warns at 30 days
        #expect(!ObligationsBriefRules.showsInBrief(soon, today: today))   // the Monitor section says it
        #expect(ObligationsBriefRules.showsInBrief(far, today: today))
        #expect(!ObligationsBriefRules.showsInBrief(keysDue, today: today))
        #expect(ObligationsBriefRules.showsInBrief(keysNext, today: today))
        #expect(!ObligationsBriefRules.showsInBrief(keysUnknown, today: today))
    }

    @Test func noEncryptedCopyYetIsThisWeekNotLater() throws {
        let register = build(live: ObligationLiveInput(continuity: ContinuityLog()))
        let section = DailyBriefBuilder.obligations(briefInput(register))
        let line = try #require(section.lines.first { $0.id == "obligation.continuity.export" })
        #expect(line.severity == .normal)
        #expect(line.destination == .continuity)
    }

    @Test func aVerifiedExportIsDueAgainIn30Days() throws {
        var log = ContinuityLog()
        log.add(ContinuityExportRecord(fileName: "linumic-os-continuity-2026-10-19-1200.json.age", folder: "USB", folderKind: .external,
                                       createdAt: now, verifiedAt: now, fileBytes: 1, fileSHA256: "a", plaintextBytes: 1,
                                       plaintextSHA256: "b", workFactor: 18, formatVersion: 1, counts: [:]))
        let register = build(live: ObligationLiveInput(continuity: log))
        let export = try #require(register.obligation("continuity.export"))
        #expect(export.due == day("2026-11-18"))
        #expect(export.source.contains("linumic-os-continuity-2026-10-19-1200.json.age"))
    }

    @Test func aBriefLinesFactChangesWhenItsWindowDoes() {
        // The Desk's marks follow the fact: a "waiting" mark at 30 days does not hide the 7-day reminder.
        let o = row("x", due: "2026-11-15")
        let early = DailyBriefBuilder.obligations(briefInput(build(ObligationsFile(added: [o]), seed: [], accounts: [])))
        let later = DailyBriefBuilder.obligations(BriefInput(now: now.addingTimeInterval(20 * 86_400), monitor: MonitorSnapshot(),
                                                             releases: ReleaseCenterSnapshot(),
                                                             licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                                             worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                                                             operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
                                                             obligations: BriefObligationsInput(register: build(ObligationsFile(added: [o]), seed: [], accounts: []))))
        let a = early.lines.first { $0.id == "obligation.x" }!
        let b = later.lines.first { $0.id == "obligation.x" }!
        #expect(a.severity == .info && b.severity == .normal)
        #expect(DeskBuilder.factHash(a) != DeskBuilder.factHash(b))
    }
}

@Suite("Obligation alerts at the lead days")
struct ObligationAlertTests {
    @Test func eachWindowAlertsOnceWithTheSharedKey() {
        let register = build(ObligationsFile(added: [row("bill", due: "2026-10-26"), row("unknown", due: nil),
                                                     row("far", due: "2027-06-01")]), seed: [], accounts: [])
        let first = ObligationAlerts.due(register, today: today, sent: [])
        #expect(first.map(\.key) == ["obligation:bill:2026-10-26:7"])
        #expect(ObligationAlerts.due(register, today: today, sent: Set(first.map(\.key))).isEmpty)
        // The next window is a new alert; the day itself and after it too.
        #expect(ObligationAlerts.due(register, today: day("2026-10-25"), sent: Set(first.map(\.key))).map(\.key)
                == ["obligation:bill:2026-10-26:1"])
        #expect(ObligationAlerts.due(register, today: day("2026-10-28"), sent: []).map(\.lead) == [0])
    }

    @Test func liveAndClosedRowsDoNotAlertHere() throws {
        var file = ObligationsFile(added: [row("paid", due: "2026-10-20")])
        try file.complete("paid", due: day("2026-10-20"), on: today, evidence: "receipt", now: now, calendar: utc)
        let live = row("licence.X", due: "2026-10-21", origin: .licence)
        let register = build(file, seed: [live], accounts: [])
        #expect(ObligationAlerts.due(register, today: today, sent: []).isEmpty)
    }
}
