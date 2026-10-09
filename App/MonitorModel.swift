import Foundation
import LinumicCore
import Observation
import Security

/// Monitor (پایش): live health of every public Linumic endpoint, TLS certificate and domain expiry. Plain GETs to
/// public URLs only (`MonitorCatalog`); no credential, cookie or session is ever attached. Results stay on this
/// device (`monitor.json`, last 24 hours).
@MainActor
@Observable
final class MonitorModel {
    static let notifyKey = "LCCNotifyMonitor"

    private(set) var snapshot: MonitorSnapshot
    private(set) var isChecking = false
    private(set) var isCheckingDomains = false
    /// Advances every minute so relative times and day counts stay current between rounds.
    private(set) var now = Date()

    private let store: MonitorStore?
    private let runner = MonitorRunner(probe: URLSessionMonitorProbe())
    private let rdap = RDAPClient(transport: URLSessionTransport(session: MonitorSessions.rdap))

    init() {
        store = (try? MonitorStore.defaultFileURL()).map(MonitorStore.init(fileURL:))
        snapshot = store?.load() ?? MonitorSnapshot()
    }

    var targets: [MonitorTarget] { MonitorCatalog.targets }
    var summary: MonitorSummary { MonitorSummary(snapshot: snapshot, now: now) }

    func targets(for product: MonitorProduct) -> [MonitorTarget] { targets.filter { $0.product == product } }
    func result(for target: MonitorTarget) -> MonitorResult? { snapshot.latest[target.id] }
    func uptime(for target: MonitorTarget) -> Double? { snapshot.history.uptime(target.id, now: now) }
    func latencies(for target: MonitorTarget) -> [Int?] { snapshot.history.latencies(target.id, now: now) }
    func samples(for target: MonitorTarget) -> Int { snapshot.history.recent(target.id, now: now).count }

    /// Runs while the app is open: a round at once, then every 5 minutes (longer after rounds where nothing
    /// answered, and twice as long in Low Power Mode). Domain registrations are re-read every 12 hours.
    func run() async {
        while !Task.isCancelled {
            await checkNow()
            let interval = MonitorSchedule.interval(failedRounds: snapshot.failedRounds,
                                                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            // Tick every minute so "checked 3 min ago" and the day counts stay true while waiting.
            var waited: TimeInterval = 0
            while waited < interval, !Task.isCancelled {
                let step = min(60, interval - waited)
                try? await Task.sleep(for: .seconds(step))
                waited += step
                now = .now
            }
        }
    }

    /// One round of every check (the "Check now" button). Overlapping requests are ignored.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let round = await runner.run(targets)
        now = .now
        let alerts = snapshot.apply(round, now: now)
        if MonitorSchedule.isDomainCheckDue(lastFetch: snapshot.lastDomainFetchAt, now: now), !round.nothingAnswered {
            await checkDomains()
        }
        save()
        await MonitorNotifier.post(alerts, targets: targets, now: now)
    }

    /// Reads every domain's registration from public RDAP.
    func checkDomains() async {
        guard !isCheckingDomains else { return }
        isCheckingDomains = true
        defer { isCheckingDomains = false }
        var alerts: [MonitorAlert] = []
        for domain in MonitorCatalog.domains {
            do {
                let reading = try await rdap.lookup(domain.name)
                alerts += snapshot.apply(domain: reading, now: .now)
            } catch {
                snapshot.recordDomainError(domain.name, message: error.localizedDescription)
            }
        }
        snapshot.lastDomainFetchAt = .now
        save()
        await MonitorNotifier.post(alerts, targets: targets, now: now)
    }

    private func save() {
        try? store?.save(snapshot)
    }
}

// MARK: - Networking (App layer)

enum MonitorSessions {
    /// Ephemeral: no cookies, no credential storage, no cache, so nothing of the owner's ever rides along.
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "LinumicOS-Monitor/1"]
        return c
    }

    static let rdap = URLSession(configuration: configuration())
}

/// One GET per target on a fresh ephemeral session, so every request makes its own TLS handshake and the
/// certificate can be read. Reads the leaf certificate's notAfter, then lets the system evaluate trust as usual
/// (an invalid certificate fails the request). Any other authentication challenge is refused.
struct URLSessionMonitorProbe: MonitorProbe {
    func probe(_ target: MonitorTarget) async -> MonitorObservation {
        let capture = TLSCapture()
        let session = URLSession(configuration: MonitorSessions.configuration(), delegate: capture, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        let started = Date()
        let clock = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - clock
            let latency = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let k = key as? String, let v = value as? String { headers[k] = v }
            }
            return MonitorObservation(targetID: target.id, checkedAt: started, statusCode: http?.statusCode, latency: latency,
                                      headers: headers, body: target.isHealthEndpoint ? data.prefix(16_384) : nil,
                                      certificateNotAfter: capture.notAfter)
        } catch {
            return MonitorObservation(targetID: target.id, checkedAt: started, statusCode: nil, latency: nil,
                                      failure: error.localizedDescription, certificateNotAfter: capture.notAfter)
        }
    }
}

private final class TLSCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _notAfter: Date?
    var notAfter: Date? { lock.withLock { _notAfter } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Never answer a password or client-certificate challenge.
            return (.rejectProtectionSpace, nil)
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
           let date = SecCertificateCopyNotValidAfterDate(leaf) as Date? {
            lock.withLock { _notAfter = date }
        }
        return (.performDefaultHandling, nil)
    }
}
