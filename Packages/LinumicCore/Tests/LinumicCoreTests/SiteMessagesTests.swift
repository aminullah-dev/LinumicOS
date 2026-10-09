import Foundation
import Testing
@testable import LinumicCore

// Fixtures are fake data in the documented shape of the SureForms abilities; no real entry is ever fetched.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let credential = WordPressAppPassword(username: "owner", password: "abcd EFGH 1234 ijkl MNOP 5678")

/// Answers by ability name and records every request. Never touches the network.
private final class FakeWordPress: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    let answers: [String: (Int, Data)]

    init(_ answers: [String: (Int, Data)]) { self.answers = answers }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let path = request.url?.path ?? ""
        let key = answers.keys.first { path.contains($0) } ?? ""
        let (status, data) = answers[key] ?? (404, Data(#"{"code":"rest_no_route","message":"No route","data":{"status":404}}"#.utf8))
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func reading() throws -> SiteMessagesReading {
    let details = try SiteMessagesParser.details(try fixture("sureforms-bulk-get-entries"))
    return SiteMessagesReading(messages: details.map { SiteMessagesParser.message($0) }, total: 4,
                               readAt: Date(timeIntervalSince1970: 1_791_500_000))
}

@Suite("Website messages")
struct SiteMessagesTests {
    // MARK: Parsing

    @Test func parsesTheListAbilityOutput() throws {
        let list = try SiteMessagesParser.list(try fixture("sureforms-list-entries"))
        #expect(list.entries.map(\.id) == [104, 103, 102, 101])
        #expect(list.entries.first?.formID == 1752)
        #expect(list.entries.first?.status == "unread")
        #expect(list.total == 4)
        #expect(list.perPage == 20)
        #expect(throws: SiteMessagesError.badResponse) { try SiteMessagesParser.list(Data("[]".utf8)) }
    }

    @Test func turnsFieldsIntoAMessage() throws {
        let r = try reading()
        #expect(r.messages.map(\.id) == [104, 103, 102])
        let a = r.messages[0]
        #expect(a.name == "Test Person")
        #expect(a.email == "test.person@example.com")
        #expect(a.message.hasPrefix("Hello,"))
        #expect(a.isUnreadInWordPress)
        #expect(a.createdAtText == "2026-10-08 21:15:04")
        // Stored in Kabul time (UTC+4:30): 21:15:04 is 16:45:04 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = try #require(a.createdAt.map { utc.dateComponents([.year, .month, .day, .hour, .minute], from: $0) })
        #expect([c.year, c.month, c.day, c.hour, c.minute] == [2026, 10, 8, 16, 45])
        // No name: the address stands in, and a crafted address gets no reply link.
        let b = r.messages[1]
        #expect(b.name == nil)
        #expect(b.sender == "someone@example.org?cc=other@example.org")
        #expect(b.replyURL == nil)
        // Dari labels, and a list value joined.
        let c2 = r.messages[2]
        #expect(c2.name == "آزمون نمونه")
        #expect(c2.email == "sample@example.com")
        #expect(c2.message == "سلام, قیمت برنامه چند است؟")
    }

    @Test func messageFallsBackToTheLongestOtherField() {
        let d = SiteEntryDetail(id: 7, formID: 1, formName: "Other", status: "unread", createdAt: "bad date", fields: [
            SiteEntryField(label: "Your name", value: "Ali", blockName: "srfm-input"),
            SiteEntryField(label: "Topic", value: "A longer free text that is the message", blockName: "srfm-input"),
        ])
        let m = SiteMessagesParser.message(d)
        #expect(m.name == "Ali")
        #expect(m.message == "A longer free text that is the message")
        #expect(m.createdAt == nil)
        #expect(m.email == nil)
        #expect(m.sender == "Ali")
    }

    @Test func mapsWordPressErrorsToWhatTheOwnerCanDo() throws {
        #expect(SiteMessagesParser.error(status: 404, data: try fixture("wp-ability-not-found")) == .abilitiesOff)
        #expect(SiteMessagesParser.error(status: 404, data: Data(#"{"code":"rest_no_route"}"#.utf8)) == .noAbilitiesAPI)
        #expect(SiteMessagesParser.error(status: 401, data: Data(#"{"code":"incorrect_password"}"#.utf8)) == .unauthorized(code: "incorrect_password"))
        #expect(SiteMessagesParser.error(status: 403, data: Data(#"{"code":"rest_ability_cannot_execute"}"#.utf8)) == .forbidden(code: "rest_ability_cannot_execute"))
        #expect(SiteMessagesParser.error(status: 500, data: Data("<html>".utf8)) == .http(status: 500, code: nil))
        // Every error has words for the screen.
        let all: [SiteMessagesError] = [.notConfigured, .unauthorized(code: "rest_not_logged_in"), .unauthorized(code: "x"),
                                        .forbidden(code: "x"), .abilitiesOff, .noAbilitiesAPI, .http(status: 500, code: nil), .badResponse, .insecureSite]
        #expect(all.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }

    // MARK: Credential and requests

    @Test func credentialIsNormalisedAndNeverDescribed() throws {
        #expect(credential.password == "abcdEFGH1234ijklMNOP5678")
        #expect(credential.authorizationHeader == "Basic " + Data("owner:abcdEFGH1234ijklMNOP5678".utf8).base64EncodedString())
        #expect(!String(describing: credential).contains("abcd"))
        #expect(!String(reflecting: credential).contains("abcd"))
        let json = try credential.encoded()
        #expect(WordPressAppPassword.decode(json) == credential)
        #expect(!WordPressAppPassword(username: " ", password: "x").isComplete)
    }

    @Test func requestsAreGetsToTheCitedAbilityRoutes() {
        let client = SiteMessagesClient(credential: credential, transport: FakeWordPress([:]))
        let list = client.listRequest()
        #expect(list.httpMethod == "GET")
        #expect(list.url?.absoluteString == "https://linumic.com/wp-json/wp-abilities/v1/abilities/sureforms/list-entries/run?input%5Bstatus%5D=all&input%5Borderby%5D=created_at&input%5Border%5D=DESC&input%5Bper_page%5D=20&input%5Bpage%5D=1")
        #expect(list.value(forHTTPHeaderField: "Authorization") == credential.authorizationHeader)
        let details = client.detailsRequest(ids: [104, 103])
        #expect(details.url?.absoluteString == "https://linumic.com/wp-json/wp-abilities/v1/abilities/sureforms/bulk-get-entries/run?input%5Bentry_ids%5D%5B%5D=104&input%5Bentry_ids%5D%5B%5D=103")
        #expect(client.detailsRequest(ids: Array(1...80)).url!.absoluteString.components(separatedBy: "entry_ids").count - 1 == 50)
    }

    @Test func fetchRecentListsThenReadsDetails() async throws {
        let fake = FakeWordPress(["list-entries": (200, try fixture("sureforms-list-entries")),
                                  "bulk-get-entries": (200, try fixture("sureforms-bulk-get-entries"))])
        let client = SiteMessagesClient(credential: credential, transport: fake)
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let r = try await client.fetchRecent(now: now)
        #expect(r.messages.map(\.id) == [104, 103, 102])   // 101 vanished between the calls: left out
        #expect(r.total == 4)
        #expect(r.readAt == now)
        #expect(fake.requests.count == 2)
        #expect(fake.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.scheme == "https" })
    }

    @Test func fetchRecentStopsOnErrorsAndInsecureSites() async throws {
        let off = SiteMessagesClient(credential: credential, transport: FakeWordPress(["list-entries": (404, try fixture("wp-ability-not-found"))]))
        await #expect(throws: SiteMessagesError.abilitiesOff) { try await off.fetchRecent() }
        let plain = FakeWordPress([:])
        let http = SiteMessagesClient(site: URL(string: "http://linumic.com")!, credential: credential, transport: plain)
        await #expect(throws: SiteMessagesError.insecureSite) { try await http.fetchRecent() }
        #expect(plain.requests.isEmpty)   // nothing sent in the clear
        let empty = SiteMessagesClient(credential: WordPressAppPassword(username: "", password: ""), transport: plain)
        await #expect(throws: SiteMessagesError.notConfigured) { try await empty.fetchRecent() }
        #expect(plain.requests.isEmpty)
    }

    // MARK: Text

    @Test func excerptFoldsSpaceAndCutsAt140() {
        #expect(SiteMessageText.excerpt("  a\n\n b   c ") == "a b c")
        let long = String(repeating: "word ", count: 60)
        let e = SiteMessageText.excerpt(long)
        #expect(e.hasSuffix("…"))
        #expect(e.count <= 141)
        #expect(SiteMessageText.excerpt(String(repeating: "x", count: 140)).count == 140)
        // Dari text counts characters, not bytes.
        #expect(SiteMessageText.excerpt(String(repeating: "پ", count: 150)).count == 141)
    }

    @Test func replyLinkOnlyForAPlainAddress() throws {
        let url = try #require(SiteMessageText.replyURL(to: "test.person@example.com", subject: "Re: hello there"))
        #expect(url.absoluteString == "mailto:test.person@example.com?subject=Re:%20hello%20there")
        for bad in ["a@b.com?cc=c@d.com", "a@b.com&bcc=x", "two words@example.com", "no-at.example.com", "a@localhost", "a@b.com\nBcc: x"] {
            #expect(SiteMessageText.replyURL(to: bad) == nil, "\(bad)")
        }
        #expect(SiteMessagesSource.entryAdminURL(104).absoluteString == "https://linumic.com/wp-admin/admin.php?page=sureforms_entries#/entry/104")
    }

    // MARK: Seen, new, notify

    @Test func newSinceSeenAndNotifiedOnce() throws {
        let r = try reading()
        var state = SiteMessagesState()
        // First reading: everything is new (the owner never got the emails) and notified once.
        #expect(state.record(r).map(\.id) == [104, 103, 102])
        #expect(state.lastNewCount == 3)
        #expect(state.lastReadAt == r.readAt)
        #expect(state.record(r).isEmpty)   // never twice
        state.markSeen([103])
        #expect(SiteMessagesRules.new(r.messages, seen: state.seenIDs).map(\.id) == [104, 102])
        // A new entry arrives: only it is notified.
        var next = r
        next.messages.insert(SiteMessage(id: 105, formID: 1752, formName: "Simple Contact Form", status: "unread",
                                         createdAtText: "2026-10-09 10:00:00", createdAt: SiteMessagesParser.siteDate("2026-10-09 10:00:00"),
                                         name: "New", email: nil, message: "Hi"), at: 0)
        #expect(state.record(next).map(\.id) == [105])
        state.markSeen(next.messages.map(\.id))
        #expect(SiteMessagesRules.new(next.messages, seen: state.seenIDs).isEmpty)
        state.markUnseen(104)
        #expect(SiteMessagesRules.new(next.messages, seen: state.seenIDs).map(\.id) == [104])
    }

    @Test func stateFileHoldsIdsOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SiteMessagesStateStore(fileURL: dir.appending(path: "site-messages.json"))
        #expect(store.load() == SiteMessagesState())
        var state = SiteMessagesState()
        _ = state.record(try reading())
        state.markSeen([104])
        try store.save(state)
        #expect(store.load() == state)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("example.com"))
        #expect(!text.contains("Person"))
        #expect(!text.contains("WorkTrack"))
        // Ids are trimmed to the newest.
        var big = SiteMessagesState()
        big.markSeen(1...700)
        #expect(big.seenIDs.count == SiteMessagesState.keepIDs)
        #expect(big.seenIDs.contains(700) && !big.seenIDs.contains(1))
    }

    @Test func notificationWording() throws {
        let m = try reading().messages
        #expect(SiteMessagesNotificationText.content([]) == nil)
        let one = try #require(SiteMessagesNotificationText.content([m[0]]))
        #expect(one.title == "New message from linumic.com")
        #expect(one.body.hasPrefix("Test Person: Hello, I would like"))
        #expect(!one.body.contains("@"))
        let three = try #require(SiteMessagesNotificationText.content(m))
        #expect(three.title == "3 new messages from linumic.com")
        let extra = SiteMessage(id: 1, formID: 1, formName: "", status: "", createdAtText: "", createdAt: nil, name: "Z", email: nil, message: "")
        let four = try #require(SiteMessagesNotificationText.content(m + [extra]))
        #expect(four.body.hasSuffix("and 1 more."))
    }

    // MARK: Brief

    private func briefInput(_ site: BriefSiteMessagesInput?) -> BriefInput {
        BriefInput(now: Date(timeIntervalSince1970: 1_791_500_000), monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                   licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                   operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []), siteMessages: site)
    }

    @Test func briefSectionStates() throws {
        let none = DailyBriefBuilder.build(briefInput(nil), changes: nil)
        guard case .neverRead = none.section(.siteMessages)?.state else { Issue.record("expected not read"); return }
        let notRead = DailyBriefBuilder.siteMessages(briefInput(BriefSiteMessagesInput(isConfigured: true, reading: nil, seenIDs: [])))
        guard case .neverRead = notRead.state else { Issue.record("expected not read"); return }
        let failed = DailyBriefBuilder.siteMessages(briefInput(BriefSiteMessagesInput(isConfigured: true, reading: nil, seenIDs: [],
                                                                                       loadError: "SureForms abilities are off.")))
        #expect(failed.state == .unavailable("SureForms abilities are off."))

        let r = try reading()
        let section = DailyBriefBuilder.siteMessages(briefInput(BriefSiteMessagesInput(isConfigured: true, reading: r, seenIDs: [102])))
        #expect(section.state == .items)
        #expect(section.lines.map(\.id) == ["site.104", "site.103"])
        let first = try #require(section.lines.first)
        #expect(first.severity == .normal)
        #expect(first.text.hasPrefix("Message from Test Person, "))
        #expect(first.detail?.count ?? 0 <= 141)
        #expect(first.readAt == r.readAt)
        #expect(first.destination == .siteMessages)
        #expect(first.links.map(\.url.absoluteString) == ["https://linumic.com/wp-admin/admin.php?page=sureforms_entries#/entry/104",
                                                          "mailto:test.person@example.com?subject=Re:%20your%20message%20to%20Linumic"])
        #expect(section.lines[1].links.count == 1)   // no reply link for the crafted address
        #expect(section.notes == ["1 earlier messages already marked seen."])
        // The brief counts them as waiting on the owner.
        let brief = DailyBriefBuilder.build(briefInput(BriefSiteMessagesInput(isConfigured: true, reading: r, seenIDs: [])), changes: nil)
        #expect(brief.attention.filter { $0.kind == .siteMessages }.count == 3)
        let clear = DailyBriefBuilder.siteMessages(briefInput(BriefSiteMessagesInput(isConfigured: true, reading: r, seenIDs: [102, 103, 104])))
        #expect(clear.state == .allClear)
    }
}
