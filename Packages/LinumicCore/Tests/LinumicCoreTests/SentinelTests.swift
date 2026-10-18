import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only: sentinel-overview.json and sentinel-events.json were produced by running the repository's
// migrations on a scratch Postgres with made-up rounds and a made-up licence ("Sample Clinic"); never real data.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private final class Recorder: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> (Int, Data)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = handler(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let config = SupabaseConfig(url: URL(string: "https://sample.supabase.co")!, publishableKey: "sb_publishable_SAMPLE")
private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private func body(_ r: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
}

@Suite("Sentinel client")
struct SentinelClientTests {
    @Test func overviewCallsTheRPCAndDecodes() async throws {
        let data = try fixture("sentinel-overview")
        let t = Recorder { _ in (200, data) }
        let client = SentinelClient(config: config, transport: t, token: { "admin-jwt" })
        let o = try await client.overview(hours: 24)
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString == "https://sample.supabase.co/rest/v1/rpc/sentinel_overview")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "apikey") == "sb_publishable_SAMPLE")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer admin-jwt")
        #expect(try body(r)["hours"] as? Int == 24)

        #expect(o.windowHours == 24)
        #expect(o.lastRound?.id == 4)
        #expect(o.lastRound?.finishedAt == iso("2026-10-18T23:42:19Z"))
        #expect(o.unacknowledged == 2)
        #expect(o.snapshotCount == 1)
        #expect(o.lastSnapshot?.schemaVersion == 2)
        let site = try #require(o.targets.first { $0.targetID == "website.home" })
        #expect(site.state == .down)
        #expect(site.consecutiveFailures == 3)
        #expect(site.lastFailure == "TimeoutError: Signal timed out.")
        #expect(site.lastCheckState == .down)
        #expect(site.uptime == 0.25)
        #expect(site.lastLatencyMS == nil, "no latency without a response")
        let velro = try #require(o.targets.first { $0.targetID == "velro.api.live" })
        #expect(velro.state == .up && velro.lastFailureAt == nil && velro.uptime == 1)
    }

    @Test func eventsDecodeWithTheirDetails() async throws {
        let data = try fixture("sentinel-events")
        let t = Recorder { _ in (200, data) }
        let client = SentinelClient(config: config, transport: t, token: { "admin-jwt" })
        let events = try await client.events(limit: 20, includeAcknowledged: false)
        let r = try #require(t.requests.first)
        #expect(r.url?.path() == "/rest/v1/rpc/sentinel_recent_events")
        #expect(try body(r)["max_rows"] as? Int == 20)
        #expect(try body(r)["include_acknowledged"] as? Bool == false)

        #expect(events.map(\.id) == [2, 1])
        let licence = events[0]
        #expect(licence.kind == .licenceExpiring && licence.severity == .warning && !licence.isAcknowledged)
        #expect(licence.detail?.daysLeft == 5 && licence.detail?.threshold == 7 && licence.detail?.expires == "2026-10-23")
        let down = events[1]
        #expect(down.kind == .targetDown && down.severity == .critical)
        #expect(down.detail?.reason == .transport && down.detail?.failedRounds == 2)
        #expect(down.acknowledgedAt == iso("2026-10-18T23:52:15Z"))
    }

    @Test func acknowledgeAndRequestRound() async throws {
        let t = Recorder { r in (200, Data((r.url!.lastPathComponent == "request_sentinel_round" ? "false" : "").utf8)) }
        let client = SentinelClient(config: config, transport: t, token: { "admin-jwt" })
        try await client.acknowledge(eventID: 7)
        #expect(try body(t.requests[0])["event_id"] as? Int == 7)
        #expect(try await client.requestRound() == false, "refused within 2 minutes of the last request")
        #expect(t.requests[1].url?.lastPathComponent == "request_sentinel_round")
    }

    @Test func notAnAdminIsReportedAsSuch() async throws {
        let t = Recorder { _ in (400, Data(#"{"code":"42501","message":"Not authorised: Linumic OS admins only"}"#.utf8)) }
        let client = SentinelClient(config: config, transport: t, token: { "someone-else" })
        await #expect(throws: SupabaseError.notAuthorized) { try await client.overview(hours: 24) }
    }
}

@Suite("Sentinel summary")
struct SentinelSummaryTests {
    private let t0 = iso("2026-10-18T09:00:00Z")

    private func status(_ id: String, _ state: SentinelTargetState, last: MonitorState?, product: String = "velro") -> SentinelStatus {
        SentinelStatus(targetID: id, product: product, state: state, since: t0, lastCheckedAt: t0, samples: 6, available: 6,
                       lastCheckState: last)
    }

    private func overview(roundAt: Date?, targets: [SentinelStatus], unacknowledged: Int = 0, snapshotAt: Date? = nil) -> SentinelOverview {
        SentinelOverview(generatedAt: t0,
                         lastRound: roundAt.map { SentinelRound(id: 1, startedAt: $0, finishedAt: $0, source: "cron", targetCount: targets.count,
                                                               upCount: 0, degradedCount: 0, downCount: 0) },
                         targets: targets, unacknowledged: unacknowledged, snapshotCount: snapshotAt == nil ? 0 : 1,
                         lastSnapshot: snapshotAt.map { SentinelSnapshotInfo(id: 1, createdAt: $0, bytes: 100, schemaVersion: 2) })
    }

    @Test func nothingRecordedMeansNotRunning() {
        let s = SentinelSummary.make(overview(roundAt: nil, targets: []), now: t0)
        #expect(s.health == .notRunning)
        #expect(!s.snapshotOverdue, "no snapshot is expected before the Sentinel runs")
        #expect(!s.needsAttention)
        #expect(s.missingFromServer.count == MonitorCatalog.targets.count)
    }

    @Test func downOutranksSlowAndOneFailureIsOnlyFlapping() {
        let targets = [status("velro.api.live", .down, last: .down), status("velro.admin", .up, last: .degraded),
                       status("velro.api.ready", .up, last: .down)]
        let s = SentinelSummary.make(overview(roundAt: t0, targets: targets, snapshotAt: t0), now: t0.addingTimeInterval(300))
        #expect(s.health == .down(count: 1))
        #expect(s.slow.map(\.targetID) == ["velro.admin"])
        #expect(s.flapping.map(\.targetID) == ["velro.api.ready"])
        #expect(s.needsAttention)
    }

    @Test func slowOnlyAndAllUp() {
        let slow = SentinelSummary.make(overview(roundAt: t0, targets: [status("velro.admin", .up, last: .degraded)], snapshotAt: t0),
                                        now: t0.addingTimeInterval(60))
        #expect(slow.health == .slow(count: 1))
        #expect(!slow.needsAttention)
        let up = SentinelSummary.make(overview(roundAt: t0, targets: [status("velro.admin", .up, last: .up)], snapshotAt: t0),
                                      now: t0.addingTimeInterval(60))
        #expect(up.health == .allUp)
    }

    @Test func staleAfter25MinutesWins() {
        let o = overview(roundAt: t0, targets: [status("velro.api.live", .down, last: .down)], snapshotAt: t0)
        #expect(SentinelSummary.make(o, now: t0.addingTimeInterval(25 * 60)).health == .down(count: 1))
        #expect(SentinelSummary.make(o, now: t0.addingTimeInterval(25 * 60 + 1)).health == .stale(lastRoundAt: t0))
    }

    @Test func snapshotOverdueAndUnseenEventsNeedAttention() {
        let up = [status("velro.admin", .up, last: .up)]
        let noSnapshot = SentinelSummary.make(overview(roundAt: t0, targets: up), now: t0)
        #expect(noSnapshot.snapshotOverdue && noSnapshot.needsAttention)
        let old = SentinelSummary.make(overview(roundAt: t0, targets: up, snapshotAt: t0.addingTimeInterval(-9 * 86_400)), now: t0)
        #expect(old.snapshotOverdue)
        let fresh = SentinelSummary.make(overview(roundAt: t0, targets: up, snapshotAt: t0.addingTimeInterval(-6 * 86_400)), now: t0)
        #expect(!fresh.snapshotOverdue && !fresh.needsAttention)
        let unseen = SentinelSummary.make(overview(roundAt: t0, targets: up, unacknowledged: 1, snapshotAt: t0), now: t0)
        #expect(unseen.needsAttention)
    }

    @Test func catalogDriftIsReportedBothWays() {
        let targets = [status("velro.api.live", .up, last: .up), status("retired.target", .up, last: .up)]
        let s = SentinelSummary.make(overview(roundAt: t0, targets: targets, snapshotAt: t0), now: t0)
        #expect(s.unknownToApp == ["retired.target"])
        #expect(!s.missingFromServer.contains("velro.api.live"))
        #expect(s.missingFromServer.contains("website.home"))
    }

    @Test func fixtureOverviewReadsAsDown() throws {
        let o = try InventoryCoding.decoder().decode(SentinelOverview.self, from: try fixture("sentinel-overview"))
        let s = SentinelSummary.make(o, now: iso("2026-10-18T23:47:19Z"))
        #expect(s.health == .down(count: 1))
        #expect(s.down.map(\.targetID) == ["website.home"])
        #expect(!s.snapshotOverdue)
    }
}

@Suite("Sentinel matches the Monitor")
struct SentinelParityTests {
    /// supabase/functions/sentinel/targets.ts, found from this file's path (Tests/LinumicCoreTests -> repository root).
    private func serverTargets() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "supabase/functions/sentinel/targets.ts"), encoding: .utf8)
    }

    @Test func everyMonitorTargetIsCheckedByTheServerWithTheSameURL() throws {
        let ts = try serverTargets()
        for target in MonitorCatalog.targets {
            #expect(ts.contains(#"id: "\#(target.id)""#), "\(target.id) is missing from targets.ts")
            #expect(ts.contains(#"url: "\#(target.url.absoluteString)""#), "\(target.id): URL differs in targets.ts")
            #expect(ts.contains(#"product: "\#(target.product.rawValue)""#))
        }
        #expect(ts.components(separatedBy: #"id: ""#).count - 1 == MonitorCatalog.targets.count, "targets.ts has extra targets")
    }

    @Test func healthRulesAndThresholdsMatch() throws {
        let ts = try serverTargets()
        // Each target's entry runs from its id to the next `id:`; its health rule and slowAfter must match.
        for target in MonitorCatalog.targets {
            let start = try #require(ts.range(of: #"id: "\#(target.id)""#))
            let rest = ts[start.upperBound...]
            let entry = rest.range(of: "id: ").map { rest[..<$0.lowerBound] } ?? rest
            let slow = target.slowAfter.rounded() == target.slowAfter ? String(Int(target.slowAfter)) : String(target.slowAfter)
            #expect(entry.contains("slowAfter: \(slow)"), "\(target.id): slowAfter differs")
            switch target.kind {
            case .page: #expect(entry.contains("kind: page"), "\(target.id) should be a page")
            case let .health(format, expected):
                #expect(entry.contains(#"health("\#(format.rawValue)", "\#(expected)")"#), "\(target.id): health rule differs")
            }
        }
    }

    @Test func checkJSONHasTheShapeTheServerReads() throws {
        let result = MonitorResult(targetID: "velro.api.live", checkedAt: iso("2026-10-18T09:00:00Z"), state: .down,
                                   statusCode: 503, latencyMS: 120, reason: .httpStatus)
        let check = SentinelCheck(result, product: .velro)
        let object = try #require(JSONSerialization.jsonObject(with: try InventoryCoding.encoder().encode(check)) as? [String: Any])
        // Keys of `Check` in supabase/functions/sentinel/evaluate.ts, as read by sentinel_record_round().
        let serverKeys: Set = ["targetID", "product", "checkedAt", "state", "statusCode", "latencyMS", "healthStatus", "reason", "failure"]
        #expect(Set(object.keys).isSubset(of: serverKeys))
        #expect(object["checkedAt"] as? String == "2026-10-18T09:00:00Z")
        #expect(object["state"] as? String == "down" && object["reason"] as? String == "httpStatus" && object["product"] as? String == "velro")
    }
}
