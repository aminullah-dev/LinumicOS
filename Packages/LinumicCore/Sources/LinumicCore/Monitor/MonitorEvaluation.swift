import Foundation

/// What one GET returned, before any judgement. Built by the app's probe (or a test).
public struct MonitorObservation: Sendable {
    public let targetID: String
    public let checkedAt: Date
    public let statusCode: Int?
    /// Seconds from sending the request to the end of the body.
    public let latency: TimeInterval?
    /// Response headers with lower-cased names.
    public let headers: [String: String]
    /// Kept only for health endpoints; pages are not stored.
    public let body: Data?
    /// The transport error (DNS, TLS, timeout, offline), when there was no response.
    public let failure: String?
    /// The leaf certificate's notAfter, when the TLS handshake was seen on this request.
    public let certificateNotAfter: Date?

    public init(targetID: String, checkedAt: Date, statusCode: Int?, latency: TimeInterval?, headers: [String: String] = [:],
                body: Data? = nil, failure: String? = nil, certificateNotAfter: Date? = nil) {
        self.targetID = targetID
        self.checkedAt = checkedAt
        self.statusCode = statusCode
        self.latency = latency
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
        self.failure = failure
        self.certificateNotAfter = certificateNotAfter
    }
}

public enum MonitorState: String, Codable, Sendable, CaseIterable {
    case up, degraded, down, unknown

    /// Up or merely slow: the service answered correctly.
    public var isAvailable: Bool { self == .up || self == .degraded }
}

public enum MonitorReason: String, Codable, Sendable {
    /// No HTTP response (DNS, TLS, timeout, offline).
    case transport
    /// HTTP 4xx or 5xx.
    case httpStatus
    /// The health endpoint answered but did not report the expected status.
    case unhealthy
    /// The health endpoint's body was not the expected JSON (e.g. an HTML page served in its place).
    case unreadableHealth
    /// Answered correctly but slower than the target's threshold.
    case slow
}

/// The judged outcome of one check. Contains no response body.
public struct MonitorResult: Codable, Sendable, Identifiable, Equatable {
    public let targetID: String
    public let checkedAt: Date
    public let state: MonitorState
    public let statusCode: Int?
    public let latencyMS: Int?
    /// The status the health endpoint reported ("alive", "ready", "ok"), when it is one.
    public let healthStatus: String?
    public let reason: MonitorReason?
    public let failure: String?

    public var id: String { targetID }

    public init(targetID: String, checkedAt: Date, state: MonitorState, statusCode: Int? = nil, latencyMS: Int? = nil,
                healthStatus: String? = nil, reason: MonitorReason? = nil, failure: String? = nil) {
        self.targetID = targetID
        self.checkedAt = checkedAt
        self.state = state
        self.statusCode = statusCode
        self.latencyMS = latencyMS
        self.healthStatus = healthStatus
        self.reason = reason
        self.failure = failure
    }
}

/// A parsed health body.
public struct MonitorHealth: Equatable, Sendable {
    public let status: String
    public let database: String?

    /// Reads the body in the given product format; nil when it is not that JSON shape.
    public static func parse(_ data: Data, format: MonitorHealthFormat) -> MonitorHealth? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch format {
        case .velroEnvelope, .dataStatus:
            guard let inner = object["data"] as? [String: Any], let status = inner["status"] as? String else { return nil }
            return MonitorHealth(status: status, database: inner["database"] as? String)
        case .okFlag:
            guard let ok = object["ok"] as? Bool else { return nil }
            return MonitorHealth(status: ok ? "ok" : "not ok", database: nil)
        }
    }

    /// Healthy when the status matches and, where a database is reported, it is "ok".
    public func isHealthy(expected: String) -> Bool {
        status == expected && (database == nil || database == "ok")
    }
}

public enum MonitorEvaluator {
    public static func evaluate(_ observation: MonitorObservation, target: MonitorTarget) -> MonitorResult {
        let latencyMS = observation.latency.map { Int(($0 * 1000).rounded()) }
        func result(_ state: MonitorState, _ reason: MonitorReason?, health: String? = nil) -> MonitorResult {
            MonitorResult(targetID: target.id, checkedAt: observation.checkedAt, state: state, statusCode: observation.statusCode,
                          latencyMS: latencyMS, healthStatus: health, reason: reason, failure: observation.failure)
        }
        guard observation.failure == nil, let code = observation.statusCode else { return result(.down, .transport) }
        guard (200..<400).contains(code) else { return result(.down, .httpStatus) }
        var health: String?
        if case let .health(format, expected) = target.kind {
            guard let body = observation.body, let parsed = MonitorHealth.parse(body, format: format) else {
                return result(.down, .unreadableHealth)
            }
            health = parsed.status
            guard parsed.isHealthy(expected: expected) else { return result(.down, .unhealthy, health: health) }
        }
        if let latency = observation.latency, latency > target.slowAfter { return result(.degraded, .slow, health: health) }
        return result(.up, nil, health: health)
    }
}

// MARK: - Expiry (TLS certificates and domain registrations)

/// How close an expiry is. Warnings start at 30, 14 and 7 days.
public enum ExpiryLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case ok = 0, within30, within14, within7, expired

    public static func < (a: ExpiryLevel, b: ExpiryLevel) -> Bool { a.rawValue < b.rawValue }

    public static func level(daysLeft: Int) -> ExpiryLevel {
        switch daysLeft {
        case ..<0: .expired
        case ..<7: .within7
        case ..<14: .within14
        case ..<30: .within30
        default: .ok
        }
    }

    /// Whole days left (rounded down); negative once past.
    public static func daysLeft(until date: Date, now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    public var isWarning: Bool { self != .ok }
}

/// A host's TLS leaf certificate expiry, with the time it was read.
public struct CertificateReading: Codable, Sendable, Equatable {
    public let host: String
    public let notAfter: Date
    public let readAt: Date

    public init(host: String, notAfter: Date, readAt: Date) {
        self.host = host
        self.notAfter = notAfter
        self.readAt = readAt
    }

    public func daysLeft(now: Date) -> Int { ExpiryLevel.daysLeft(until: notAfter, now: now) }
    public func level(now: Date) -> ExpiryLevel { .level(daysLeft: daysLeft(now: now)) }
}

/// A domain's registration, as public RDAP reported it, with the URL it came from and the fetch time.
public struct DomainReading: Codable, Sendable, Equatable {
    public let name: String
    public let expiresAt: Date?
    public let registeredAt: Date?
    public let registrar: String?
    /// The RDAP server's own "last update of RDAP database" time.
    public let rdapUpdatedAt: Date?
    /// The URL that answered (after rdap.org's redirect to the registry).
    public let sourceURL: String
    public let fetchedAt: Date

    public init(name: String, expiresAt: Date?, registeredAt: Date?, registrar: String?, rdapUpdatedAt: Date?,
                sourceURL: String, fetchedAt: Date) {
        self.name = name
        self.expiresAt = expiresAt
        self.registeredAt = registeredAt
        self.registrar = registrar
        self.rdapUpdatedAt = rdapUpdatedAt
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
    }

    public func daysLeft(now: Date) -> Int? { expiresAt.map { ExpiryLevel.daysLeft(until: $0, now: now) } }
    public func level(now: Date) -> ExpiryLevel? { daysLeft(now: now).map(ExpiryLevel.level(daysLeft:)) }
}

// MARK: - RDAP

public enum RDAPError: Error, Equatable, LocalizedError {
    case notJSON
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notJSON: L("The RDAP answer was not RDAP JSON.")
        case .http(let code): LF("RDAP returned HTTP %d.", code)
        }
    }
}

/// The parts of an RFC 9083 domain object the Monitor shows.
public struct RDAPDomain: Equatable, Sendable {
    public let ldhName: String?
    public let expiration: Date?
    public let registration: Date?
    public let lastChanged: Date?
    public let databaseUpdated: Date?
    public let registrar: String?

    public static func parse(_ data: Data) throws -> RDAPDomain {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RDAPError.notJSON }
        var dates: [String: Date] = [:]
        for event in object["events"] as? [[String: Any]] ?? [] {
            if let action = event["eventAction"] as? String, let text = event["eventDate"] as? String, let date = parseDate(text) {
                dates[action.lowercased()] = date
            }
        }
        var registrar: String?
        for entity in object["entities"] as? [[String: Any]] ?? [] where (entity["roles"] as? [String])?.contains("registrar") == true {
            registrar = vcardName(entity["vcardArray"])
        }
        guard object["ldhName"] != nil || !dates.isEmpty else { throw RDAPError.notJSON }
        return RDAPDomain(ldhName: object["ldhName"] as? String, expiration: dates["expiration"], registration: dates["registration"],
                          lastChanged: dates["last changed"], databaseUpdated: dates["last update of rdap database"],
                          registrar: registrar)
    }

    /// `["vcard", [["version",{},"text","4.0"], ["fn",{},"text","GoDaddy.com, LLC"]]]` -> the fn value.
    static func vcardName(_ value: Any?) -> String? {
        guard let array = value as? [Any], array.count > 1, let props = array[1] as? [[Any]] else { return nil }
        return props.first { ($0.first as? String) == "fn" }.flatMap { $0.count > 3 ? $0[3] as? String : nil }
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Reads a domain's registration from public RDAP. One GET, no credentials, follows rdap.org's redirect.
public struct RDAPClient: Sendable {
    public static let bootstrapBase = URL(string: "https://rdap.org/domain/")!
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public init(transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport
        self.now = now
    }

    public func lookup(_ domain: String) async throws -> DomainReading {
        let url = Self.bootstrapBase.appending(path: domain)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/rdap+json, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw RDAPError.http(response.statusCode) }
        let parsed = try RDAPDomain.parse(data)
        return DomainReading(name: domain, expiresAt: parsed.expiration, registeredAt: parsed.registration,
                             registrar: parsed.registrar, rdapUpdatedAt: parsed.databaseUpdated,
                             sourceURL: (response.url ?? url).absoluteString, fetchedAt: now())
    }
}

// MARK: - Caching headers

/// A parsed `Cache-Control` header.
public struct CacheControl: Equatable, Sendable {
    public let directives: [String: String]

    public static func parse(_ header: String) -> CacheControl {
        var d: [String: String] = [:]
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = pieces.first?.lowercased(), !name.isEmpty else { continue }
            d[name] = pieces.count > 1 ? pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : ""
        }
        return CacheControl(directives: d)
    }

    public var maxAge: Int? { directives["max-age"].flatMap { Int($0) } }
    public var sharedMaxAge: Int? { directives["s-maxage"].flatMap { Int($0) } }
}

/// The caching headers of a page (linumic.com home), shown for information only.
public struct CacheCheck: Codable, Sendable, Equatable {
    public static let oneDay = 86_400

    public let url: String
    public let cacheControl: String?
    /// Cloudflare's `cf-cache-status` (HIT, MISS, DYNAMIC, ...).
    public let cdnStatus: String?
    /// `age`: seconds the copy has been in the cache.
    public let age: Int?
    public let checkedAt: Date

    public init(url: String, headers: [String: String], checkedAt: Date) {
        let h = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.url = url
        cacheControl = h["cache-control"]
        cdnStatus = h["cf-cache-status"]
        age = h["age"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        self.checkedAt = checkedAt
    }

    public var maxAge: Int? { cacheControl.map(CacheControl.parse)?.maxAge }
    public var sharedMaxAge: Int? { cacheControl.map(CacheControl.parse)?.sharedMaxAge }

    /// True when a browser or the CDN may keep the page for more than a day (an edit may take that long to show).
    public var isLongerThanADay: Bool { max(maxAge ?? 0, sharedMaxAge ?? 0) > Self.oneDay }
}
