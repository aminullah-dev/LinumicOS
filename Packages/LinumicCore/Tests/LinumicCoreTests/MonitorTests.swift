import Foundation
import Testing
@testable import LinumicCore

// monitor-*.json were fetched on 2026-10-09 with curl from the public, unauthenticated endpoints they are named
// after (VELRO /healthz and /readyz, WorkTrack and Talar /v1/health) and from rdap.org for linumic.com (trimmed to
// the domain object, its events and the registrar entity). No credentials were involved.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func target(_ id: String) -> MonitorTarget {
    MonitorCatalog.targets.first { $0.id == id }!
}

private let t0 = Date(timeIntervalSince1970: 1_791_590_400) // 2026-10-09T00:00:00Z

private func observation(_ id: String, status: Int? = 200, latency: TimeInterval? = 0.2, body: Data? = nil,
                         failure: String? = nil, headers: [String: String] = [:], at: Date = t0, cert: Date? = nil) -> MonitorObservation {
    MonitorObservation(targetID: id, checkedAt: at, statusCode: status, latency: latency, headers: headers, body: body,
                       failure: failure, certificateNotAfter: cert)
}

private func result(_ id: String, _ state: MonitorState, at: Date = t0, latency: Int? = 200) -> MonitorResult {
    MonitorResult(targetID: id, checkedAt: at, state: state, latencyMS: latency, reason: state == .down ? .transport : nil)
}

/// Answers each target from a table; records nothing else.
private struct StubProbe: MonitorProbe {
    let answers: [String: MonitorObservation]
    func probe(_ target: MonitorTarget) async -> MonitorObservation {
        answers[target.id] ?? observation(target.id, status: nil, latency: nil, failure: "offline")
    }
}

private final class RDAPStub: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: Data
    let finalURL: URL
    private(set) var requests: [URLRequest] = []
    init(status: Int, body: Data, finalURL: URL) { self.status = status; self.body = body; self.finalURL = finalURL }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Monitor catalog")
struct MonitorCatalogTests {
    @Test func everyTargetIsHTTPSGetWithASourceAndUniqueID() {
        let targets = MonitorCatalog.targets
        #expect(Set(targets.map(\.id)).count == targets.count)
        for t in targets {
            #expect(t.url.scheme == "https", "\(t.id)")
            #expect(!t.source.isEmpty && t.source.contains(":"), "\(t.id) needs a file:line source")
            #expect(t.url.user == nil && t.url.password == nil && t.url.query == nil, "\(t.id) must carry no credentials")
        }
        #expect(Set(targets.map(\.product)) == Set(MonitorProduct.allCases))
    }

    @Test func healthEndpointsMatchTheProductRoutes() {
        #expect(target("velro.api.live").url.path() == "/healthz")
        #expect(target("velro.api.ready").url.path() == "/readyz")
        #expect(target("worktrack.api").url.absoluteString == "https://worktrack-prod.web.app/v1/health")
        #expect(target("talar.api").url.absoluteString == "https://asia-south1-talar-af-prod.cloudfunctions.net/api/v1/health")
        #expect(MonitorCatalog.targets.filter(\.inspectsCache).map(\.id) == ["website.home"])
    }

    @Test func domainsCoverOnlyLinumicHosts() {
        #expect(MonitorCatalog.domain(for: "console.linumic.com")?.name == "linumic.com")
        #expect(MonitorCatalog.domain(for: "linumic.com")?.name == "linumic.com")
        #expect(MonitorCatalog.domain(for: "safebeauty.web.app") == nil)
        #expect(MonitorCatalog.domain(for: "notlinumic.com") == nil)
        #expect(MonitorCatalog.hosts.count == Set(MonitorCatalog.hosts).count)
        #expect(MonitorCatalog.hosts.contains("api.velro.linumic.com"))
    }
}

@Suite("Monitor evaluation")
struct MonitorEvaluationTests {
    @Test func parsesEachProductsHealthFixture() throws {
        #expect(MonitorHealth.parse(try fixture("monitor-velro-readyz"), format: .velroEnvelope) == MonitorHealth(status: "ready", database: "ok"))
        #expect(MonitorHealth.parse(try fixture("monitor-velro-healthz"), format: .velroEnvelope) == MonitorHealth(status: "alive", database: nil))
        #expect(MonitorHealth.parse(try fixture("monitor-worktrack-health"), format: .dataStatus) == MonitorHealth(status: "ok", database: nil))
        #expect(MonitorHealth.parse(try fixture("monitor-talar-health"), format: .okFlag) == MonitorHealth(status: "ok", database: nil))
        #expect(MonitorHealth.parse(Data("<!doctype html>".utf8), format: .dataStatus) == nil)
        #expect(MonitorHealth.parse(Data(#"{"ok":false}"#.utf8), format: .okFlag)?.status == "not ok")
    }

    @Test func healthyEndpointIsUp() throws {
        let r = MonitorEvaluator.evaluate(observation("velro.api.ready", latency: 0.383, body: try fixture("monitor-velro-readyz")),
                                          target: target("velro.api.ready"))
        #expect(r.state == .up)
        #expect(r.healthStatus == "ready")
        #expect(r.latencyMS == 383)
        #expect(r.reason == nil)
    }

    @Test func databaseNotOkIsDown() {
        let body = Data(#"{"data":{"status":"ready","database":"error"}}"#.utf8)
        let r = MonitorEvaluator.evaluate(observation("velro.api.ready", body: body), target: target("velro.api.ready"))
        #expect(r.state == .down)
        #expect(r.reason == .unhealthy)
    }

    @Test func htmlInPlaceOfHealthIsDown() {
        let r = MonitorEvaluator.evaluate(observation("worktrack.api", body: Data("<html>".utf8)), target: target("worktrack.api"))
        #expect(r.state == .down)
        #expect(r.reason == .unreadableHealth)
    }

    @Test func statusCodesAndTransportErrors() {
        let page = target("website.home")
        #expect(MonitorEvaluator.evaluate(observation(page.id, status: 503), target: page).state == .down)
        #expect(MonitorEvaluator.evaluate(observation(page.id, status: 503), target: page).reason == .httpStatus)
        #expect(MonitorEvaluator.evaluate(observation(page.id, status: 404), target: page).state == .down)
        #expect(MonitorEvaluator.evaluate(observation(page.id, status: 302), target: page).state == .up)
        let offline = MonitorEvaluator.evaluate(observation(page.id, status: nil, latency: nil, failure: "The Internet connection appears to be offline."), target: page)
        #expect(offline.state == .down)
        #expect(offline.reason == .transport)
        #expect(offline.failure != nil)
    }

    @Test func slowAnswerIsDegradedWithPerTargetThreshold() {
        #expect(MonitorEvaluator.evaluate(observation("website.home", latency: 3.5), target: target("website.home")).state == .degraded)
        // Talar's Cloud Function gets 10 s for a cold start.
        let talar = MonitorEvaluator.evaluate(observation("talar.api", latency: 5.4, body: Data(#"{"ok":true}"#.utf8)), target: target("talar.api"))
        #expect(talar.state == .up)
    }

    @Test func expiryLevelsAt30_14_7Days() {
        #expect(ExpiryLevel.level(daysLeft: 90) == .ok)
        #expect(ExpiryLevel.level(daysLeft: 30) == .ok)
        #expect(ExpiryLevel.level(daysLeft: 29) == .within30)
        #expect(ExpiryLevel.level(daysLeft: 14) == .within30)
        #expect(ExpiryLevel.level(daysLeft: 13) == .within14)
        #expect(ExpiryLevel.level(daysLeft: 7) == .within14)
        #expect(ExpiryLevel.level(daysLeft: 6) == .within7)
        #expect(ExpiryLevel.level(daysLeft: 0) == .within7)
        #expect(ExpiryLevel.level(daysLeft: -1) == .expired)
        #expect(ExpiryLevel.daysLeft(until: t0.addingTimeInterval(36 * 3600), now: t0) == 1)
        #expect(ExpiryLevel.daysLeft(until: t0.addingTimeInterval(-3600), now: t0) == -1)
    }
}

@Suite("Monitor RDAP and headers")
struct MonitorParsingTests {
    @Test func parsesTheLinumicRDAPFixture() throws {
        let d = try RDAPDomain.parse(try fixture("monitor-rdap-linumic-com"))
        #expect(d.ldhName == "LINUMIC.COM")
        #expect(d.registrar == "GoDaddy.com, LLC")
        #expect(d.expiration == ISO8601DateFormatter().date(from: "2029-08-15T23:22:47Z"))
        #expect(d.registration == ISO8601DateFormatter().date(from: "2026-08-15T23:22:47Z"))
        #expect(d.databaseUpdated == ISO8601DateFormatter().date(from: "2026-10-09T17:54:32Z"))
    }

    @Test func rdapAcceptsFractionalSecondsAndRejectsNonRDAP() throws {
        let json = #"{"ldhName":"example.com","events":[{"eventAction":"expiration","eventDate":"2027-01-02T03:04:05.123Z"}]}"#
        #expect(try RDAPDomain.parse(Data(json.utf8)).expiration != nil)
        #expect(throws: RDAPError.notJSON) { try RDAPDomain.parse(Data("<html>".utf8)) }
        #expect(throws: RDAPError.notJSON) { try RDAPDomain.parse(Data(#"{"errorCode":404}"#.utf8)) }
    }

    @Test func rdapClientRecordsTheAnsweringURLAndTime() async throws {
        let final = URL(string: "https://rdap.verisign.com/com/v1/domain/linumic.com")!
        let stub = RDAPStub(status: 200, body: try fixture("monitor-rdap-linumic-com"), finalURL: final)
        let reading = try await RDAPClient(transport: stub, now: { t0 }).lookup("linumic.com")
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].url?.absoluteString == "https://rdap.org/domain/linumic.com")
        #expect(stub.requests[0].httpMethod == "GET")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(reading.sourceURL == final.absoluteString)
        #expect(reading.fetchedAt == t0)
        #expect(reading.registrar == "GoDaddy.com, LLC")
        #expect(reading.daysLeft(now: t0)! > 1000)
        #expect(reading.level(now: t0) == .ok)
    }

    @Test func rdapClientSurfacesHTTPErrors() async throws {
        let stub = RDAPStub(status: 404, body: Data(), finalURL: URL(string: "https://rdap.org/domain/x.af")!)
        await #expect(throws: RDAPError.http(404)) { try await RDAPClient(transport: stub).lookup("x.af") }
    }

    @Test func cacheControlParsing() {
        let c = CacheControl.parse("public, max-age=2678400")
        #expect(c.maxAge == 2_678_400)
        #expect(c.directives["public"] == "")
        #expect(CacheControl.parse("no-cache, s-maxage=600, max-age=\"60\"").sharedMaxAge == 600)
        #expect(CacheControl.parse("no-cache, s-maxage=600, max-age=\"60\"").maxAge == 60)
        #expect(CacheControl.parse("").maxAge == nil)
    }

    @Test func linumicHomeCacheIsFlaggedOverADay() {
        // The headers linumic.com returned on 2026-10-09 (GoDaddy CDN in front of WordPress).
        let headers = ["Cache-Control": "public, max-age=2678400", "CF-Cache-Status": "HIT", "Age": "1679"]
        let check = CacheCheck(url: "https://linumic.com/", headers: headers, checkedAt: t0)
        #expect(check.maxAge == 2_678_400)
        #expect(check.cdnStatus == "HIT")
        #expect(check.age == 1679)
        #expect(check.isLongerThanADay)
        #expect(!CacheCheck(url: "u", headers: ["cache-control": "max-age=3600"], checkedAt: t0).isLongerThanADay)
        #expect(!CacheCheck(url: "u", headers: [:], checkedAt: t0).isLongerThanADay)
        #expect(CacheCheck(url: "u", headers: ["cache-control": "max-age=60, s-maxage=172800"], checkedAt: t0).isLongerThanADay)
    }
}

@Suite("Monitor history, alerts and schedule")
struct MonitorStateTests {
    @Test func historyKeepsOnly24HoursAndComputesUptime() {
        var h = MonitorHistory()
        h.append(result("a", .up, at: t0.addingTimeInterval(-25 * 3600)), now: t0)
        h.append(result("a", .up, at: t0.addingTimeInterval(-3600), latency: 100), now: t0)
        h.append(result("a", .degraded, at: t0.addingTimeInterval(-1800), latency: 4000), now: t0)
        h.append(result("a", .down, at: t0.addingTimeInterval(-600), latency: nil), now: t0)
        h.append(result("a", .up, at: t0, latency: 120), now: t0)
        h.append(result("a", .unknown, at: t0), now: t0)
        #expect(h.recent("a", now: t0).count == 4)
        #expect(h.uptime("a", now: t0) == 0.75)
        #expect(h.latencies("a", now: t0) == [100, 4000, nil, 120])
        #expect(h.uptime("b", now: t0) == nil)
        // A day later everything has aged out.
        h.prune(now: t0.addingTimeInterval(24 * 3600 + 1))
        #expect(h.samples["a"] == nil)
    }

    @Test func historyIsCappedAndDropsRetiredTargets() {
        var h = MonitorHistory()
        for i in 0..<(MonitorHistory.maxSamplesPerTarget + 20) {
            h.append(result("a", .up, at: t0.addingTimeInterval(Double(i))), now: t0.addingTimeInterval(Double(i)))
        }
        #expect(h.samples["a"]?.count == MonitorHistory.maxSamplesPerTarget)
        h.prune(now: t0.addingTimeInterval(700), keeping: ["b"])
        #expect(h.samples["a"] == nil)
    }

    @Test func downAlertNeedsTwoConsecutiveFailures() {
        var s = MonitorAlertState()
        let v1 = s.record(result("a", .down))
        #expect(v1 == nil)
        let v2 = s.record(result("a", .up))
        #expect(v2 == nil) // one blip, never alerted, so no recovery either
        let v3 = s.record(result("a", .down))
        #expect(v3 == nil)
        let v4 = s.record(result("a", .down))
        #expect(v4 == .down(targetID: "a"))
        let v5 = s.record(result("a", .down))
        #expect(v5 == nil) // only once per outage
        let v6 = s.record(result("a", .degraded))
        #expect(v6 == .recovered(targetID: "a"))
        let v7 = s.record(result("a", .up))
        #expect(v7 == nil)
        let v8 = s.record(result("a", .unknown))
        #expect(v8 == nil)
    }

    @Test func expiryAlertsOnlyWhenEnteringAWorseWindow() {
        var s = MonitorAlertState()
        let v9 = s.recordExpiry(key: "cert:x", level: .ok)
        #expect(!v9)
        let v10 = s.recordExpiry(key: "cert:x", level: .within30)
        #expect(v10)
        let v11 = s.recordExpiry(key: "cert:x", level: .within30)
        #expect(!v11)
        let v12 = s.recordExpiry(key: "cert:x", level: .within14)
        #expect(v12)
        let v13 = s.recordExpiry(key: "cert:x", level: .within7)
        #expect(v13)
        let v14 = s.recordExpiry(key: "cert:x", level: .expired)
        #expect(v14)
        // Renewed: back to ok, and the next approach alerts again.
        let v15 = s.recordExpiry(key: "cert:x", level: .ok)
        #expect(!v15)
        let v16 = s.recordExpiry(key: "cert:x", level: .within30)
        #expect(v16)
        // Already inside 14 days at first sight: one alert.
        let v17 = s.recordExpiry(key: "cert:y", level: .within14)
        #expect(v17)
    }

    @Test func scheduleBacksOffAndRespectsLowPower() {
        #expect(MonitorSchedule.interval(failedRounds: 0, lowPower: false) == 300)
        #expect(MonitorSchedule.interval(failedRounds: 1, lowPower: false) == 600)
        #expect(MonitorSchedule.interval(failedRounds: 2, lowPower: false) == 1200)
        #expect(MonitorSchedule.interval(failedRounds: 9, lowPower: false) == 1800)
        #expect(MonitorSchedule.interval(failedRounds: 0, lowPower: true) == 600)
        #expect(MonitorSchedule.interval(failedRounds: 3, lowPower: true) == 1800)
        #expect(MonitorSchedule.isDomainCheckDue(lastFetch: nil, now: t0))
        #expect(!MonitorSchedule.isDomainCheckDue(lastFetch: t0.addingTimeInterval(-3600), now: t0))
        #expect(MonitorSchedule.isDomainCheckDue(lastFetch: t0.addingTimeInterval(-13 * 3600), now: t0))
    }
}

@Suite("Monitor runner and snapshot")
struct MonitorRunnerTests {
    private func healthy(_ at: Date, certDays: Double = 60) throws -> [String: MonitorObservation] {
        var answers: [String: MonitorObservation] = [:]
        let bodies: [String: Data] = [
            "velro.api.live": try fixture("monitor-velro-healthz"), "velro.api.ready": try fixture("monitor-velro-readyz"),
            "worktrack.api": try fixture("monitor-worktrack-health"), "worktrack.demo": try fixture("monitor-worktrack-health"),
            "talar.api": try fixture("monitor-talar-health"),
        ]
        for t in MonitorCatalog.targets {
            answers[t.id] = observation(t.id, body: bodies[t.id],
                                        headers: t.inspectsCache ? ["cache-control": "public, max-age=2678400", "cf-cache-status": "HIT"] : [:],
                                        at: at, cert: at.addingTimeInterval(certDays * 86_400))
        }
        return answers
    }

    @Test func aHealthyRoundIsAllUpWithCertificatesAndCache() async throws {
        let round = await MonitorRunner(probe: StubProbe(answers: try healthy(t0)), now: { t0 }).run()
        #expect(round.results.count == MonitorCatalog.targets.count)
        #expect(round.results.allSatisfy { $0.state == .up })
        #expect(Set(round.certificates.map(\.host)) == Set(MonitorCatalog.hosts))
        #expect(round.cache?.isLongerThanADay == true)
        #expect(!round.nothingAnswered)

        var snap = MonitorSnapshot()
        let v18 = snap.apply(round, now: t0)
        #expect(v18.isEmpty)
        let summary = MonitorSummary(snapshot: snap, now: t0)
        #expect(summary.up == MonitorCatalog.targets.count)
        #expect(summary.down == 0 && summary.notChecked == 0)
        #expect(summary.expiryWarnings == 0)
        #expect(summary.soonestExpiryDays == 60)
        #expect(snap.certificate(for: target("worktrack.console"))?.host == "console.linumic.com")
    }

    @Test func twoFailedRoundsAlertOnceAndRecover() async throws {
        var snap = MonitorSnapshot()
        var answers = try healthy(t0)
        answers["talar.api"] = observation("talar.api", status: 500, at: t0)
        let r1 = await MonitorRunner(probe: StubProbe(answers: answers), now: { t0 }).run()
        let v19 = snap.apply(r1, now: t0)
        #expect(v19.isEmpty)
        let r2 = await MonitorRunner(probe: StubProbe(answers: answers), now: { t0 }).run()
        let v20 = snap.apply(r2, now: t0.addingTimeInterval(300))
        #expect(v20 == [.down(targetID: "talar.api")])
        #expect(MonitorSummary(snapshot: snap, now: t0).down == 1)
        let r3 = await MonitorRunner(probe: StubProbe(answers: try healthy(t0)), now: { t0 }).run()
        let v21 = snap.apply(r3, now: t0.addingTimeInterval(600))
        #expect(v21 == [.recovered(targetID: "talar.api")])
        #expect(snap.history.uptime("talar.api", now: t0.addingTimeInterval(600))! < 0.34)
    }

    @Test func anOfflineRoundRaisesNoAlertAndCountsForBackoff() async throws {
        var snap = MonitorSnapshot()
        let offline = StubProbe(answers: [:])
        for i in 0..<3 {
            let round = await MonitorRunner(probe: offline, now: { t0 }).run()
            #expect(round.nothingAnswered)
            let v22 = snap.apply(round, now: t0.addingTimeInterval(Double(i) * 300))
            #expect(v22.isEmpty)
        }
        #expect(snap.failedRounds == 3)
        #expect(MonitorSchedule.interval(failedRounds: snap.failedRounds, lowPower: false) == 1800)
        let back = await MonitorRunner(probe: StubProbe(answers: try healthy(t0)), now: { t0 }).run()
        _ = snap.apply(back, now: t0.addingTimeInterval(900))
        #expect(snap.failedRounds == 0)
    }

    @Test func certificateEnteringAWindowAlertsOncePerHost() async throws {
        var snap = MonitorSnapshot()
        let round = await MonitorRunner(probe: StubProbe(answers: try healthy(t0, certDays: 20)), now: { t0 }).run()
        let alerts = snap.apply(round, now: t0)
        #expect(alerts.count == MonitorCatalog.hosts.count)
        #expect(alerts.contains(.certificate(host: "linumic.com", level: .within30, daysLeft: 20)))
        // Same reading a round later: nothing new. Eight days later it is inside 14 days (re-judged without a new read).
        let quiet = await MonitorRunner(probe: StubProbe(answers: [:]), now: { t0 }).run()
        let v23 = snap.apply(quiet, now: t0.addingTimeInterval(300))
        #expect(v23.isEmpty)
        let later = snap.apply(quiet, now: t0.addingTimeInterval(8 * 86_400))
        #expect(later.contains(.certificate(host: "linumic.com", level: .within14, daysLeft: 12)))
        #expect(MonitorSummary(snapshot: snap, now: t0.addingTimeInterval(8 * 86_400)).expiryWarnings == MonitorCatalog.hosts.count)
    }

    @Test func domainReadingAlertsInsideTheWindow() {
        var snap = MonitorSnapshot()
        let reading = DomainReading(name: "linumic.com", expiresAt: t0.addingTimeInterval(10 * 86_400), registeredAt: nil,
                                    registrar: "GoDaddy.com, LLC", rdapUpdatedAt: nil, sourceURL: "https://rdap.verisign.com/com/v1/domain/linumic.com", fetchedAt: t0)
        let v24 = snap.apply(domain: reading, now: t0)
        #expect(v24 == [.domain(name: "linumic.com", level: .within14, daysLeft: 10)])
        let v25 = snap.apply(domain: reading, now: t0)
        #expect(v25.isEmpty)
        #expect(snap.domain(for: target("velro.admin"))?.name == "linumic.com")
        #expect(snap.domain(for: target("talar.web")) == nil)
        snap.recordDomainError("linumic.com", message: "offline")
        #expect(snap.domainErrors["linumic.com"] == "offline")
        _ = snap.apply(domain: reading, now: t0)
        #expect(snap.domainErrors["linumic.com"] == nil)
    }

    @Test func snapshotRoundTripsThroughTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "monitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MonitorStore(fileURL: dir.appending(path: "monitor.json"))
        #expect(store.load() == MonitorSnapshot())
        var snap = MonitorSnapshot()
        _ = snap.apply(await MonitorRunner(probe: StubProbe(answers: try healthy(t0)), now: { t0 }).run(), now: t0)
        try store.save(snap)
        let loaded = store.load()
        #expect(loaded == snap)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("talar-api")) // no response body is stored
    }
}
