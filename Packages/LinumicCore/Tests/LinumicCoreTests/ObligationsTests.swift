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
        // «پیش از ۳۱ اکتبر» and «پیش از ۱۰ نومبر» are read as the day before, as «پیش از ۲۷ اکتبر» is for WorkTrack.
        let pashto = try #require(register.obligation("marketing.safebeauty-dst-pashto"))
        #expect(pashto.due == day("2026-10-30"))
        #expect(pashto.source.contains("NEXT-ACTIONS-2026-10-19.md:119"))
        #expect(pashto.consequence != nil)
        #expect(register.obligation("marketing.safebeauty-dst-reels")?.due == day("2026-11-09"))
        #expect(register.obligation("marketing.worktrack-queue-end")?.due == day("2026-10-26"))
        // What signs the installed copy ends before the profile does, and is a row of its own.
        let development = try #require(register.obligation("signing.apple-development-certificate"))
        #expect(development.due == day("2027-09-08"))
        #expect(development.source.contains("T9QW4K4J88") && development.source.contains("PRIORITIES.md:15"))
        // An unknown date stays unknown: its own lane, never a guess.
        #expect(register.obligation("stores.play-target-api")?.due == nil)
        #expect(ObligationRules.lane(register.obligation("stores.play-target-api")!, today: today) == .dateUnknown)
    }

    @Test func accountsSayWhoseNameTheyAreInOrThatItIsNotRecorded() throws {
        let register = build()
        let apple = try #require(register.accounts.first { $0.id == "apple-developer" })
        #expect(apple.holder == .personal)
        #expect(register.accounts.first { $0.id == "hetzner" }?.holder == nil)
        // No source records a renewal or billing term for any seed account (Supabase is on the free plan), so none has
        // a renewal obligation: nothing presumes an account renews.
        #expect(!register.obligations.contains { $0.origin == .account })
        // Once a bill says it is paid yearly, the renewal is an obligation, "date unknown" until the day is recorded.
        var file = ObligationsFile()
        try file.editAccount("apple-developer", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                             cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "Apple receipt"), now: now)
        let renewal = try #require(build(file).obligation(apple.renewalObligationID))
        #expect(renewal.due == nil)
        #expect(renewal.origin == .account)
        #expect(renewal.source == "Apple receipt")
        // A one-off cost is no term.
        var once = ObligationsFile()
        try once.editAccount("elevenlabs", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                             cost: AccountCost(amount: 5, currency: "USD", cycle: .once, source: "receipt"), now: now)
        #expect(build(once).obligation("account.elevenlabs.renewal") == nil)
    }

    @Test func linumicComsConsequenceIsWhatItsSourceSays() throws {
        // docs/integrations.md:548-551 names linumic.com's subdomains and Google's hosts, and no mailbox.
        let seed = try #require(ObligationSeed.obligations.first { $0.id == "domain.linumic.com" })
        #expect(seed.consequence == ObligationSeed.linumicComConsequence)
        #expect(!ObligationSeed.linumicComConsequence.contains("contact@"))
        #expect(ObligationSeed.linumicComConsequence.contains("web.app") && ObligationSeed.linumicComConsequence.contains("cloudfunctions.net"))
        var snapshot = MonitorSnapshot()
        snapshot.domains["linumic.com"] = DomainReading(name: "linumic.com", expiresAt: utc.date(from: DateComponents(year: 2029, month: 8, day: 15)),
                                                        registeredAt: nil, registrar: nil, rdapUpdatedAt: nil,
                                                        sourceURL: "https://rdap.verisign.com/com/v1/domain/linumic.com", fetchedAt: now)
        #expect(build(live: ObligationLiveInput(monitor: snapshot)).obligation("domain.linumic.com")?.consequence
                == ObligationSeed.linumicComConsequence)
    }

    @Test func theSupabaseCitationPointsAtTheLineThatHoldsIt() throws {
        // docs/backend-plan.md is in this repository: the cited line must still hold the organization.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let lines = try String(contentsOf: root.appending(path: "docs/backend-plan.md"), encoding: .utf8).components(separatedBy: "\n")
        let supabase = try #require(ObligationSeed.accounts.first { $0.id == "supabase" })
        #expect(supabase.source.contains("backend-plan.md:20"))
        #expect(lines[19].contains("Organization") && lines[19].contains("mjkdmjrjalelcmqwdwok") && lines[19].contains("Free plan"))
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
        // Refused means not applied: "a" is still open, and "b" still has no date.
        #expect(register.obligation("a")?.isClosed == false)
        #expect(register.obligation("a")?.completion == nil)
        #expect(register.obligation("b")?.due == nil && register.obligation("b")?.dueSource == nil)
        // The Brief shows every refusal as a high line.
        let section = DailyBriefBuilder.obligations(briefInput(register))
        #expect(section.lines.filter { $0.severity == .high }.count == 2)
    }

    @Test func anAccountValueWithoutASourceIsNotApplied() throws {
        var file = ObligationsFile()
        file.accountEdits = [VendorAccountEdit(accountID: "hetzner", renewal: day("2026-11-05"), renewalSource: " ", holder: .company,
                                               holderSource: nil, enteredAt: now)]
        let register = build(file)
        let hetzner = try #require(register.accounts.first { $0.id == "hetzner" })
        #expect(hetzner.renewal == nil && hetzner.renewalSource == nil)
        #expect(hetzner.holder == nil)
        #expect(register.obligation("account.hetzner.renewal") == nil)
        #expect(register.issues == [.valueWithoutSource("hetzner")])
        // A cost without its bill, on an account itself, is reported and taken off it.
        let costly = VendorAccount(id: "x", name: "X", purpose: "", cost: AccountCost(amount: 5, currency: "EUR", cycle: .monthly, source: " "),
                                   source: "s", recordedOn: today, origin: .seed)
        #expect(ObligationsBuilder.validate(obligations: [], accounts: [costly], file: ObligationsFile()) == [.valueWithoutSource("x")])
        let kept = build(seed: [], accounts: [costly])
        #expect(kept.accounts.first?.cost == nil)
        #expect(kept.obligation("account.x.renewal") == nil)   // a cost that is not applied is no billing term either
    }

    @Test func aDateIsNotAppliedToALiveRowOrToNoRow() throws {
        var snapshot = MonitorSnapshot()
        snapshot.domains["linumic.com"] = DomainReading(name: "linumic.com", expiresAt: utc.date(from: DateComponents(year: 2029, month: 8, day: 15)),
                                                        registeredAt: nil, registrar: nil, rdapUpdatedAt: nil,
                                                        sourceURL: "https://rdap.verisign.com/com/v1/domain/linumic.com", fetchedAt: now)
        var file = ObligationsFile()
        try file.setDate("domain.linumic.com", due: day("2030-01-01"), source: "a guess", now: now)
        try file.setDate("no.such.row", due: day("2030-01-01"), source: "a note", now: now)
        let register = build(file, live: ObligationLiveInput(monitor: snapshot))
        let domain = try #require(register.obligation("domain.linumic.com"))
        #expect(domain.origin == .domain && domain.due == day("2029-08-15") && domain.dueSource == nil)
        #expect(Set(register.issues) == [.dateNotApplied("domain.linumic.com"), .dateNotApplied("no.such.row")])
    }

    @Test func onlyRowsTheAppWritesAreTakenFromTheFile() throws {
        var file = ObligationsFile()
        // (1) A row with a blank source, written by hand: refused, and so not in the register, the alerts or the Brief.
        file.added.append(Obligation(id: "owner.x", title: "Pay something", area: .other, due: day("2026-10-20"), source: "  ",
                                     recordedOn: today, origin: .owner))
        // (2) A row that copies a seed row's id with a live origin: refused, and the seed row stays as recorded.
        file.added.append(Obligation(id: "marketing.worktrack-queue-end", title: "Fake replacement", area: .marketing,
                                     due: day("2030-01-01"), source: "nothing", recordedOn: today, origin: .domain))
        // (3) An account with no source: refused, with no renewal row.
        file.accounts.append(VendorAccount(id: "owner.y", name: "Y", purpose: "", renewal: day("2026-11-01"), renewalSource: "r",
                                           source: "", recordedOn: today, origin: .owner))
        let register = build(file)
        #expect(register.obligation("owner.x") == nil)
        #expect(ObligationAlerts.due(register, today: today, sent: []).allSatisfy { $0.obligation.id != "owner.x" })
        let queue = try #require(register.obligation("marketing.worktrack-queue-end"))
        #expect(queue.title == "WorkTrack's scheduled Meta posts end on 2026-10-26" && queue.due == day("2026-10-26") && queue.origin == .seed)
        #expect(register.obligations.filter { $0.id == "marketing.worktrack-queue-end" }.count == 1)
        #expect(!register.accounts.contains { $0.id == "owner.y" })
        #expect(register.obligation("account.owner.y.renewal") == nil)
        #expect(Set(register.issues) == [.noSource("owner.x"), .notOwners("marketing.worktrack-queue-end"), .noSource("owner.y")])
        // The Brief says each refusal once, and nothing else about them.
        let section = DailyBriefBuilder.obligations(briefInput(register))
        #expect(!section.lines.contains { $0.obligationID == "owner.x" })
        #expect(section.lines.filter { $0.id.hasPrefix("obligation.issue.") }.count == 3)
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

    @Test func anAccountsRenewalDayIsEnteredOnTheAccountOnly() throws {
        // The yearly renew-and-record flow: one place for the day (the account's card), so the next renewal always
        // reaches the obligation, the Desk and the alerts.
        let d1 = now
        let d2 = now.addingTimeInterval(10 * 86_400)        // 2026-10-29
        let d3 = now.addingTimeInterval(380 * 86_400)       // 2027-11-03
        var file = ObligationsFile()
        try file.editAccount("apple-developer", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                             cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "Apple receipt"), now: d1)
        let id = "account.apple-developer.renewal"
        // Its row is recorded the day the bill was entered, not the day the account was.
        #expect(build(file).obligation(id)?.recordedOn == today)
        // A date set on the row itself is not applied: it would compete with the account's own renewal.
        try file.setDate(id, due: day("2026-11-01"), source: "renewal email", now: d1)
        var register = build(file)
        #expect(register.obligation(id)?.due == nil)
        #expect(register.issues == [.dateNotApplied(id)])
        // The day is recorded on the account (which supersedes that date), then the renewal is done with evidence.
        try file.editAccount("apple-developer", renewal: day("2026-11-01"), renewalSource: "Apple membership page", holder: nil,
                             holderSource: nil, now: d2)
        #expect(file.dates.isEmpty)
        register = build(file)
        let first = try #require(register.obligation(id))
        #expect(first.due == day("2026-11-01") && first.source == "Apple membership page")
        #expect(first.recordedOn == day("2026-10-29"))   // the day the renewal was entered
        try file.complete(id, due: first.due, on: day("2026-10-29"), evidence: "Apple receipt 2026-10-29", now: d2, calendar: utc)
        #expect(build(file).obligation(id)?.isClosed == true)
        // A year on, the next renewal is recorded on the card: the obligation follows it and is open again.
        try file.editAccount("apple-developer", renewal: day("2027-11-01"), renewalSource: "Apple membership page", holder: nil,
                             holderSource: nil, now: d3)
        register = build(file)
        let next = try #require(register.obligation(id))
        #expect(next.due == day("2027-11-01") && !next.isClosed)
        #expect(register.accounts.first { $0.id == "apple-developer" }?.renewal == day("2027-11-01"))
        #expect(register.issues.isEmpty)
        #expect(ObligationAlerts.due(register, today: day("2027-10-25"), sent: []).contains { $0.key == "obligation:\(id):2027-11-01:7" })
    }

    @Test func handWrittenValuesAreCheckedAsTheFormsCheckThem() throws {
        var file = ObligationsFile()
        // (1) A cost the sheet would refuse: not applied, so no billing term and no renewal row.
        file.accountEdits.append(VendorAccountEdit(accountID: "hetzner",
                                                   cost: AccountCost(amount: -5, currency: "dollars!", cycle: .monthly, source: "a note"),
                                                   enteredAt: now))
        // (2) A row with no lead days at all: it would never be brought forward.
        file.added.append(Obligation(id: "owner.tomorrow", title: "Pay the host", area: .accounts, due: day("2026-10-20"),
                                     source: "invoice", recordedOn: today, leadDays: [], origin: .owner))
        // (4) Facts for an account that is not in the register.
        file.accountEdits.append(VendorAccountEdit(accountID: "no-such-account", holder: .company, holderSource: "a page", enteredAt: now))
        // An account that is refused already has its own line; its facts are not reported twice.
        file.accounts.append(VendorAccount(id: "owner.nosource", name: "N", purpose: "", source: " ", recordedOn: today, origin: .owner))
        file.accountEdits.append(VendorAccountEdit(accountID: "owner.nosource", holder: .company, holderSource: "a page", enteredAt: now))
        let register = build(file)
        #expect(register.accounts.first { $0.id == "hetzner" }?.cost == nil)
        #expect(register.obligation("account.hetzner.renewal") == nil)
        let tomorrow = try #require(register.obligation("owner.tomorrow"))
        #expect(tomorrow.leadDays == Obligation.defaultLeadDays)
        #expect(ObligationRules.severity(tomorrow, today: today) == .high)
        #expect(ObligationAlerts.due(register, today: today, sent: []).contains { $0.key == "obligation:owner.tomorrow:2026-10-20:1" })
        #expect(Set(register.issues) == [.badValue("hetzner"), .unknownAccount("no-such-account"), .noSource("owner.nosource")])
        #expect(ObligationsBuilder.validate(obligations: [], accounts: [], file: file).contains(.badValue("hetzner")))
        // A seed or owner account whose own cost is malformed loses it too.
        let odd = VendorAccount(id: "x", name: "X", purpose: "", cost: AccountCost(amount: 0, currency: "USD", cycle: .yearly, source: "bill"),
                                source: "s", recordedOn: today, origin: .seed)
        let kept = build(seed: [], accounts: [odd])
        #expect(kept.accounts.first?.cost == nil && kept.issues == [.badValue("x")])
        // Lead days are the defaults only when unusable.
        #expect(Obligation.usableLeadDays([60, 10]) == [60, 10])
        #expect(Obligation.usableLeadDays([0]) == Obligation.defaultLeadDays)
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

    @Test func aCostIsOneAmountInOneCurrencyWithItsBill() throws {
        var file = ObligationsFile()
        #expect(throws: ObligationError.missingSource) {
            try file.editAccount("apple-developer", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                                 cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: " "), now: now)
        }
        #expect(throws: ObligationError.badAmount) {
            try file.editAccount("apple-developer", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                                 cost: AccountCost(amount: 99, currency: "US$", cycle: .yearly, source: "receipt"), now: now)
        }
        #expect(throws: ObligationError.badAmount) {
            try file.editAccount("apple-developer", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                                 cost: AccountCost(amount: 0, currency: "USD", cycle: .yearly, source: "receipt"), now: now)
        }
        try file.editAccount("apple-developer", renewal: day("2027-03-01"), renewalSource: "Apple membership page",
                             holder: nil, holderSource: nil,
                             cost: AccountCost(amount: 99, currency: "usd", cycle: .yearly, source: "Apple receipt 2026-03-01"), now: now)
        let register = build(file)
        let apple = try #require(register.accounts.first { $0.id == "apple-developer" })
        #expect(apple.cost == AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "Apple receipt 2026-03-01"))
        #expect(register.obligation(apple.renewalObligationID)?.due == day("2027-03-01"))
        #expect(register.issues.isEmpty)
        // A cost written without its bill (by hand in the file) is refused, not shown.
        var bad = ObligationsFile()
        bad.accountEdits = [VendorAccountEdit(accountID: "hetzner", cost: AccountCost(amount: 5, currency: "EUR", cycle: .monthly, source: ""),
                                              enteredAt: now)]
        let refused = build(bad)
        #expect(refused.accounts.first { $0.id == "hetzner" }?.cost == nil)
        #expect(refused.issues == [.valueWithoutSource("hetzner")])
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
        #expect(bucket("marketing.safebeauty-dst-pashto") == .thisWeek)     // 11 days: the 14-day window
        #expect(bucket("marketing.safebeauty-dst-reels") == .later)         // 21 days: the 30-day window
        #expect(bucket("signing.developer-id-certificate") == .later)
        #expect(bucket("signing.apple-development-certificate") == .later)
        #expect(bucket("signing.linumicos-mac-profile") == .later)
        #expect(bucket("stores.play-target-api") == .later)                 // date unknown
        // Each row says where it comes from and when it is due.
        let profile = try #require(desk.later.first { $0.item.subjectKey == "obligation.signing.linumicos-mac-profile" })
        #expect(profile.item.evidence.source.contains("NEXT-ACTIONS-2026-10-19.md:147"))
        #expect(profile.item.due == day("2027-09-23"))
        #expect(profile.item.destination == .screen(.obligation("signing.linumicos-mac-profile")))
        #expect(profile.item.obligationID == "signing.linumicos-mac-profile")
        #expect(profile.item.domain == .linumicOS)
    }

    @Test func aRestoreTestsDueDayIsInOneSectionOrTheOther() throws {
        // Last test 2026-07-21: due 2026-10-19, 90 days on. The Obligations section has it up to and on its day ("due
        // today", high); Keys & Backups from the day after. No day is in neither.
        var reg = KeysRegistry.seed
        let backup = reg.backups[0]
        reg.backups[0].restoreTests = [RestoreTest(on: day("2026-07-21"), by: "Owner", source: "test")]
        let register = build(live: ObligationLiveInput(keys: reg))
        let o = try #require(register.obligation("keys.restore.\(backup.id)"))
        #expect(o.due == day("2026-10-19"))
        func keysFlags(_ d: String) -> Bool {
            let input = KeysCheckInput(registry: reg, now: day(d).start(calendar: utc).addingTimeInterval(12 * 3600), calendar: utc)
            return KeysRules.reminders(input).contains { $0.kind == .restoreTestDue && $0.backupID == backup.id }
        }
        for d in ["2026-10-18", "2026-10-19", "2026-10-20"] {
            let shown = ObligationsBriefRules.showsInBrief(o, today: day(d))
            #expect(shown != keysFlags(d), "\(d): exactly one section says it")
        }
        #expect(ObligationsBriefRules.showsInBrief(o, today: day("2026-10-19")))
        #expect(ObligationsBriefRules.severity(o, today: day("2026-10-19")) == .high)
        #expect(ObligationsBriefRules.text(o, today: day("2026-10-19")).hasSuffix("(due today)"))
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
        // Its date is not unknown: P0 makes it due now.
        #expect(line.text == "No encrypted copy of Linumic OS data off this Mac yet (to do now)")
        // It closes only through its source: its Done goes to the Continuity screen, never to the evidence sheet.
        #expect(line.obligationID == "continuity.export")
        #expect(line.closesAtSource)
        // An obligation the owner closes with evidence does not.
        #expect(section.lines.first { $0.id == "obligation.marketing.worktrack-queue-end" }?.closesAtSource == false)
    }

    @Test func aTypedDoneNeverClosesTheContinuityRow() throws {
        // "I think I copied it", with no export in the log: the row stays open, on the Desk and in the Brief, and the
        // Done is reported as not applied.
        var file = ObligationsFile()
        try file.complete("continuity.export", due: nil, on: today, evidence: "I think I copied it", now: now, calendar: utc)
        let register = build(file, live: ObligationLiveInput(continuity: ContinuityLog()))
        let export = try #require(register.obligation("continuity.export"))
        #expect(!export.isClosed)
        #expect(ObligationRules.lane(export, today: today) == .dateUnknown)
        #expect(register.issues.contains(.doneNotApplied("continuity.export")))
        let section = DailyBriefBuilder.obligations(briefInput(register))
        #expect(section.lines.contains { $0.id == "obligation.continuity.export" })
        // Once dated, a Done for its due day does not silence the 30-day reminder either.
        var log = ContinuityLog()
        log.add(ContinuityExportRecord(fileName: "linumic-os-continuity-2026-10-19-1200.json.age", folder: "USB", folderKind: .external,
                                       createdAt: now, verifiedAt: now, fileBytes: 1, fileSHA256: "a", plaintextBytes: 1,
                                       plaintextSHA256: "b", workFactor: 18, formatVersion: 1, counts: [:]))
        var dated = ObligationsFile()
        try dated.complete("continuity.export", due: day("2026-11-18"), on: today, evidence: "done", now: now, calendar: utc)
        let next = try #require(build(dated, live: ObligationLiveInput(continuity: log)).obligation("continuity.export"))
        #expect(next.due == day("2026-11-18") && !next.isClosed)
        // The same holds for every live row: a licence closes when the ledger records its renewal.
        let licence = row("licence.KY-1", due: "2026-11-01", origin: .licence)
        var licenceDone = ObligationsFile()
        try licenceDone.complete("licence.KY-1", due: day("2026-11-01"), on: today, evidence: "renewed", now: now, calendar: utc)
        let r = build(licenceDone, seed: [licence], accounts: [])
        #expect(r.obligation("licence.KY-1")?.isClosed == false)
        #expect(r.issues == [.doneNotApplied("licence.KY-1")])
    }

    @Test func anExportOnThisMacIsNotACopyOffIt() throws {
        // One verified export to ~/Documents (this Mac's own disk), one to a folder whose place is not known, one to a
        // cloud folder that was never opened outside this Mac (its local copy reads back whether or not it was uploaded).
        for kind in [ContinuityFolderKind.thisMac, .unknown, .cloud] {
            var log = ContinuityLog()
            log.add(ContinuityExportRecord(fileName: "linumic-os-continuity-2026-10-19-1200.json.age", folder: "~/Documents", folderKind: kind,
                                           createdAt: now, verifiedAt: now, fileBytes: 1, fileSHA256: "a", plaintextBytes: 1,
                                           plaintextSHA256: "b", workFactor: 18, formatVersion: 1, counts: [:]))
            #expect(log.lastVerified != nil && log.lastVerifiedOffMac == nil)
            #expect(log.nextExportDue(calendar: utc) == nil)
            let register = build(live: ObligationLiveInput(continuity: log))
            let export = try #require(register.obligation("continuity.export"))
            #expect(export.due == nil, "\(kind)")
            #expect(export.title == "No encrypted copy of Linumic OS data off this Mac yet")
            #expect(export.source.contains("linumic-os-continuity-2026-10-19-1200.json.age"))   // the copy on this Mac is named
            let line = try #require(DailyBriefBuilder.obligations(briefInput(register)).lines.first { $0.id == "obligation.continuity.export" })
            #expect(line.severity == .normal)   // still This week on the Desk
            #expect(export.source.contains("cloud folder") == (kind == .cloud))
        }
    }

    @Test func aCloudExportCountsOnceItWasOpenedOutsideThisMac() throws {
        var log = ContinuityLog()
        let record = ContinuityExportRecord(fileName: "linumic-os-continuity-2026-10-19-1200.json.age", folder: "~/Library/CloudStorage/GoogleDrive-x/Mohem",
                                            folderKind: .cloud, createdAt: now, verifiedAt: now, fileBytes: 1, fileSHA256: "a",
                                            plaintextBytes: 1, plaintextSHA256: "b", workFactor: 18, formatVersion: 1, counts: [:])
        log.add(record)
        #expect(log.exports[0].uploadNotChecked && log.lastVerifiedOffMac == nil)
        try log.recordOutsideCheck(record.id, on: day("2026-10-20"), evidence: "age -d on the office PC; SHA-256 matched",
                                   now: now.addingTimeInterval(86_400), calendar: utc)
        #expect(!log.exports[0].uploadNotChecked && log.lastVerifiedOffMac?.id == record.id)
        // Due 30 days after the export itself.
        #expect(build(live: ObligationLiveInput(continuity: log)).obligation("continuity.export")?.due == day("2026-11-18"))
        // An external drive needs no outside check.
        var usb = record
        usb.folderKind = .external
        usb.outsideChecks = []
        #expect(usb.isKnownOffThisMac)
    }

    @Test func aDeskDoneOnTheContinuityRowDoesNotHideItForGood() throws {
        func desk(at time: Date, state: DeskState) -> Desk {
            let register = ObligationsBuilder.build(file: ObligationsFile(), live: ObligationLiveInput(continuity: ContinuityLog()),
                                                    now: time, calendar: utc)
            let input = BriefInput(now: time, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                                   licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                                   operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
                                   obligations: BriefObligationsInput(register: register))
            let brief = DailyBrief(sections: [DailyBriefBuilder.obligations(input)], generatedAt: time)
            return DeskBuilder.build(brief: brief, ledgers: .unsupported, state: state, now: time, calendar: utc)
        }
        let first = desk(at: now, state: DeskState())
        let row = try #require(first.open.first { $0.item.subjectKey == "obligation.continuity.export" })
        #expect(row.item.obligationID == "continuity.export")
        #expect(row.item.closesAtSource)   // the Desk's Done opens Continuity
        // Should a plain Done reach it anyway, it hides only until the next Brief, which reads the log again.
        var state = DeskState()
        state.markDone(row.item, now: now)
        #expect(desk(at: now, state: state).hidden.contains { $0.item.id == row.item.id })
        let next = desk(at: now.addingTimeInterval(30 * 60), state: state)
        let back = try #require(next.open.first { $0.item.id == row.item.id })
        guard case .reopened = back.resolution else { Issue.record("expected it back as still open, got \(back.resolution)"); return }
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
        let o = row("owner.x", due: "2026-11-15")
        let early = DailyBriefBuilder.obligations(briefInput(build(ObligationsFile(added: [o]), seed: [], accounts: [])))
        let later = DailyBriefBuilder.obligations(BriefInput(now: now.addingTimeInterval(20 * 86_400), monitor: MonitorSnapshot(),
                                                             releases: ReleaseCenterSnapshot(),
                                                             licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                                             worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                                                             operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
                                                             obligations: BriefObligationsInput(register: build(ObligationsFile(added: [o]), seed: [], accounts: []))))
        let a = early.lines.first { $0.id == "obligation.owner.x" }!
        let b = later.lines.first { $0.id == "obligation.owner.x" }!
        #expect(a.severity == .info && b.severity == .normal)
        #expect(DeskBuilder.factHash(a) != DeskBuilder.factHash(b))
        // A new due day alone is a new fact too: a "waiting" mark on one day does not hide the next.
        var moved = a
        moved.due = day("2026-11-16")
        #expect(moved.severity == a.severity && moved.id == a.id)
        #expect(DeskBuilder.factHash(a) != DeskBuilder.factHash(moved))
    }
}

@Suite("Obligation alerts at the lead days")
struct ObligationAlertTests {
    @Test func eachWindowAlertsOnceWithTheSharedKey() {
        let register = build(ObligationsFile(added: [row("owner.bill", due: "2026-10-26"), row("owner.unknown", due: nil),
                                                     row("owner.far", due: "2027-06-01")]), seed: [], accounts: [])
        let first = ObligationAlerts.due(register, today: today, sent: [])
        #expect(first.map(\.key) == ["obligation:owner.bill:2026-10-26:7"])
        #expect(ObligationAlerts.due(register, today: today, sent: Set(first.map(\.key))).isEmpty)
        // The next window is a new alert; the day itself and after it too.
        #expect(ObligationAlerts.due(register, today: day("2026-10-25"), sent: Set(first.map(\.key))).map(\.key)
                == ["obligation:owner.bill:2026-10-26:1"])
        #expect(ObligationAlerts.due(register, today: day("2026-10-28"), sent: []).map(\.lead) == [0])
    }

    @Test func liveAndClosedRowsDoNotAlertHere() throws {
        var file = ObligationsFile(added: [row("owner.paid", due: "2026-10-20")])
        try file.complete("owner.paid", due: day("2026-10-20"), on: today, evidence: "receipt", now: now, calendar: utc)
        let live = row("licence.X", due: "2026-10-21", origin: .licence)
        let register = build(file, seed: [live], accounts: [])
        #expect(ObligationAlerts.due(register, today: today, sent: []).isEmpty)
    }
}
