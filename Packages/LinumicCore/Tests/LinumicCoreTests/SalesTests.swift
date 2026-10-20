import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. worktrack-crm-accounts-sales.json, worktrack-companies-sales.json and worktrack-crm-contacts.json
// are written by hand to WorkTrack's schemas (services/crm.ts and services/vendor.ts at 0403fd0); every name, note and
// number in them is made up (SAMPLE, SENTINEL). No request leaves the process.

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// 2026-10-20 12:30 in Kabul.
private let now = at("2026-10-20T08:00:00Z")
private let readAt = at("2026-10-20T07:58:00Z")
private var utc: Calendar { calendar("UTC") }

private func calendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private struct Envelope<T: Decodable>: Decodable { let data: T }

private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(Envelope<T>.self, from: try fixture(name)).data
}

private func accounts() throws -> WTLossyList<WTCrmAccount> { try decode(WTLossyList<WTCrmAccount>.self, "worktrack-crm-accounts-sales") }
private func companies() throws -> [WTCompany] { try decode([WTCompany].self, "worktrack-companies-sales") }

private func worktrack(env: String = "production", companies list: [WTCompany]? = nil, accounts read: MoneyRead<WTLossyList<WTCrmAccount>>? = nil,
                       accountsAt: Date = readAt, signedIn: Bool = true, loadError: String? = nil) throws -> MoneyWorkTrackInput {
    let money = WorkTrackMoneyRead(revenue: .failed("not used by Sales", at: accountsAt, needsSignIn: false),
                                   accounts: try read ?? .read(accounts(), at: accountsAt),
                                   invoices: .failed("not used by Sales", at: accountsAt, needsSignIn: false))
    return MoneyWorkTrackInput(isSignedIn: signedIn, environment: env, companies: try list ?? companies(), companiesReadAt: readAt,
                               loadError: loadError, money: money)
}

private func part(_ w: MoneyWorkTrackInput, at time: Date = now) -> SalesWorkTrack? {
    SalesBuilder.worktrack(w, today: WorkTrackDates.kabulToday(time)).value
}

private func section(_ w: MoneyWorkTrackInput?, at time: Date = now) -> BriefSection { SalesBrief.section(w, now: time) }

private func desk(_ w: MoneyWorkTrackInput?, state: DeskState = DeskState(), at time: Date = now, calendar: Calendar = utc) -> Desk {
    DeskBuilder.build(brief: DailyBrief(sections: [section(w, at: time)], generatedAt: time), ledgers: .unsupported, state: state,
                      now: time, calendar: calendar)
}

private func key(_ accountID: String) -> String { "sales.followup." + SalesKey.account(accountID) }
private func deskID(_ lineID: String) -> String { "brief.sales|\(lineID)|fact" }

// MARK: - Decoding

@Suite("Sales: the CRM account, widened")
struct SalesDecodeTests {
    @Test func stageDateAndNextStepAreDecodedNothingElse() throws {
        let list = try accounts()
        #expect(list.rows.count == 21 && list.skipped == 0, "no Sales field ever sets a row aside")
        let lead = try #require(list.rows.first { $0.id == "acc_lead_today" })
        #expect(lead.stage == .lead && lead.nextActionAt == .day("2026-10-20") && lead.nextAction == "SENTINEL-NEXTACTION")
        let text = String(describing: list)
        for never in ["SENTINEL-NOTES", "SENTINEL-CITY", "SENTINEL-PHONE-VALUE", "vendor-uid-sample", "2026-09-01T08"] {
            #expect(!text.contains(never), "\(never) is never held")
        }
    }

    @Test func aBadValueIsUnknownForItsFieldOnly() throws {
        let list = try accounts()
        func row(_ id: String) -> WTCrmAccount? { list.rows.first { $0.id == id } }
        #expect(row("acc_number")?.nextActionAt == .unreadable)
        #expect(row("acc_stage_number")?.stage == nil)
        #expect(row("acc_paused")?.stage?.rawValue == "PAUSED" && row("acc_paused")?.stage?.isKnown == false)
        #expect(row("acc_blank")?.companyId == nil, "a blank link is no link")
        // Money's own fixture still reads the same.
        let money = try decode(WTLossyList<WTCrmAccount>.self, "worktrack-crm-accounts")
        #expect(money.rows.count == 6 && money.skipped == 0)
    }

    @Test func nextActionAtCases() throws {
        func day(_ json: String) throws -> WTCrmDay {
            try JSONDecoder().decode(WTCrmAccount.self, from: Data(#"{"id":"a","name":"n"\#(json)}"#.utf8)).nextActionAt
        }
        #expect(try day("") == WTCrmDay.none)
        #expect(try day(#","nextActionAt":null"#) == WTCrmDay.none)
        #expect(try day(#","nextActionAt":"2026-10-20""#) == .day("2026-10-20"))
        #expect(try day(#","nextActionAt":"2026-02-31""#) == .notADay("2026-02-31"))
        #expect(try day(#","nextActionAt":"2026-1-5""#) == .notADay("2026-1-5"))
        #expect(try day(#","nextActionAt":"""#) == .notADay(""))
        #expect(try day(#","nextActionAt":20261020"#) == .unreadable)
        #expect(try day(#","nextActionAt":"۲۰۲۶-۱۰-۲۰""#) == .notADay("۲۰۲۶-۱۰-۲۰"), "ASCII digits only")
    }
}

// MARK: - Kabul's day

@Suite("Sales: Kabul's day, as the server counts it")
struct SalesDayTests {
    @Test func kabulToday() {
        #expect(WorkTrackDates.kabulToday(at("2026-10-19T19:29:59Z")) == "2026-10-19")
        #expect(WorkTrackDates.kabulToday(at("2026-10-19T19:30:00Z")) == "2026-10-20")
        #expect(WorkTrackDates.kabulToday(at("2026-12-31T19:30:00Z")) == "2027-01-01")
        #expect(WorkTrackDates.kabulToday(at("2027-03-20T19:30:00Z")) == "2027-03-21")
    }

    @Test func classification() {
        let today = "2026-10-20"
        #expect(SalesBuilder.due(.none, today: today) == nil)
        #expect(SalesBuilder.due(.day("2026-10-20"), today: today) == .dueNow(overdueDays: 0))
        #expect(SalesBuilder.due(.day("2026-10-01"), today: today) == .dueNow(overdueDays: 19))
        #expect(SalesBuilder.due(.day("2026-10-21"), today: today) == .dueSoon(inDays: 1))
        #expect(SalesBuilder.due(.day("2026-10-27"), today: today) == .dueSoon(inDays: 7), "the boundary is inclusive")
        #expect(SalesBuilder.due(.day("2026-10-28"), today: today) == .later(inDays: 8))
        #expect(SalesBuilder.due(.notADay("2026-02-31"), today: today) == .dateUnknown(raw: "2026-02-31"))
        #expect(SalesBuilder.due(.notADay("2026-1-5"), today: today) == .dateUnknown(raw: "2026-1-5"))
        #expect(SalesBuilder.due(.unreadable, today: today) == .dateUnknown(raw: nil))
    }

    /// `crm.ts:252-272` for every pair of real days in two months: text comparison, and today + 7 at UTC midnight.
    @Test func matchesTheServerForEveryDay() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        let days = (0..<61).map { f.string(from: at("2026-10-01T00:00:00Z").addingTimeInterval(Double($0) * 86_400)) }
        #expect(days.last == "2026-11-30")
        for today in days {
            let inSeven = f.string(from: at("\(today)T00:00:00Z").addingTimeInterval(7 * 86_400))
            for d in days {
                let due = SalesBuilder.due(.day(d), today: today)
                let server: String = d <= today ? "now" : d <= inSeven ? "soon" : "later"
                let ours: String = switch due {
                case .dueNow?: "now"
                case .dueSoon?: "soon"
                default: "later"
                }
                #expect(ours == server, "\(today) \(d)")
            }
        }
        #expect(WorkTrackDates.addDays("2026-02-25", 7) == "2026-03-04")
        #expect(WorkTrackDates.addDays("2028-02-26", 7) == "2028-03-04")
        #expect(WorkTrackDates.addDays("2027-01-01", 7) == "2027-01-08")
    }

    /// The Desk bucket follows Kabul's day in every device time zone, never the device's own day.
    @Test(arguments: [
        ("America/Toronto", "2026-10-19T19:30:00Z", "2026-10-20", DeskBucket.today),
        ("Pacific/Kiritimati", "2026-10-19T10:00:00Z", "2026-10-20", DeskBucket.thisWeek),
        ("Asia/Kabul", "2026-10-19T19:30:00Z", "2026-10-21", DeskBucket.thisWeek),
        ("Pacific/Pago_Pago", "2026-10-19T19:30:00Z", "2026-10-20", DeskBucket.today),
    ])
    func deskBucketIsKabulsInEveryTimeZone(zone: String, time: String, nextActionAt: String, bucket: DeskBucket) throws {
        let list = WTLossyList(rows: [WTCrmAccount(id: "acc_tz", name: "TZ Lead (SAMPLE)", stage: .lead, nextActionAt: .day(nextActionAt))])
        let d = desk(try worktrack(companies: [], accounts: .read(list, at: at(time)), accountsAt: at(time)), at: at(time), calendar: calendar(zone))
        let row = try #require(d.row(deskID(key("acc_tz"))))
        #expect(row.bucket == bucket, "\(zone)")
        #expect(row.item.due == nil, "a Sales item carries no day for the device to compare")
    }

    @Test func daysShowTheSameInEveryTimeZone() {
        let en = Locale(identifier: "en_US")
        let texts = ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Kabul", "UTC"].map {
            WorkTrackDates.displayText("2026-10-20", calendar: calendar($0), locale: en)
        }
        #expect(Set(texts).count == 1 && texts[0].contains("20"), "\(texts)")
        #expect(WorkTrackDates.displayText("2026-02-31") == "2026-02-31", "not a day: shown as stored")
    }
}

// MARK: - What is listed

@Suite("Sales: follow-ups, TEST companies, signups and limits")
struct SalesBuilderTests {
    @Test func followUpsAndNoNextStep() throws {
        let wt = try #require(part(try worktrack()))
        #expect(wt.callToday.map(\.account.accountID) == ["acc_overdue", "acc_dangling", "acc_lead_today", "acc_won_due"],
                "most overdue first, then by name; a WON account with a date is listed, as WorkTrack's own dashboard does")
        #expect(wt.thisWeek.map(\.account.accountID) == ["acc_soon1", "acc_blank", "acc_soon7"])
        #expect(wt.later.map(\.account.accountID) == ["acc_later"])
        #expect(Set(wt.dateUnknown.map(\.account.accountID)) == ["acc_feb31", "acc_short", "acc_number"])
        // The done criterion in code: a LEAD with no date still reaches the Desk, as "no next step".
        #expect(Set(wt.noNextStep.map(\.accountID)) == ["acc_nodate_null", "acc_nodate_absent", "acc_paused", "acc_stage_number"])
        let listed = Set(wt.followUps.map(\.account.accountID) + wt.noNextStep.map(\.accountID))
        for never in ["acc_won_nodate", "acc_lost", "acc_dormant", "acc_support_trial"] { #expect(!listed.contains(never)) }
    }

    @Test func testAndDuplicateCompaniesAreLeftOut() throws {
        let wt = try #require(part(try worktrack()))
        #expect(Set(wt.leftOut.map(\.accountID)) == ["acc_test", "acc_dup"], "TEST with a date, DUPLICATE with no next step")
        let all = Set(wt.followUps.map(\.account.accountID) + wt.noNextStep.map(\.accountID))
        #expect(!all.contains("acc_test") && !all.contains("acc_dup"))
        let dangling = try #require(wt.followUps.first { $0.account.accountID == "acc_dangling" })
        #expect(dangling.account.company == .notListed && wt.notListed == 1)
        let s = section(try worktrack())
        #expect(!s.lines.contains { $0.text.contains("Test Lead") || $0.text.contains("Duplicate Lead") })
        #expect(s.notes.contains("Left out: 2 CRM accounts of TEST or DUPLICATE companies."))
        #expect(s.lines.first { $0.id == key("acc_dangling") }?.detail?.contains("whether it is a TEST company is unknown") == true)
    }

    @Test func withoutTheCompanyListNothingIsShownUnfiltered() throws {
        #expect(SalesBuilder.worktrack(try worktrack(loadError: "HTTP 500"), today: "2026-10-20").value == nil)
        var w = try worktrack()
        w.companiesReadAt = nil
        #expect(SalesBuilder.worktrack(w, today: "2026-10-20").value == nil)
        #expect(section(w).lines.isEmpty)
    }

    @Test func signupsDays14And15SelfServeDeletionAndSupportAccounts() throws {
        let wt = try #require(part(try worktrack()))
        let signups = try #require(wt.signups.value)
        #expect(signups.isComplete)
        #expect(signups.rows.map(\.company.companyId) == ["c_trial_new", "c_trial_day14", "c_selfserve"])
        #expect(signups.rows[0].reason == .newSignup(createdDay: "2026-10-17"))
        #expect(signups.rows[1].reason == .newSignup(createdDay: "2026-10-06"), "19:30 UTC is midnight in Kabul: day 14, still new")
        #expect(signups.rows[2].reason == .selfServe, "bought a plan itself, 200 days ago")
        #expect(signups.rows[0].isOnDeskAsRenewal && signups.rows[1].isOnDeskAsRenewal && !signups.rows[2].isOnDeskAsRenewal)
        let without = try #require(wt.withoutCRMAccount.value)
        #expect(without.rows.map(\.companyId) == ["c_trial_day15", "c_expired_future", "c_null_created", "c_old_nocrm", "c_suspended"],
                "day 15 is not new; no creation day is not new")
        let all = Set(signups.rows.map(\.company.companyId) + without.rows.map(\.companyId))
        #expect(!all.contains("c_deleting"), "a scheduled deletion is no one to call")
        #expect(!all.contains("c_test") && !all.contains("c_dup") && !all.contains("c_paid"))
        // A trial that opened a support ticket has a WON account WorkTrack made itself: still a signup.
        #expect(signups.rows.contains { $0.company.companyId == "c_trial_new" })
    }

    /// The support-ticket exception decides who is a new signup, nothing else: an older trial whose only account is
    /// that WON one has an account, so it is not counted as "no CRM account".
    @Test func aSupportAccountStillCountsAsAnAccount() throws {
        var old = try #require((try companies()).first { $0.companyId == "c_trial_new" })
        old.companyId = "c_old_trial"
        old.createdAt = "2026-09-01T06:00:00.000Z"
        let support = WTCrmAccount(id: "acc_old_support", name: "Old Trial (SAMPLE)", companyId: "c_old_trial", stage: .won)
        let wt = try #require(part(try worktrack(companies: [old], accounts: .read(WTLossyList(rows: [support]), at: readAt))))
        #expect(old.isTrial && wt.signups.value?.rows.isEmpty == true, "49 days old: not new")
        #expect(wt.withoutCRMAccount.value?.rows.isEmpty == true, "it has an account")
        // The same trial with no account at all is "without one".
        let none = try #require(part(try worktrack(companies: [old], accounts: .read(WTLossyList(rows: []), at: readAt))))
        #expect(none.withoutCRMAccount.value?.rows.map(\.companyId) == ["c_old_trial"])
    }

    @Test func aNewTrialIsOneDeskItemNotTwo() throws {
        let s = section(try worktrack())
        let signupLines = s.lines.filter { $0.id.hasPrefix("sales.signup.") }
        #expect(signupLines.map(\.id) == ["sales.signup." + SalesKey.company("c_selfserve")],
                "the trials are WorkTrack trial items already; only the self-serve company is a Sales item")
        #expect(s.notes.contains("2 new signups are on the Desk as WorkTrack trials ending; the Sales page lists them."))
    }

    @Test func limitsMakeTheCountsUnknownOrAtLeast() throws {
        // 2000 accounts: whether a company has one is unknown.
        let many = WTLossyList(rows: (0..<2000).map { WTCrmAccount(id: "a\($0)", name: "n\($0)", stage: .won) })
        let atLimit = try #require(part(try worktrack(accounts: .read(many, at: readAt))))
        #expect(atLimit.accountsAtLimit && atLimit.signups.value == nil && atLimit.withoutCRMAccount.value == nil)
        #expect(atLimit.signups.reason == LF("WorkTrack sent %ld CRM accounts, the most it sends, so whether a company has a CRM account is unknown.", 2000))
        // One account set aside: the same.
        var skipped = try accounts()
        skipped.skipped = 1
        let one = try #require(part(try worktrack(accounts: .read(skipped, at: readAt))))
        #expect(one.signups.value == nil && one.withoutCRMAccount.value == nil && one.signups.reason?.contains("1 CRM accounts") == true)
        #expect(section(try worktrack(accounts: .read(skipped, at: readAt))).lines.allSatisfy { !$0.id.hasPrefix("sales.signup.") && $0.id != "sales.nocrm" })
        // The follow-up lists are then "at least", and the page says why (never "none").
        let whole = try #require(part(try worktrack()))
        #expect(!one.accountsComplete && !atLimit.accountsComplete && whole.accountsComplete)
        #expect(SalesBrief.accountsCaveats(one) == ["1 CRM accounts could not be read; their follow-ups, and whether a company has a CRM account, are unknown."])
        #expect(SalesBrief.accountsCaveats(atLimit) == [LF("WorkTrack sent %ld CRM accounts, the most it sends; newer accounts past that, and their follow-ups, are unknown.", 2000)])
        #expect(SalesBrief.accountsCaveats(whole).isEmpty)
        let noDate = section(try worktrack(accounts: .read(skipped, at: readAt))).lines.first { $0.id == "sales.nodate" }
        #expect(noDate?.text == "At least 4 open CRM accounts have no next-action date")
        // 500 companies: signups found are listed, and the rest is "at least".
        let base = try companies()
        let filler = (0..<(500 - base.count)).map { i -> WTCompany in
            var c = base.first { $0.companyId == "c_old_nocrm" }!
            c.companyId = "c_fill_\(i)"
            c.name = "Filler \(i) (SAMPLE)"
            return c
        }
        let s = section(try worktrack(companies: base + filler))
        let full = try #require(part(try worktrack(companies: base + filler)))
        #expect(full.companiesAtLimit && full.signups.value?.isComplete == false && full.signups.value?.rows.count == 3)
        #expect(s.lines.first { $0.id == "sales.nocrm" }?.text == "At least \(5 + filler.count) WorkTrack companies have no CRM account")
    }

    @Test func renewalsAreKnownOrUnknownWithAReason() throws {
        let report = SalesBuilder.build(SalesInput(worktrack: try worktrack()), now: now)
        let renewals = try #require(report.renewals.value)
        let rows = renewals.list.rows
        #expect(rows.map(\.company.companyId) == ["c_expired_future", "c_trial_day15", "c_trial_day14", "c_trial_new"],
                "a scheduled deletion is no one to call")
        #expect(renewals.deletionsLeftOut == 1 && renewals.list.isComplete)
        #expect(renewals.environment == "production" && renewals.readAt == readAt, "the company list's source and time")
        #expect(rows.first { $0.company.companyId == "c_trial_day15" }?.daysLeft == -1)
        // Days are "left" only while the licence is in force.
        func timing(_ id: String) -> SalesRenewal.Timing? { rows.first { $0.company.companyId == id }?.timing }
        #expect(timing("c_expired_future") == .notInForce, "EXPIRED with its last day ahead: no days left")
        #expect(timing("c_trial_day15") == .ended(daysAgo: 1))
        #expect(timing("c_trial_new").map { if case .daysLeft = $0 { true } else { false } } == true)
        // Without the CRM accounts, renewals are still read, with the list's own source.
        let failed = SalesBuilder.build(SalesInput(worktrack: try worktrack(accounts: .failed("HTTP 502", at: readAt, needsSignIn: false))), now: now)
        #expect(failed.worktrack.value == nil && failed.renewals.value?.readAt == readAt)
        let signedOut = SalesBuilder.build(SalesInput(worktrack: MoneyWorkTrackInput(isSignedIn: false, environment: nil)), now: now)
        #expect(signedOut.renewals.value == nil && signedOut.renewals.reason == "Not signed in to WorkTrack customers, so renewals are unknown.")
        #expect(signedOut.worktrack.reason == "Not signed in to WorkTrack, so who to call is unknown.")
        #expect(signedOut.siteMessages.reason != nil && signedOut.kyc.reason != nil, "never an empty list")
    }

    @Test func kycProvidersExactOrAtLeast() {
        let exact = SalesBuilder.kyc(SalesKYCInput(isSignedIn: true, environment: "production", pendingCount: 7,
                                                   queueRoles: ["PROVIDER", "CUSTOMER", "PROVIDER", "CUSTOMER", "PROVIDER", "CUSTOMER", "CUSTOMER"],
                                                   readAt: now))
        #expect(exact.value == SalesKYC(providers: 3, isExact: true, queueRead: 7, pending: 7, environment: "production", readAt: now))
        let page = SalesBuilder.kyc(SalesKYCInput(isSignedIn: true, environment: "production", pendingCount: 140,
                                                  queueRoles: Array(repeating: "PROVIDER", count: 100), readAt: now))
        #expect(page.value?.providers == 100 && page.value?.isExact == false && page.value?.queueRead == 100)
        // A count that moved between the two reads: "at least", among the people actually read.
        let drift = SalesBuilder.kyc(SalesKYCInput(isSignedIn: true, environment: "production", pendingCount: 9,
                                                   queueRoles: ["PROVIDER", "CUSTOMER"], readAt: now))
        #expect(drift.value?.isExact == false && drift.value?.queueRead == 2)
        #expect(SalesBuilder.kyc(SalesKYCInput(isSignedIn: false, environment: nil)).reason != nil)
        #expect(SalesBuilder.kyc(SalesKYCInput(isSignedIn: true, environment: "production", loadError: "HTTP 503")).reason == "SafeBeauty could not be read: HTTP 503")
    }
}

// MARK: - The Brief section and the Desk

@Suite("Sales: the Brief section and its Desk items")
struct SalesBriefTests {
    @Test func linesSeveritiesAndHorizons() throws {
        let s = section(try worktrack())
        func line(_ id: String) -> BriefLine? { s.lines.first { $0.id == id } }
        let today = try #require(line(key("acc_lead_today")))
        #expect(today.text == "Call today: Lead Today (SAMPLE)" && today.severity == .normal && today.horizon == .today && today.due == nil)
        #expect(line(key("acc_overdue"))?.text.hasPrefix("Follow-up overdue: Overdue Tailors (SAMPLE)") == true)
        #expect(line(key("acc_soon1"))?.severity == .info && line(key("acc_soon1"))?.horizon == .thisWeek)
        #expect(line(key("acc_later")) == nil, "more than 7 days away: the page only")
        #expect(line(key("acc_feb31"))?.text == "The next-action date of Bad Day (SAMPLE) could not be read (2026-02-31)")
        #expect(line(key("acc_number"))?.text == "The next-action date of Number Day (SAMPLE) could not be read")
        #expect(line(key("acc_dangling"))?.severity == .info && line(key("acc_dangling"))?.horizon == .today,
                "a company not in the list: on the Desk by its day, out of the notification")
        #expect(line("sales.nodate")?.text == "4 open CRM accounts have no next-action date" && line("sales.nodate")?.severity == .normal)
        #expect(line("sales.nocrm")?.text == "5 WorkTrack companies have no CRM account" && line("sales.nocrm")?.severity == .info)
        #expect(today.detail?.contains("SENTINEL-NEXTACTION") == true, "the owner's note, on this device")
        #expect(today.detail?.contains("Done here does not change the CRM") == true)
        #expect(today.source == "WorkTrack (production): GET /v1/vendor/crm/accounts" && today.readAt == readAt)
        #expect(today.links.first?.url == URL(string: "https://console.linumic.com/") && today.destination == .sales(SalesKey.account("acc_lead_today")))
        #expect(s.gaps.isEmpty && s.state == .items)
    }

    @Test func theDeskPutsThemByKabulsDay() throws {
        let d = desk(try worktrack())
        func bucket(_ id: String) -> DeskBucket? { d.row(deskID(id))?.bucket }
        #expect(bucket(key("acc_lead_today")) == .today && bucket(key("acc_overdue")) == .today)
        #expect(bucket(key("acc_soon7")) == .thisWeek)
        #expect(bucket(key("acc_feb31")) == .today, "a date that could not be read is the owner's work today")
        #expect(bucket("sales.nodate") == .today && bucket("sales.nocrm") == .later)
        #expect(d.row(deskID(key("acc_lead_today")))?.item.domain == .worktrack)
    }

    @Test func notProductionIsInformationOnly() throws {
        let s = section(try worktrack(env: "demo"))
        #expect(!s.lines.isEmpty && s.lines.allSatisfy { $0.severity == .info && $0.horizon == nil && $0.links.isEmpty })
        let gap = try #require(s.gaps.first { $0.key == "worktrack.production" })
        #expect(gap.isCaveat && !gap.isDeskItem && s.notes.contains("Read from the demo environment, not production."))
        let d = desk(try worktrack(env: "demo"))
        #expect(!d.open.contains { $0.id.contains("part.worktrack.production") }, "WorkTrack customers raises it already")
        #expect(d.today.allSatisfy { !$0.id.hasPrefix("brief.sales|") })
    }

    @Test func oneCauseIsOneItemInLater() throws {
        for w in [MoneyWorkTrackInput(isSignedIn: false, environment: nil), try worktrack(loadError: "HTTP 500"), nil] {
            let d = desk(w)
            let sales = d.open.filter { $0.id.hasPrefix("brief.sales|") }
            #expect(sales.map(\.id) == ["brief.sales|section|not-read"])
            #expect(sales.first?.bucket == .later && sales.first?.item.domain == .shared)
        }
        // Failed CRM accounts: Money's own item (WorkTrack) is the one in This week; Sales adds one in Later.
        let failed = try worktrack(accounts: .failed("HTTP 502", at: readAt, needsSignIn: false))
        #expect(section(failed).state == .neverRead("The CRM accounts could not be read: HTTP 502"))
        let sales = desk(failed).open.filter { $0.id.hasPrefix("brief.sales|") }
        #expect(sales.map(\.id) == ["brief.sales|section|not-read"] && sales.first?.bucket == .later)
    }

    @Test func limitNoticesAreCaveatsAndMakeNoSecondItem() throws {
        let many = WTLossyList(rows: (0..<2000).map { WTCrmAccount(id: "a\($0)", name: "n\($0)", stage: .won) })
        let w = try worktrack(accounts: .read(many, at: readAt))
        let s = section(w)
        let gap = try #require(s.gaps.first { $0.key == "worktrack.accounts.limit" })
        #expect(gap.isCaveat && !gap.isDeskItem && s.notes.contains(gap.text))
        #expect(desk(w).open.filter { $0.id.hasPrefix("brief.sales|part.") }.isEmpty, "Money raises the 2000-account limit")
        var skipped = try accounts()
        skipped.skipped = 2
        let items = desk(try worktrack(accounts: .read(skipped, at: readAt))).open.filter { $0.id.hasPrefix("brief.sales|part.") }
        #expect(items.map(\.id) == ["brief.sales|part.worktrack.accounts.skipped|not-read"])
        #expect(items.first?.item.detail == "This part was not read, so it is unknown here, not zero." && items.first?.bucket == .later)
    }

    @Test func idsCarryHashesNeverIDsOrNames() throws {
        let ids = try accounts().rows.map(\.id) + (try companies()).map(\.companyId)
        let names = try accounts().rows.map(\.name) + (try companies()).map(\.name)
        var skipped = try accounts()
        skipped.skipped = 1
        let desks = [desk(try worktrack()), desk(try worktrack(env: "demo")), desk(try worktrack(accounts: .read(skipped, at: readAt))),
                     desk(MoneyWorkTrackInput(isSignedIn: false, environment: nil))]
        let items = desks.flatMap { $0.open + $0.hidden }.map(\.item).filter { $0.id.hasPrefix("brief.sales|") }
        #expect(items.count > 15)
        // The proposed server check (docs/sales.md) and Phase 3's own (supabase/migrations/20261019090000_desk_sync.sql:159).
        let sales = /^brief\.sales\|(section|part\.[A-Za-z0-9._-]+|sales\.(followup|signup)\.[0-9a-f]{16}|sales\.(nodate|nocrm))\|[A-Za-z0-9._-]+$/
        let server = /^[a-z][A-Za-z0-9._-]*\|.+\|[A-Za-z0-9._-]+$/
        for item in items {
            #expect(item.id.wholeMatch(of: sales) != nil && item.id.wholeMatch(of: server) != nil && item.id.count <= 300, "\(item.id)")
            #expect(DeskCloudKey.cloud(item.id) == item.id, "already a hash: the cloud key is the id")
            for id in ids where id.count > 3 { #expect(!item.id.contains(id), "\(item.id) holds \(id)") }
            if item.kind != .fact {
                for name in names { #expect(!item.title.contains(name) && !(item.detail ?? "").contains(name)) }
            }
            let brief = DeskAgentBrief.text(for: item, now: now)
            for id in ids where id.count > 3 { #expect(!brief.contains(id)) }
            if item.kind == .fact {
                for name in names { #expect(!brief.contains(name), "the agent brief carries the hash only") }
                #expect(brief.contains(item.subjectKey) && !brief.contains("SENTINEL"))
            }
        }
    }

    @Test func theNotificationCountsFollowUpsAndNamesNoOne() throws {
        let s = section(try worktrack())
        let other = BriefSection(kind: .monitor, state: .items,
                                 lines: [BriefLine(id: "monitor.down.x", kind: .monitor, severity: .normal, text: "WorkTrack API is down",
                                                   source: "GET", readAt: now, destination: .monitor)],
                                 readAt: now, source: "monitor")
        let brief = DailyBrief(sections: [other, s], generatedAt: now)
        #expect(brief.attentionCount == 9, "8 Sales lines and 1 other: the count is not changed")
        let body = BriefNotificationText.content(brief, asOf: "08:00").body
        #expect(body.contains("9 items need you: WorkTrack API is down; 3 WorkTrack follow-ups are due; 5 other Sales items need you"), "\(body)")
        for name in try accounts().rows.map(\.name) + (try companies()).map(\.name) { #expect(!body.contains(name)) }
        // Only lines that are not follow-ups due: never called follow-ups.
        let undated = WTLossyList(rows: [WTCrmAccount(id: "x1", name: "Undated (SAMPLE)", stage: .lead),
                                         WTCrmAccount(id: "x2", name: "Bad (SAMPLE)", stage: .lead, nextActionAt: .notADay("2026-13-01"))])
        let mixed = DailyBrief(sections: [section(try worktrack(companies: [], accounts: .read(undated, at: readAt)))], generatedAt: now)
        let text = BriefNotificationText.content(mixed, asOf: "08:00").body
        #expect(text.contains("2 Sales items need you") && !text.contains("follow-ups are due"), "\(text)")
    }

    @Test func marksOnLinesThatAreGone() throws {
        let markTime = at("2026-10-20T08:10:00Z"), later = at("2026-10-20T09:00:00Z")
        let first = desk(try worktrack())
        let item = try #require(first.row(deskID(key("acc_lead_today")))?.item)
        var state = DeskState()
        state.markDone(item, now: markTime)
        var gone = try accounts()
        gone.rows.removeAll { $0.id == "acc_lead_today" }
        #expect(desk(try worktrack(accounts: .read(gone, at: later)), state: state, at: later).obsoleteMarks.contains(item.id))
        var setAside = gone
        setAside.skipped = 1
        #expect(!desk(try worktrack(accounts: .read(setAside, at: later)), state: state, at: later).obsoleteMarks.contains(item.id),
                "an account set aside may be the one: the mark is kept")
        #expect(desk(try worktrack(env: "demo", accounts: .read(gone, at: later)), state: state, at: later).obsoleteMarks.contains(item.id),
                "not production is no reason to keep a mark")
        #expect(!desk(MoneyWorkTrackInput(isSignedIn: false, environment: nil), state: state, at: later).obsoleteMarks.contains(item.id))
        #expect(!desk(try worktrack(accounts: .read(gone, at: readAt)), state: state, at: later).obsoleteMarks.contains(item.id),
                "not read since the mark")
    }

    @Test func aMovedDateIsANewFactANewNoteIsNot() throws {
        func hash(_ a: WTCrmAccount) throws -> String? {
            desk(try worktrack(accounts: .read(WTLossyList(rows: [a]), at: readAt))).row(deskID(key(a.id)))?.item.factHash
        }
        let a = WTCrmAccount(id: "acc_f", name: "Fact (SAMPLE)", stage: .lead, nextActionAt: .day("2026-10-20"), nextAction: "call")
        var moved = a; moved.nextActionAt = .day("2026-10-19")
        var noted = a; noted.nextAction = "call again"
        #expect(try hash(a) != nil && hash(a) != hash(moved) && hash(a) == hash(noted))
        // Done, then a later reading still shows it due: back, "still open".
        let item = try #require(desk(try worktrack(accounts: .read(WTLossyList(rows: [a]), at: readAt))).row(deskID(key("acc_f")))?.item)
        var state = DeskState()
        state.markDone(item, now: at("2026-10-20T08:01:00Z"))
        let again = desk(try worktrack(accounts: .read(WTLossyList(rows: [a]), at: at("2026-10-20T09:00:00Z"))), state: state,
                         at: at("2026-10-20T09:00:00Z"))
        #expect(again.row(item.id)?.resolution == .reopened(state.marks[item.id]!))
    }

    @Test func existingSectionsAreKept() {
        #expect(BriefSourceKind.allCases.firstIndex(of: .sales) == BriefSourceKind.allCases.firstIndex(of: .money)! + 1)
        #expect(SalesBrief.section(nil, now: now).state == .neverRead("Sales has not been collected on this device yet."))
    }
}

// MARK: - Dismiss reasons

@Suite("Sales: dismiss reasons are fixed, never typed")
struct SalesDismissTests {
    @Test func onlyAPresetDismissesASalesItem() throws {
        let item = try #require(desk(try worktrack()).row(deskID(key("acc_lead_today")))?.item)
        var state = DeskState()
        let typed = state.dismiss(item, reason: "Called Ahmad, +93 700 000 001", now: now)
        #expect(!typed && state.marks.isEmpty, "free text could name the customer")
        let preset = state.dismiss(item, reason: SalesDismissReason.called.rawValue, now: now)
        #expect(preset)
        #expect(state.marks[item.id]?.reason == "sales.reason.called")
        let gap = try #require(desk(MoneyWorkTrackInput(isSignedIn: false, environment: nil)).open.first { $0.id.hasPrefix("brief.sales|") }?.item)
        let gapTyped = state.dismiss(gap, reason: "not signed in on purpose", now: now)
        let gapPreset = state.dismiss(gap, reason: SalesDismissReason.other.rawValue, now: now)
        #expect(!gapTyped && gapPreset)
        // Any other item keeps the owner's own words.
        let other = DeskItem(origin: .brief(.monitor), subjectKey: "monitor.down.x", kindKey: "fact", kind: .fact, domain: .shared,
                             severity: .normal, title: "t", subject: "s", ownerAction: true, evidence: DeskEvidence(source: "s", readAt: now),
                             factHash: "0123456789abcdef", destination: .screen(.monitor))
        let own = state.dismiss(other, reason: "known outage", now: now)
        #expect(own)
        #expect(SalesDismissReason.displayText("sales.reason.console") == "Handled in the WorkTrack console")
        #expect(SalesDismissReason.displayText("known outage") == "known outage")
    }

    @Test func aTypedReasonNeverReachesTheCloud() {
        let id = "brief.sales|sales.followup.0123456789abcdef|fact"
        // Only an edited desk-state.json could hold one.
        let state = DeskState(marks: [
            id: DeskMark(kind: .dismissed, at: now, factHash: "0123456789abcdef", reason: "Called Ahmad"),
            "brief.monitor|monitor.down.x|fact": DeskMark(kind: .dismissed, at: now, factHash: "0123456789abcdef", reason: "known outage"),
        ])
        let local = DeskCloudMapping.localMarks(state)
        guard case .value(let sales)? = local[id], case .value(let other)? = local["brief.monitor|monitor.down.x|fact"] else {
            Issue.record("both marks are sent")
            return
        }
        #expect(sales.reason == "sales.reason.other" && other.reason == "known outage")
    }
}

// MARK: - The shape check

@Suite("Sales: the CRM answer's shape")
struct SalesShapeTests {
    @Test func countsAndNamesNeverValues() throws {
        let rows = try decode([WTJSON].self, "worktrack-crm-accounts-sales")
        let report = WTShapeReport(rows: rows, readAt: now)
        #expect(report.rows == 21 && report.nonObjects == 0 && !report.reachedLimit)
        #expect(report.unexpectedKeys == ["legacyPhone"])
        #expect(report.unknownStages == 1 && report.nextActionAtNotADay == 2)
        func field(_ n: String) -> WTShapeReport.Field? { report.fields.first { $0.name == n } }
        #expect(field("stage")?.differing == 1 && field("stage")?.types == ["string": 20, "number": 1])
        #expect(field("nextActionAt")?.differing == 1, "a number; null and absent are fine")
        #expect(field("nextActionAt")?.null == 2 && field("id")?.differing == 0 && field("name")?.differing == 0)
        let text = String(describing: report) + report.differences.joined()
        for never in ["SENTINEL", "SAMPLE", "Lead Today", "+93", "2026-02-31", "vendor-uid"] { #expect(!text.contains(never), "\(never)") }
        #expect(report.differences.count == 5, "\(report.differences)")
    }

    @Test func nullsTheConsoleWritesAreNotDifferences() throws {
        let json = #"[{"id":"a","name":"n","stage":"LEAD","companyId":null,"city":null,"industry":null,"source":null,"employeesEstimate":null,"nextActionAt":null,"nextAction":null,"notes":null,"createdAt":"2026-10-01T00:00:00.000Z","updatedAt":null,"createdBy":"u","updatedBy":"u"},{"id":"b","name":"m","stage":"WON","companyId":"c","createdBy":"support","createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z"}]"#
        let report = WTShapeReport(rows: try JSONDecoder().decode([WTJSON].self, from: Data(json.utf8)), readAt: now)
        #expect(report.differences.isEmpty, "\(report.differences)")
        let bad = #"[{"id":1,"name":"n"}, "x"]"#
        let broken = WTShapeReport(rows: try JSONDecoder().decode([WTJSON].self, from: Data(bad.utf8)), readAt: now)
        #expect(broken.nonObjects == 1 && broken.fields.first { $0.name == "id" }?.differing == 1)
        #expect(broken.fields.first { $0.name == "stage" }?.differing == 1 && broken.fields.first { $0.name == "createdAt" }?.differing == 1)
    }
}
