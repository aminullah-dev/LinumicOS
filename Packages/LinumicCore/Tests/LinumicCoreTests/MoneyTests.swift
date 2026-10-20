import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. worktrack-crm-{invoices,accounts}.json and safebeauty-balance-{owed,owing}.json are written by
// hand to the servers' schemas (WorkTrack services/crm.ts at 0403fd0; Firestore's runAggregationQuery answer); every
// name, number and note in them is made up (SAMPLE). The company list and the revenue are the emulator captures the
// WorkTrack tests use. No request leaves the process.

private let now = Date(timeIntervalSince1970: 1_792_438_260)      // 2026-10-19T19:31:00Z = 2026-10-20 00:01 in Kabul
private let readAt = Date(timeIntervalSince1970: 1_792_438_140)   // two minutes earlier
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private struct Envelope<T: Decodable>: Decodable { let data: T }

private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(Envelope<T>.self, from: try fixture(name)).data
}

private func companies(duplicate: String? = "emu_perpetual") throws -> [WTCompany] {
    var list = try decode([WTCompany].self, "worktrack-companies")
    if let duplicate, let i = list.firstIndex(where: { $0.companyId == duplicate }) {
        list[i].flags = WTFlags(kind: "DUPLICATE", duplicateOf: "emu_herat", note: "SAMPLE", at: nil, by: nil)
    }
    return list
}

private func moneyRead(revenue: MoneyRead<WTRevenue>? = nil, accounts: MoneyRead<WTLossyList<WTCrmAccount>>? = nil,
                       invoices: MoneyRead<WTLossyList<WTCrmInvoice>>? = nil) throws -> WorkTrackMoneyRead {
    WorkTrackMoneyRead(revenue: try revenue ?? .read(decode(WTRevenue.self, "worktrack-revenue"), at: readAt),
                       accounts: try accounts ?? .read(decode(WTLossyList<WTCrmAccount>.self, "worktrack-crm-accounts"), at: readAt),
                       invoices: try invoices ?? .read(decode(WTLossyList<WTCrmInvoice>.self, "worktrack-crm-invoices"), at: readAt))
}

private func worktrack(env: String = "production", companies list: [WTCompany]? = nil, money: WorkTrackMoneyRead? = nil,
                       companiesReadAt: Date? = readAt, loadError: String? = nil) throws -> MoneyWorkTrackInput {
    MoneyWorkTrackInput(isSignedIn: true, environment: env, companies: try list ?? companies(), companiesReadAt: companiesReadAt,
                        loadError: loadError, money: try money ?? moneyRead())
}

private let balances = SafeBeautyBalanceTotals(owedToSalonsCount: 3, owedToSalons: 4500, owedBySalonsCount: 1, owedBySalons: 300,
                                               readTime: readAt, readAt: readAt)

private func safeBeauty(env: String = "production", _ read: MoneyRead<SafeBeautyBalanceTotals>? = .read(balances, at: readAt)) -> MoneySafeBeautyInput {
    MoneySafeBeautyInput(isSignedIn: true, environment: env, balances: read)
}

private let signedOutWorkTrack = MoneyWorkTrackInput(isSignedIn: false, environment: nil)
private let signedOutSafeBeauty = MoneySafeBeautyInput(isSignedIn: false, environment: nil)

private func account(_ id: String, cost: AccountCost?) -> VendorAccount {
    VendorAccount(id: id, name: id.capitalized, purpose: "SAMPLE", cost: cost, source: "SAMPLE bill", recordedOn: KeyDay("2026-10-19"), origin: .owner)
}

private func costs(_ accounts: [VendorAccount] = [], loadError: String? = nil) -> MoneyCostsInput {
    MoneyCostsInput(accounts: accounts, builtAt: readAt, loadError: loadError)
}

private func input(_ w: MoneyWorkTrackInput, _ s: MoneySafeBeautyInput, _ c: MoneyCostsInput? = costs()) -> MoneyInput {
    MoneyInput(worktrack: w, safeBeauty: s, costs: c)
}

private func amounts(_ f: MoneyFigure) -> [Decimal] { f.totals?.amounts.map(\.value) ?? [] }

private func briefInput(_ money: MoneyInput?) -> BriefInput {
    BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
               licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
               operations: OperationsProduct.allCases.map { BriefOperationsInput(product: $0, isSignedIn: false, counts: []) },
               oversight: BriefOversightInput(repos: [], recentChanges: []), money: money)
}

private func desk(_ money: MoneyInput?, state: DeskState = DeskState(), at time: Date = now) -> Desk {
    var b = briefInput(money)
    b.now = time
    return DeskBuilder.build(brief: DailyBriefBuilder.build(b, changes: []), ledgers: .unsupported, state: state, now: time, calendar: utc)
}

// MARK: - Amounts

@Suite("Money: amounts and currencies")
struct MoneyAmountTests {
    @Test func currencyCodeIsThreeLetters() {
        #expect(CurrencyCode(rawValue: "afn") == .afn)
        #expect(CurrencyCode(rawValue: " usd ")?.rawValue == "USD")
        for bad in ["AF", "US$", "", "AFNN", "۱۲۳"] { #expect(CurrencyCode(rawValue: bad) == nil, "\(bad)") }
    }

    @Test func totalsNeverMixCurrencies() {
        var t = MoneyTotals()
        t.add(MoneyAmount(100, .afn))
        t.add(MoneyAmount(5, CurrencyCode(rawValue: "USD")!))
        t.add(MoneyAmount(50, .afn))
        #expect(t.count == 3)
        #expect(t.amounts == [MoneyAmount(150, .afn), MoneyAmount(5, CurrencyCode(rawValue: "USD")!)], "AFN first, never one sum")
        let text = MoneyFormat.text(t, locale: Locale(identifier: "en_US"))
        #expect(text == "150 AFN · 5 USD")
        #expect(MoneyFormat.text(t, .atLeast("x"), locale: Locale(identifier: "en_US")) == "At least 150 AFN · 5 USD")
    }

    @Test func decimalDecodingIsExact() throws {
        let json = #"[{"id":"a","accountId":"x","status":"PAID","amountAfn":1500.5,"issuedAt":"2026-10-01"},"#
            + #"{"id":"b","accountId":"x","status":"PAID","amountAfn":0.1,"issuedAt":"2026-10-01"},"#
            + #"{"id":"c","accountId":"x","status":"PAID","amountAfn":0.2,"issuedAt":"2026-10-01"}]"#
        let list = try JSONDecoder().decode(WTLossyList<WTCrmInvoice>.self, from: Data(json.utf8))
        #expect(list.rows.reduce(Decimal(0)) { $0 + $1.amountAfn } == Decimal(string: "1500.8")!)
        #expect(MoneyAmount.decimal(3500) == 3500 && MoneyAmount.decimal(0.3) == Decimal(string: "0.3")!)
    }
}

// MARK: - Decoding and clients

@Suite("Money: WorkTrack CRM and SafeBeauty reads")
struct MoneyClientTests {
    @Test func crmInvoicesDecodeTolerantly() throws {
        let list = try decode(WTLossyList<WTCrmInvoice>.self, "worktrack-crm-invoices")
        #expect(list.rows.count == 13 && list.skipped == 1, "inv_14 has no amount: set aside, not read as 0")
        func inv(_ id: String) -> WTCrmInvoice? { list.rows.first { $0.id == id } }
        #expect(inv("inv_05")?.dueAt == nil && inv("inv_06")?.dueAt == nil, "null and missing alike")
        #expect(inv("inv_09")?.status.isKnown == false && inv("inv_09")?.status.rawValue == "OVERDUE")
        #expect(inv("inv_01")?.amountAfn == Decimal(string: "1500.5")! && inv("inv_01")?.method == "HAWALA")
        let labels = Mirror(reflecting: try #require(inv("inv_01"))).children.compactMap(\.label)
        #expect(!labels.contains("notes") && !labels.contains("period") && !labels.contains("createdBy"), "never held")
    }

    @Test func crmAccountsDecodeOnlyTheLink() throws {
        let list = try decode(WTLossyList<WTCrmAccount>.self, "worktrack-crm-accounts")
        #expect(list.rows.count == 6 && list.skipped == 0)
        let labels = Mirror(reflecting: list.rows[0]).children.compactMap(\.label)
        #expect(labels == ["id", "name", "companyId"])
        #expect(list.rows.first { $0.id == "acc_prospect" }?.companyId == nil)
        #expect(list.rows.first { $0.id == "acc_blank" }?.companyId == nil, "an empty link is no link")
        #expect(list.rows.first { $0.id == "acc_test" }?.companyId == "emu_test")
    }

    @Test func fixtureFlagsUseTheAPIFieldName() throws {
        // The API sends `flags` (services/vendor.ts:127); `vendorFlags` is the Firestore field and would decode as nil.
        let raw = String(decoding: try fixture("worktrack-companies"), as: UTF8.self)
        #expect(!raw.contains("vendorFlags"))
        let list = try companies(duplicate: nil)
        #expect(list.first { $0.companyId == "emu_test" }?.flags?.isTest == true)
    }

    @Test func crmClientPathsAndRetry() async throws {
        let t = MoneyStub { req, n in
            if req.url!.host == "securetoken.googleapis.com" { return (200, Data(#"{"id_token":"id-\#(n)","refresh_token":"r2","expires_in":"3600","user_id":"u"}"#.utf8)) }
            if req.url!.path.hasSuffix("/crm/accounts") { return n == 2 ? (401, Data(#"{"code":"UNAUTHENTICATED","detail":"expired"}"#.utf8)) : (200, try fixture("worktrack-crm-accounts")) }
            return (200, try fixture("worktrack-crm-invoices"))
        }
        let client = WorkTrackVendorClient(environment: .production, transport: t)
        await client.restore(refreshToken: "stored")
        let accounts = try await client.crmAccounts()
        let invoices = try await client.crmInvoices()
        #expect(accounts.rows.count == 6 && invoices.rows.count == 13)
        let paths = t.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.absoluteString)" }
        #expect(paths == [
            "POST https://securetoken.googleapis.com/v1/token?key=AIzaSyBhGGgbBqhdsJYpM9FpQld28jyhvEfqWPA",
            "GET https://worktrack-prod.web.app/v1/vendor/crm/accounts",
            "POST https://securetoken.googleapis.com/v1/token?key=AIzaSyBhGGgbBqhdsJYpM9FpQld28jyhvEfqWPA",
            "GET https://worktrack-prod.web.app/v1/vendor/crm/accounts",
            "GET https://worktrack-prod.web.app/v1/vendor/crm/invoices",
        ], "no accountId filter; one retry after a 401")
        #expect(t.requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer id-3")
    }

    @Test func moneyReaderReadsInTurnAndStopsWhenTheSessionIsRefused() async throws {
        let order = MoneyStub { req, _ in
            if req.url!.host == "securetoken.googleapis.com" { return (200, Data(#"{"id_token":"i","refresh_token":"r","expires_in":"3600","user_id":"u"}"#.utf8)) }
            if req.url!.path.hasSuffix("/revenue") { return (500, Data(#"{"code":"INTERNAL","detail":"boom"}"#.utf8)) }
            if req.url!.path.hasSuffix("/crm/accounts") { return (200, try fixture("worktrack-crm-accounts")) }
            return (200, try fixture("worktrack-crm-invoices"))
        }
        let client = WorkTrackVendorClient(environment: .demo, transport: order)
        await client.restore(refreshToken: "r")
        let read = await WorkTrackMoneyReader.read(client, now: { readAt })
        #expect(order.requests.compactMap { $0.url?.path }.filter { $0.contains("/vendor/") }
            == ["/v1/vendor/revenue", "/v1/vendor/crm/accounts", "/v1/vendor/crm/invoices"])
        #expect(read.revenue.failure != nil && read.accounts.value != nil && read.invoices.value != nil && !read.needsSignIn)
        #expect(read.revenue.at == readAt)

        let refused = MoneyStub { req, _ in
            req.url!.host == "securetoken.googleapis.com" ? (400, Data(#"{"error":{"message":"TOKEN_EXPIRED"}}"#.utf8)) : (200, Data("{}".utf8))
        }
        let stale = WorkTrackVendorClient(environment: .demo, transport: refused)
        await stale.restore(refreshToken: "old")
        let none = await WorkTrackMoneyReader.read(stale)
        #expect(none.needsSignIn && none.accounts.needsSignIn && none.invoices.needsSignIn)
        #expect(refused.requests.count == 1, "after the refusal nothing more is asked")
    }

    @Test func aggregateRequestBodyAndCountKeepsItsOldBody() async throws {
        let t = MoneyStub { _, _ in (200, try fixture("safebeauty-balance-owed")) }
        let rest = FirestoreREST(endpoint: .google(project: "safebeauty"), transport: t)
        let r = try await rest.aggregate("provider_balances", filters: [FirestoreFilter("owedAmount", .greaterThan, .integer(0))],
                                         [.count(alias: "n"), .sum(alias: "s", field: "owedAmount")], token: "tok")
        #expect(r.values == ["n": 3, "s": 4500])
        let req = t.requests[0]
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://firestore.googleapis.com/v1/projects/safebeauty/databases/(default)/documents:runAggregationQuery")
        #expect(String(decoding: req.httpBody!, as: UTF8.self) == #"{"structuredAggregationQuery":{"aggregations":[{"alias":"n","count":{}},{"alias":"s","sum":{"field":{"fieldPath":"owedAmount"}}}],"structuredQuery":{"from":[{"collectionId":"provider_balances"}],"where":{"fieldFilter":{"field":{"fieldPath":"owedAmount"},"op":"GREATER_THAN","value":{"integerValue":"0"}}}}}}"#)

        let c = MoneyStub { _, _ in (200, try fixture("safebeauty-count")) }
        #expect(try await FirestoreREST(endpoint: .google(project: "safebeauty"), transport: c).count("salons", filters: [], token: "t") == 3)
        #expect(String(decoding: c.requests[0].httpBody!, as: UTF8.self)
            == #"{"structuredAggregationQuery":{"aggregations":[{"alias":"n","count":{}}],"structuredQuery":{"from":[{"collectionId":"salons"}]}}}"#)
    }

    @Test func aggregateDecodesIntegersAndDoublesAndRefusesTheRest() async throws {
        func run(_ body: String, _ aggs: [FirestoreAggregation] = [.count(alias: "n"), .sum(alias: "s", field: "owedAmount")]) async throws -> FirestoreAggregateResult {
            try await FirestoreREST(endpoint: .google(project: "p"), transport: MoneyStub { _, _ in (200, Data(body.utf8)) })
                .aggregate("provider_balances", filters: [], aggs, token: "t")
        }
        let owing = try await FirestoreREST(endpoint: .google(project: "p"), transport: MoneyStub { _, _ in (200, try fixture("safebeauty-balance-owing")) })
            .aggregate("provider_balances", filters: [], [.count(alias: "n"), .sum(alias: "s", field: "owedAmount")], token: "t")
        #expect(owing.values == ["n": 1, "s": -300])
        #expect(owing.readTime == FirestoreValue.parseTimestamp("2026-10-19T05:34:03.100Z"))
        // A missing alias, or a number that is not one, is an error: never 0 (FirestoreValue would have made it 0).
        await #expect(throws: FirestoreError.self) { _ = try await run(#"[{"result":{"aggregateFields":{"n":{"integerValue":"3"}}}}]"#) }
        await #expect(throws: FirestoreError.self) { _ = try await run(#"[{"result":{"aggregateFields":{"n":{"integerValue":"3x"},"s":{"integerValue":"1"}}}}]"#) }
        await #expect(throws: FirestoreError.self) { _ = try await run(#"[{"result":{"aggregateFields":{"n":{"integerValue":"3"},"s":{"stringValue":"1"}}}}]"#) }
        await #expect(throws: FirestoreError.self) { _ = try await run(#"[{"readTime":"2026-10-19T05:34:03Z"}]"#) }
    }

    @Test func balanceTotalsAreTwoReadOnlyAggregations() async throws {
        let t = MoneyStub { req, _ in
            if req.url!.path.hasSuffix("/token") { return (200, Data(#"{"id_token":"i","refresh_token":"r","expires_in":"3600","user_id":"u"}"#.utf8)) }
            let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            return (200, try fixture(body.contains("LESS_THAN") ? "safebeauty-balance-owing" : "safebeauty-balance-owed"))
        }
        let client = SafeBeautyAdminClient(environment: .production, transport: t, now: { readAt })
        await client.restore(refreshToken: "r")
        let totals = try await client.balanceTotals()
        #expect(totals == SafeBeautyBalanceTotals(owedToSalonsCount: 3, owedToSalons: 4500, owedBySalonsCount: 1, owedBySalons: 300,
                                                  readTime: FirestoreValue.parseTimestamp("2026-10-19T05:34:03.100Z"), readAt: readAt))
        let firestore = t.requests.filter { $0.url?.host == "firestore.googleapis.com" }
        #expect(firestore.count == 2 && firestore.allSatisfy { $0.httpMethod == "POST" && $0.url!.absoluteString.hasSuffix(":runAggregationQuery") })
        let ops = firestore.map { String(decoding: $0.httpBody!, as: UTF8.self) }
        #expect(ops[0].contains(#""op":"GREATER_THAN","value":{"integerValue":"0"}"#) && ops[1].contains(#""op":"LESS_THAN","value":{"integerValue":"0"}"#))
        #expect(!t.requests.contains { $0.url!.host!.hasSuffix("cloudfunctions.net") }, "no callable")
    }

    @Test func workTrackAndSafeBeautyTransportsKeepNothingOnDisk() throws {
        let c = URLSessionTransport.uncached.configuration
        #expect(c.urlCache == nil && c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(c.httpCookieStorage == nil && c.urlCredentialStorage == nil)
        func transport(of client: AnyObject) -> URLSessionTransport? {
            Mirror(reflecting: client).children.first { $0.label == "transport" }?.value as? URLSessionTransport
        }
        let wt = try #require(transport(of: WorkTrackVendorClient(environment: .production)))
        #expect(wt.session === URLSessionTransport.uncached)
        let sb = try #require(transport(of: SafeBeautyAdminClient(environment: .production)))
        #expect(sb.session === URLSessionTransport.uncached)
    }

    @Test func secretKeysUnchanged() {
        // Roadmap Phase 4 done-criterion: Money adds no key. A new case here is a new credential and needs its own review.
        #expect(SecretKey.allCases.map(\.rawValue) == [
            "github.token", "supabase.session", "appstoreconnect.key", "googleplay.serviceaccount", "licence.signing.mediflow",
            "licence.signing.khayatyar", "worktrack.vendor.session", "talar.admin.session", "safebeauty.admin.session",
            "velro.staff.session", "wordpress.linumic.apppassword",
        ])
    }
}

// MARK: - The figures

@Suite("Money: figures, Unknown and TEST companies")
struct MoneyBuilderTests {
    @Test func revenueFixtureIsReceivedWithItsSource() throws {
        let report = MoneyBuilder.build(input(try worktrack(), safeBeauty()), now: now)
        let f1 = report.figure(.worktrackHesabPayReceived)
        #expect(f1.totals == MoneyTotals(MoneyAmount(3500, .afn), count: 1))
        #expect(f1.source.reference.contains("/v1/vendor/revenue") && f1.source.readAt == readAt && f1.source.environment == "production")
        #expect(f1.completeness == .complete && !f1.isForecast)
        let f3 = report.figure(.worktrackRenewalsExpected)
        #expect(f3.isForecast && f3.totals?.count == 1)
        #expect(report.figures.map(\.id) == MoneyFigureID.allCases)
        #expect(report.kabulToday == "2026-10-20")
    }

    @Test func signedOutIsUnknownNotZero() throws {
        let report = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty()), now: now)
        for id in [MoneyFigureID.worktrackHesabPayReceived, .worktrackInvoicesPaid, .worktrackRenewalsExpected, .worktrackInvoicesOutstanding, .worktrackInvoicesOverdue] {
            #expect(report.figure(id).unknownReason == .notSignedIn(product: "WorkTrack"), "\(id)")
            #expect(report.figure(id).totals == nil)
        }
        #expect(report.counts.drafts == nil && report.counts.graceLicences == nil && report.counts.sentWithoutDueDate == nil, "unread is not 0")
        let section = MoneyBrief.section(input(signedOutWorkTrack, safeBeauty()), now: now)
        #expect(!section.lines.contains { $0.id.hasPrefix("money.worktrack") })
        let gap = try #require(section.gaps.first { $0.key == "worktrack" })
        #expect(gap.product == nil, "the WorkTrack section raises the sign-in item; this copy stays in Later")
    }

    @Test func revenueFailureKeepsInvoices() throws {
        let w = try worktrack(money: moneyRead(revenue: .failed("HTTP 500", at: readAt, needsSignIn: false)))
        let report = MoneyBuilder.build(input(w, safeBeauty()), now: now)
        #expect(report.figure(.worktrackHesabPayReceived).unknownReason == .readFailed(part: "WorkTrack revenue", message: "HTTP 500"))
        #expect(report.figure(.worktrackRenewalsExpected).unknownReason == .readFailed(part: "WorkTrack revenue", message: "HTTP 500"))
        #expect(report.figure(.worktrackInvoicesOutstanding).isKnown)
        let gaps = MoneyBrief.section(input(w, safeBeauty()), now: now).gaps
        #expect(gaps.contains { $0.key == "worktrack.revenue" && $0.product == "WorkTrack" })
    }

    @Test func aFailedCompanyListIsAFailureNotNotReadYet() throws {
        let w = try worktrack(money: nil, companiesReadAt: nil, loadError: "Couldn't reach WorkTrack")
        var cleared = w
        cleared.money = nil
        cleared.companies = []
        let report = MoneyBuilder.build(input(cleared, safeBeauty()), now: now)
        #expect(report.figure(.worktrackHesabPayReceived).unknownReason == .readFailed(part: "WorkTrack", message: "Couldn't reach WorkTrack"))
        #expect(report.figure(.worktrackInvoicesPaid).unknownReason == .readFailed(part: "WorkTrack", message: "Couldn't reach WorkTrack"))
    }

    @Test func overdueUsesKabulsDate() throws {
        let report = MoneyBuilder.build(input(try worktrack(), safeBeauty()), now: now)
        #expect(report.kabulToday == "2026-10-20")
        let overdue = report.openInvoices.filter { $0.daysPastDue != nil }.map(\.id)
        #expect(overdue.contains("inv_03"), "due 2026-10-19, and Kabul is already on the 20th")
        #expect(!overdue.contains("inv_04"), "due today in Kabul")
        #expect(report.openInvoices.first { $0.id == "inv_03" }?.daysPastDue == 1)
        // Two minutes earlier it was still the 19th in Kabul: nothing due on the 19th is past due yet.
        let before = MoneyBuilder.build(input(try worktrack(), safeBeauty()), now: readAt)
        #expect(before.kabulToday == "2026-10-19" && before.openInvoices.first { $0.id == "inv_03" }?.daysPastDue == nil)
        #expect(report.counts.sentWithoutDueDate == 2, "inv_05 (null) and inv_06 (missing)")
    }

    @Test func testAndDuplicateInvoicesAreLeftOut() throws {
        let report = MoneyBuilder.build(input(try worktrack(), safeBeauty()), now: now)
        let paid = report.figure(.worktrackInvoicesPaid), sent = report.figure(.worktrackInvoicesOutstanding), overdue = report.figure(.worktrackInvoicesOverdue)
        // PAID: inv_01 1500.5 (HAWALA) + inv_02 2000 (prospect). Left out: inv_10 (TEST), inv_13 (company gone).
        #expect(paid.totals == { var t = MoneyTotals(zeroIn: .afn); t.add(MoneyAmount(Decimal(string: "1500.5")!, .afn)); t.add(MoneyAmount(2000, .afn)); return t }())
        // SENT: inv_03 3000 + inv_04 1000 + inv_05 700 + inv_06 800 + inv_12 250 (account missing, counted). inv_11 is DUPLICATE.
        #expect(amounts(sent) == [5750] && sent.totals?.count == 5)
        #expect(amounts(overdue) == [3250] && overdue.totals?.count == 2)
        #expect(report.notYetDue.map { ($0.amounts.map(\.value), $0.count) }! == ([2500], 3))
        // Received and on the way are different questions: two totals, never one sum (13000).
        #expect(report.excludedPaid.map { ($0.amounts.map(\.value), $0.count) }! == ([7000], 1), "inv_10, PAID, TEST")
        #expect(report.excludedSent.map { ($0.amounts.map(\.value), $0.count) }! == ([6000], 1), "inv_11, SENT, DUPLICATE")
        let notes = MoneyBrief.notes(report, input: input(try worktrack(), safeBeauty()))
        #expect(notes.contains { $0.hasPrefix("Left out: 1 paid invoices") } && notes.contains { $0.hasPrefix("Left out: 1 sent invoices") })
        #expect(!notes.joined().contains("13,000") && !notes.joined().contains("13000"))
        #expect(report.counts.invoicesNotLinked == 2 && report.counts.invoicesAccountMissing == 1 && report.counts.invoicesCompanyMissing == 1)
        #expect(report.counts.invoicesUnknownStatus == 1 && report.counts.invoicesSkipped == 1 && report.counts.drafts == 1)
        #expect(report.paidByMethod.map(\.method) == ["HAWALA", ""])
        #expect(report.recentPaid.map(\.id) == ["inv_02", "inv_01"])
        // Unknown status, a document that could not be read, and the missing company or account: incomplete, said so.
        guard case .partial = paid.completeness, case .partial = sent.completeness, case .partial = overdue.completeness else {
            Issue.record("expected partial: \(paid.completeness) \(sent.completeness)")
            return
        }
        // Without the DUPLICATE mark, inv_11 counts.
        let unmarked = MoneyBuilder.build(input(try worktrack(companies: companies(duplicate: nil)), safeBeauty()), now: now)
        #expect(amounts(unmarked.figure(.worktrackInvoicesOutstanding)) == [11750])
    }

    @Test func anyMarkLeavesACompanyOutLikeTheServer() throws {
        var list = try companies(duplicate: nil)
        let i = try #require(list.firstIndex { $0.companyId == "emu_herat" })
        list[i].flags = WTFlags(kind: "SOMETHING_NEW", duplicateOf: nil, note: nil, at: nil, by: nil)
        let report = MoneyBuilder.build(input(try worktrack(companies: list), safeBeauty()), now: now)
        #expect(!report.openInvoices.contains { $0.id == "inv_03" }, "flags != nil, as services/vendorInsights.ts:400 checks")
    }

    @Test func invoiceOfACompanyNotInTheListIsLeftOutAndCounted() throws {
        let report = MoneyBuilder.build(input(try worktrack(), safeBeauty()), now: now)
        #expect(!report.recentPaid.contains { $0.id == "inv_13" })
        #expect(report.counts.invoicesCompanyMissing == 1)
        let caveat = report.figure(.worktrackInvoicesPaid).completeness.caveat ?? ""
        #expect(caveat.contains("not in the company list"))
        #expect(report.figure(.worktrackInvoicesOutstanding).completeness.caveat?.contains("not in the company list") == false,
                "only the figure the invoice would count in")
        let notes = MoneyBrief.section(input(try worktrack(), safeBeauty()), now: now).notes
        #expect(notes.contains { $0.contains("not in the company list") })
    }

    @Test func companyListNotReadMakesInvoicesUnknownNotZero() throws {
        let w = try worktrack(companiesReadAt: nil)
        let report = MoneyBuilder.build(input(w, safeBeauty()), now: now)
        for id in [MoneyFigureID.worktrackInvoicesPaid, .worktrackInvoicesOutstanding, .worktrackInvoicesOverdue] {
            guard case .dependencyFailed(let why)? = report.figure(id).unknownReason else {
                Issue.record("\(id) should be Unknown")
                continue
            }
            #expect(why.contains("company list"))
        }
        #expect(report.counts.drafts == nil && report.counts.invoicesNotLinked == nil && report.counts.graceLicences == nil)
        #expect(report.excludedPaid == nil && report.excludedSent == nil && report.openInvoices.isEmpty)
        #expect(report.figure(.worktrackHesabPayReceived).isKnown, "the server leaves TEST companies out of revenue itself")
    }

    @Test func accountsFailureMakesInvoicesUnknown() throws {
        let w = try worktrack(money: moneyRead(accounts: .failed("HTTP 503", at: readAt, needsSignIn: false)))
        let report = MoneyBuilder.build(input(w, safeBeauty()), now: now)
        guard case .dependencyFailed(let why)? = report.figure(.worktrackInvoicesPaid).unknownReason else {
            Issue.record("expected dependencyFailed")
            return
        }
        #expect(why.contains("HTTP 503"))
        #expect(report.figure(.worktrackInvoicesOverdue).totals == nil, "never shown unfiltered")
        #expect(MoneyBrief.section(input(w, safeBeauty()), now: now).gaps.contains { $0.key == "worktrack.invoices" && $0.product == "WorkTrack" })
    }

    @Test func invoiceLimitIsAtLeast() throws {
        let many = (0..<2000).map { WTCrmInvoice(id: "i\($0)", accountId: "acc_herat", number: "\($0)", status: .sent, amountAfn: 1, issuedAt: "2026-10-01", dueAt: "2026-11-01") }
        let w = try worktrack(money: moneyRead(invoices: .read(WTLossyList(rows: many), at: readAt)))
        let report = MoneyBuilder.build(input(w, safeBeauty()), now: now)
        guard case .atLeast = report.figure(.worktrackInvoicesOutstanding).completeness else {
            Issue.record("expected at least")
            return
        }
        let gap = try #require(MoneyBrief.section(input(w, safeBeauty()), now: now).gaps.first { $0.key == "worktrack.limit" })
        #expect(gap.text.contains("2000") || gap.text.contains("2,000"))
    }

    @Test func revenueLimits() throws {
        var revenue = try decode(WTRevenue.self, "worktrack-revenue")
        revenue.earned.orderCount = 4990
        revenue.excluded.orderCount = 10
        let orders = MoneyBuilder.build(input(try worktrack(money: moneyRead(revenue: .read(revenue, at: readAt))), safeBeauty()), now: now)
        guard case .atLeast = orders.figure(.worktrackHesabPayReceived).completeness else {
            Issue.record("5000 paid orders: at least")
            return
        }
        // 500 companies: a TEST company past the limit is counted, so earned may be wrong either way; renewals only short.
        let base = try companies(duplicate: nil)[0]
        let many = (0..<500).map { i -> WTCompany in var c = base; c.companyId = "c\(i)"; c.flags = nil; return c }
        let capped = MoneyBuilder.build(input(try worktrack(companies: many), safeBeauty()), now: now)
        guard case .partial = capped.figure(.worktrackHesabPayReceived).completeness,
              case .atLeast = capped.figure(.worktrackRenewalsExpected).completeness else {
            Issue.record("company cap: partial earned, at-least forecast")
            return
        }
    }

    @Test func noFlaggedCompanyRaisesTheTestGapWithAStableText() throws {
        var revenue = try decode(WTRevenue.self, "worktrack-revenue")
        revenue.excluded = WTRevenue.Excluded(companyCount: 0, orderCount: 0, amountAfn: 0)
        let w = try worktrack(money: moneyRead(revenue: .read(revenue, at: readAt)))
        let a = MoneyBrief.section(input(w, safeBeauty()), now: now).gaps.first { $0.key == "worktrack.test" }
        let b = MoneyBrief.section(input(w, safeBeauty()), now: now.addingTimeInterval(86_400)).gaps.first { $0.key == "worktrack.test" }
        #expect(a != nil && a == b, "same text a day later, so a dismissal holds")
        let flagged = MoneyBrief.section(input(try worktrack(), safeBeauty()), now: now)
        #expect(!flagged.gaps.contains { $0.key == "worktrack.test" })
        #expect(flagged.notes.contains { $0.hasPrefix("Left out: 1 TEST or DUPLICATE companies") })
    }

    @Test func nonProductionIsInfoWithAGap() throws {
        let section = MoneyBrief.section(input(try worktrack(env: "demo"), safeBeauty(env: "staging")), now: now)
        #expect(!section.lines.isEmpty && section.lines.allSatisfy { $0.severity == .info })
        #expect(section.gaps.contains { $0.key == "worktrack.production" } && section.gaps.contains { $0.key == "safebeauty.production" })
        #expect(section.lines.allSatisfy { $0.links.isEmpty }, "consoles are production only")
    }

    @Test func salonBalancesAreNeverNetted() {
        let report = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty()), now: now)
        #expect(amounts(report.figure(.safeBeautyOwedToSalons)) == [4500] && report.figure(.safeBeautyOwedToSalons).totals?.count == 3)
        #expect(amounts(report.figure(.safeBeautyOwedBySalons)) == [300] && report.figure(.safeBeautyOwedBySalons).totals?.count == 1)
        #expect(!report.figures.flatMap(amounts).contains(4200))
        let section = MoneyBrief.section(input(signedOutWorkTrack, safeBeauty()), now: now)
        #expect(!section.lines.contains { ($0.detail ?? "").contains("4,200") || ($0.detail ?? "").contains("4200") })
        #expect(report.figure(.safeBeautyOwedToSalons).source.readAt == readAt, "Firestore's own read time")
    }

    @Test func salonLinesCarryCountsNotAmounts() throws {
        let section = MoneyBrief.section(input(signedOutWorkTrack, safeBeauty()), now: now)
        let owed = try #require(section.lines.first { $0.id == "money.safebeauty.owed" })
        #expect(!owed.text.contains("AFN") && !owed.text.contains("4500") && !owed.text.contains("4,500"))
        #expect(owed.detail?.contains("AFN") == true)
        #expect(owed.factKey == BriefLine.countBucket(3) && owed.severity == .normal && owed.destination == .money)
        #expect(owed.links.first?.url.absoluteString == "https://safebeauty.web.app/admin")
        #expect(section.lines.first { $0.id == "money.safebeauty.receivable" }?.severity == .info)
        #expect(section.notes.contains("SafeBeauty has no TEST mark, so every salon balance is counted."))
    }

    @Test func balancesFailureIsUnknownWithItsMessage() {
        let report = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty(.failed("permission denied", at: readAt, needsSignIn: false))), now: now)
        #expect(report.figure(.safeBeautyOwedToSalons).unknownReason == .readFailed(part: "SafeBeauty balances", message: "permission denied"))
        #expect(report.figure(.safeBeautyOwedBySalons).totals == nil)
    }

    @Test func costsPerCurrencyPerCycleNeverSummedAcross() throws {
        let usd = CurrencyCode(rawValue: "USD")!, cad = CurrencyCode(rawValue: "CAD")!
        let accounts = [
            account("apple", cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "SAMPLE bill")),
            account("domain", cost: AccountCost(amount: 25, currency: "USD", cycle: .once, source: "SAMPLE bill")),
            account("host", cost: AccountCost(amount: 10, currency: "CAD", cycle: .monthly, source: "SAMPLE bill")),
            account("github", cost: nil), account("notion", cost: nil),
        ]
        let report = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty(), costs(accounts)), now: now)
        let f8 = report.figure(.accountCosts)
        guard case .knownByCycle(let cycles) = f8.value else {
            Issue.record("expected per-cycle costs")
            return
        }
        #expect(cycles[.yearly]?.byCurrency == [usd: 99] && cycles[.once]?.byCurrency == [usd: 25] && cycles[.monthly]?.byCurrency == [cad: 10])
        #expect(f8.totals == nil, "what we pay has no single total")
        let lines = MoneyFormat.byCycle(cycles, locale: Locale(identifier: "en_US"))
        #expect(lines == ["10 CAD per month", "99 USD per year · 25 USD once"])
        for sum in ["124", "134", "1188", "120"] { #expect(!lines.joined().contains(sum), "no sum across cycles, no ×12: \(sum)") }
        guard case .partial = f8.completeness else {
            Issue.record("2 accounts without a cost: partial")
            return
        }
        let gap = try #require(MoneyBrief.section(input(signedOutWorkTrack, safeBeauty(), costs(accounts)), now: now).gaps.first { $0.key == "costs" })
        #expect(gap.text == "2 of 5 accounts have no recorded cost, so what we pay is incomplete.")
        #expect(report.accountsWithoutCost == ["Github", "Notion"])
    }

    @Test func unreadableObligationsMakeCostsUnknown() throws {
        let accounts = [account("apple", cost: AccountCost(amount: 99, currency: "USD", cycle: .yearly, source: "SAMPLE bill"))]
        let report = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty(), costs(accounts, loadError: "bad JSON")), now: now)
        #expect(report.figure(.accountCosts).unknownReason == .obligationsUnreadable("bad JSON"))
        #expect(report.figure(.accountCosts).unknownReason?.text == "obligations.json could not be read (bad JSON), so the costs you recorded are unknown.")
        #expect(report.costs.isEmpty)
        let none = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty(), nil), now: now)
        #expect(none.figure(.accountCosts).unknownReason == .registerNotBuilt)
        let noCost = MoneyBuilder.build(input(signedOutWorkTrack, safeBeauty(), costs([account("github", cost: nil)])), now: now)
        #expect(noCost.figure(.accountCosts).unknownReason == .noCostRecorded(accounts: 1))
    }

    @Test func graceLicencesAreCountedOnlyFromARead() throws {
        var list = try companies(duplicate: nil)
        let i = try #require(list.firstIndex { $0.companyId == "emu_mazar" })
        list[i].daysUntilExpiry = -3
        let report = MoneyBuilder.build(input(try worktrack(companies: list), safeBeauty()), now: now)
        #expect(report.counts.graceLicences == 1)
        list[i].flags = WTFlags(kind: "TEST", duplicateOf: nil, note: nil, at: nil, by: nil)
        #expect(MoneyBuilder.build(input(try worktrack(companies: list), safeBeauty()), now: now).counts.graceLicences == 0)
    }
}

// MARK: - Brief and Desk

@Suite("Money: the Brief and the Desk")
struct MoneyDeskTests {
    @Test func moneySectionOrderAndNeverRead() {
        let kinds = BriefSourceKind.allCases
        #expect(kinds[kinds.firstIndex(of: .operations)! + 1] == .money)
        let section = DailyBriefBuilder.build(briefInput(nil), changes: nil).section(.money)
        guard case .neverRead? = section?.state else {
            Issue.record("not collected is never read")
            return
        }
        #expect(section?.lines.isEmpty == true)
    }

    @Test func storeProceedsAreAlwaysUnknownAndAlwaysOnTheDesk() throws {
        let report = MoneyBuilder.build(input(signedOutWorkTrack, signedOutSafeBeauty), now: now)
        #expect(report.figure(.appStoreProceeds).unknownReason == .noFinanceKey(store: "App Store"))
        #expect(report.figure(.googlePlayProceeds).unknownReason == .noFinanceKey(store: "Google Play"))
        let failing = try worktrack(money: moneyRead(revenue: .failed("x", at: readAt, needsSignIn: false), invoices: .failed("y", at: readAt, needsSignIn: false)))
        let cases: [(String, MoneyInput?)] = [
            ("read", input(try worktrack(), safeBeauty())),
            ("both signed out", input(signedOutWorkTrack, signedOutSafeBeauty)),
            ("all failed", input(failing, safeBeauty(.failed("z", at: readAt, needsSignIn: false)))),
            ("not collected", nil),
        ]
        for (name, money) in cases {
            let d = desk(money)
            let stores = d.open.first { $0.id == "brief.money|part.stores|not-read" }
            #expect(stores != nil, "\(name)")
            #expect(stores?.bucket == .later && stores?.item.severity == .info, "\(name)")
            #expect(d.open.contains { $0.id == "brief.money|part.costs|not-read" }, "\(name): costs are unknown too")
        }
    }

    @Test func aSectionReasonIsOneItemNotTwo() throws {
        let d = desk(input(signedOutWorkTrack, signedOutSafeBeauty))
        let money = d.open.filter { $0.id.hasPrefix("brief.money|") }.map(\.id).sorted()
        #expect(money == ["brief.money|part.costs|not-read", "brief.money|part.stores|not-read", "brief.money|section|not-read"])
        let failing = try worktrack(money: moneyRead(revenue: .failed("x", at: readAt, needsSignIn: false), invoices: .failed("y", at: readAt, needsSignIn: false)))
        let section = MoneyBrief.section(input(failing, signedOutSafeBeauty), now: now)
        guard case .unavailable(let why) = section.state else {
            Issue.record("expected unavailable")
            return
        }
        #expect(why.contains("x") && why.contains("y"))
        #expect(section.gaps.map(\.key).sorted() == ["costs", "safebeauty", "stores"], "SafeBeauty's own reason stays an item")
    }

    @Test func moneyLineIDsCarryNoCustomerIDs() throws {
        let section = MoneyBrief.section(input(try worktrack(), safeBeauty()), now: now)
        #expect(Set(section.lines.map(\.id)) == ["money.safebeauty.owed", "money.safebeauty.receivable", "money.worktrack.overdue", "money.worktrack.unpaid"])
        let pattern = try Regex("^money\\.[a-z.]+$")
        for line in section.lines {
            #expect(line.id.wholeMatch(of: pattern) != nil, "\(line.id)")
            #expect(!line.text.contains("emu_") && !line.text.contains("acc_") && !line.text.contains("INV-"))
        }
    }

    @Test func aMarkOnAVanishedMoneyLineIsPruned() throws {
        var state = DeskState()
        let first = desk(input(try worktrack(), safeBeauty()))
        let overdue = try #require(first.open.first { $0.id == "brief.money|money.worktrack.overdue|fact" })
        state.markWaiting(overdue.item, now: now)
        let later = now.addingTimeInterval(3600)
        // Read again an hour later: everything paid, the WorkTrack part read (no WorkTrack gap): the mark goes.
        let paid = WTLossyList<WTCrmInvoice>(rows: [])
        var w = try worktrack(money: moneyRead(invoices: .read(paid, at: later)))
        w.money?.revenue = .read(try decode(WTRevenue.self, "worktrack-revenue"), at: later)
        let gone = desk(input(w, safeBeauty(.read(balances, at: later))), state: state, at: later)
        #expect(gone.obsoleteMarks.contains(overdue.id))
        // The invoices could not be read: the line may only be unread, so the mark stays.
        let unread = try worktrack(money: moneyRead(invoices: .failed("timeout", at: later, needsSignIn: false)))
        let kept = desk(input(unread, safeBeauty(.read(balances, at: later))), state: state, at: later)
        #expect(!kept.obsoleteMarks.contains(overdue.id))
    }

    @Test func aDismissedCaveatHoldsWhileItsPartIsNotRead() throws {
        var revenue = try decode(WTRevenue.self, "worktrack-revenue")
        revenue.excluded = WTRevenue.Excluded(companyCount: 0, orderCount: 0, amountAfn: 0)
        var state = DeskState()
        let first = desk(input(try worktrack(money: moneyRead(revenue: .read(revenue, at: readAt))), safeBeauty()))
        let test = try #require(first.open.first { $0.id == "brief.money|part.worktrack.test|not-read" })
        #expect(test.item.detail == "This part was read; its figures are shown, but may not be complete or exact until this is resolved.",
                "a caveat on what was read, not an unread part")
        let dismissed = state.dismiss(test.item, reason: "No test company exists", now: now)
        #expect(dismissed)
        let later = now.addingTimeInterval(3600)
        // WorkTrack's revenue read failed once, or WorkTrack is signed out, while SafeBeauty is read: the caveat is
        // only not known this time, so the dismissal stays.
        let failed = try worktrack(money: moneyRead(revenue: .failed("HTTP 500", at: later, needsSignIn: false)))
        for (name, w) in [("revenue failed", failed), ("signed out", signedOutWorkTrack)] {
            let d = desk(input(w, safeBeauty(.read(balances, at: later))), state: state, at: later)
            #expect(!d.obsoleteMarks.contains(test.id), "\(name)")
        }
        // The company list failed and SafeBeauty is not signed in: one "not read" item in Later, not a second "could
        // not be read" beside the WorkTrack section's own, and the dismissal stays.
        let listFailed = MoneyWorkTrackInput(isSignedIn: true, environment: "production", loadError: "Couldn't reach WorkTrack")
        let d = desk(input(listFailed, signedOutSafeBeauty), state: state, at: later)
        #expect(!d.open.contains { $0.id == "brief.money|section|unavailable" })
        let section = try #require(d.open.first { $0.id == "brief.money|section|not-read" })
        #expect(section.bucket == .later && section.item.severity == .info)
        #expect(!d.obsoleteMarks.contains(test.id))
        // Read again with a company marked: the caveat is gone because the situation changed, so the mark goes.
        let marked = desk(input(try worktrack(), safeBeauty(.read(balances, at: later))), state: state, at: later)
        #expect(marked.obsoleteMarks.contains(test.id))
    }

    @Test func aDismissalOfStoreProceedsHolds() throws {
        var state = DeskState()
        let first = desk(input(try worktrack(), safeBeauty()))
        let stores = try #require(first.open.first { $0.id == "brief.money|part.stores|not-read" })
        let dismissed = state.dismiss(stores.item, reason: "No finance key until the first payment", now: now)
        #expect(dismissed)
        let later = desk(input(try worktrack(), safeBeauty()), state: state, at: now.addingTimeInterval(7 * 86_400))
        #expect(!later.open.contains { $0.id == stores.id } && later.hidden.contains { $0.id == stores.id })
    }

    @Test func theAgentBriefCarriesTheIdNotTheAmount() throws {
        let d = desk(input(try worktrack(), safeBeauty()))
        let owed = try #require(d.open.first { $0.id == "brief.money|money.safebeauty.owed|fact" })
        let text = DeskAgentBrief.text(for: owed.item, now: now)
        #expect(text.contains("money.safebeauty.owed"))
        #expect(!text.contains("AFN") && !text.contains("4,500") && !text.contains("4500"))
    }

    @Test func theNotificationShowsNoAmounts() throws {
        let brief = DailyBriefBuilder.build(briefInput(input(try worktrack(), safeBeauty())), changes: [])
        #expect(brief.attention.contains { $0.kind == .money })
        let body = BriefNotificationText.content(brief, asOf: "now").body
        #expect(body.contains("salons are owed a payout"))
        #expect(!body.contains("AFN") && !body.contains("4,500") && !body.contains("3,250"))
    }
}

/// Answers requests from a handler and records them.
final class MoneyStub: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n = lock.withLock { _requests.append(request); return _requests.count }
        let (status, body) = try handler(request, n)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
