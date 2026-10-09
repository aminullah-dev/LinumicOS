import Foundation

// Cloud Firestore over its REST API (no Firebase SDK), read-only: list a collection, run a structured query with a
// field mask, count with an aggregation query, and batch-get documents with a mask. Used for the Talar organisation
// list and the SafeBeauty queues, exactly where those products' own admin consoles read Firestore directly.
//
// Every request carries the signed-in admin's Firebase ID token, so the product's own security rules decide what
// is returned. The field mask keeps fields the app doesn't show (for example SafeBeauty's identity-document fields)
// from ever being downloaded.

/// Where a project's Firestore REST API lives.
public struct FirestoreEndpoint: Sendable, Equatable {
    /// `…/v1/projects/{project}/databases/(default)/documents`
    public var documents: URL

    public init(documents: URL) { self.documents = documents }

    public static func google(project: String) -> FirestoreEndpoint {
        FirestoreEndpoint(documents: URL(string: "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents")!)
    }

    public static func emulator(host: String, port: Int, project: String) -> FirestoreEndpoint {
        FirestoreEndpoint(documents: URL(string: "http://\(host):\(port)/v1/projects/\(project)/databases/(default)/documents")!)
    }

    /// `projects/{project}/databases/(default)/documents`, the prefix document names carry.
    var resourcePrefix: String {
        let path = documents.path
        return path.hasPrefix("/v1/") ? String(path.dropFirst(4)) : path
    }
}

/// One Firestore value, decoded from the REST API's typed form (`{"stringValue": "…"}` and so on).
public indirect enum FirestoreValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case timestamp(Date)
    case string(String)
    case reference(String)
    case array([FirestoreValue])
    case map([String: FirestoreValue])
    /// bytes, geoPoint and anything newer: present, not shown.
    case other

    private enum Keys: String, CodingKey {
        case nullValue, booleanValue, integerValue, doubleValue, timestampValue, stringValue, referenceValue, arrayValue, mapValue
    }
    private struct ArrayBox: Decodable { let values: [FirestoreValue]? }
    private struct MapBox: Decodable { let fields: [String: FirestoreValue]? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.nullValue) { self = .null }
        else if let b = try c.decodeIfPresent(Bool.self, forKey: .booleanValue) { self = .bool(b) }
        else if let s = try c.decodeIfPresent(String.self, forKey: .integerValue) { self = .integer(Int64(s) ?? 0) }
        else if let d = try? c.decodeIfPresent(Double.self, forKey: .doubleValue) { self = .double(d) }
        else if let t = try c.decodeIfPresent(String.self, forKey: .timestampValue) { self = FirestoreValue.parseTimestamp(t).map(FirestoreValue.timestamp) ?? .string(t) }
        else if let s = try c.decodeIfPresent(String.self, forKey: .stringValue) { self = .string(s) }
        else if let r = try c.decodeIfPresent(String.self, forKey: .referenceValue) { self = .reference(r) }
        else if let a = try c.decodeIfPresent(ArrayBox.self, forKey: .arrayValue) { self = .array(a.values ?? []) }
        else if let m = try c.decodeIfPresent(MapBox.self, forKey: .mapValue) { self = .map(m.fields ?? [:]) }
        else { self = .other }
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    /// Integers and doubles alike (Firestore stores JavaScript numbers as either).
    public var number: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    /// A timestamp, or a JavaScript `Date.now()` number of milliseconds (SafeBeauty stores both).
    public var date: Date? {
        switch self {
        case .timestamp(let d): d
        case .integer(let ms): Date(timeIntervalSince1970: Double(ms) / 1000)
        case .double(let ms): Date(timeIntervalSince1970: ms / 1000)
        default: nil
        }
    }
}

/// A document as the REST API returns it.
public struct FirestoreDocument: Decodable, Equatable, Sendable {
    /// Full resource name, `projects/…/documents/{collection}/{id}`.
    public let name: String
    public let fields: [String: FirestoreValue]

    public init(name: String, fields: [String: FirestoreValue]) {
        self.name = name
        self.fields = fields
    }

    private enum Keys: String, CodingKey { case name, fields }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        fields = try c.decodeIfPresent([String: FirestoreValue].self, forKey: .fields) ?? [:]
    }

    /// The last path segment.
    public var id: String { String(name.split(separator: "/").last ?? "") }

    public subscript(_ field: String) -> FirestoreValue? { fields[field] }
}

/// A filter for `runQuery` / `runAggregationQuery`: one field, one operator, one value.
public struct FirestoreFilter: Sendable, Equatable {
    public enum Op: String, Sendable { case equal = "EQUAL", greaterThan = "GREATER_THAN", greaterThanOrEqual = "GREATER_THAN_OR_EQUAL", lessThan = "LESS_THAN", lessThanOrEqual = "LESS_THAN_OR_EQUAL" }
    public enum Value: Sendable, Equatable {
        case string(String), bool(Bool), integer(Int64)
    }
    public let field: String
    public let op: Op
    public let value: Value

    public init(_ field: String, _ op: Op, _ value: Value) {
        self.field = field
        self.op = op
        self.value = value
    }

    var json: [String: Any] {
        let v: [String: Any] = switch value {
        case .string(let s): ["stringValue": s]
        case .bool(let b): ["booleanValue": b]
        case .integer(let i): ["integerValue": String(i)]
        }
        return ["fieldFilter": ["field": ["fieldPath": field], "op": op.rawValue, "value": v]]
    }
}

public enum FirestoreError: Error, LocalizedError, Equatable {
    /// 401: the ID token was refused.
    case unauthenticated
    /// 403 PERMISSION_DENIED: the security rules said no (not an admin, or the uid bridge is missing).
    case permissionDenied(String)
    /// 400 FAILED_PRECONDITION, usually a composite index the query needs.
    case failedPrecondition(String)
    case server(status: Int, message: String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: L("Firestore refused the session (401). Sign in again.")
        case .permissionDenied(let m): LF("Firestore's security rules refused this read (403): %@", m)
        case .failedPrecondition(let m): LF("Firestore can't run this query: %@", m)
        case .server(let status, let m): LF("Firestore returned HTTP %1$ld: %2$@", status, m)
        case .network(let m): LF("Couldn't reach Firestore: %@", m)
        case .decoding(let m): LF("Firestore answered in a form this app doesn't understand: %@", m)
        }
    }

    static func from(status: Int, data: Data) -> FirestoreError {
        struct Envelope: Decodable { struct Inner: Decodable { let message: String?; let status: String? }; let error: Inner? }
        // runQuery reports errors as a one-element array.
        let single = try? JSONDecoder().decode(Envelope.self, from: data)
        let list = try? JSONDecoder().decode([Envelope].self, from: data)
        let message = single?.error?.message ?? list?.first?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch status {
        case 401: return .unauthenticated
        case 403: return .permissionDenied(message)
        case 400 where message.localizedCaseInsensitiveContains("index"): return .failedPrecondition(message)
        default: return .server(status: status, message: message)
        }
    }
}

/// Stateless read-only Firestore REST calls. The caller supplies a fresh ID token per call.
public struct FirestoreREST: Sendable {
    public let endpoint: FirestoreEndpoint
    private let transport: HTTPTransport

    public init(endpoint: FirestoreEndpoint, transport: HTTPTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) } catch let e as URLError {
            throw FirestoreError.network(e.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else { throw FirestoreError.from(status: response.statusCode, data: data) }
        return data
    }

    private func request(_ url: URL, token: String, body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 60
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return r
    }

    /// `GET {collection}?pageSize=&mask.fieldPaths=…`. One page (up to `pageSize`, at most 300).
    public func list(_ collection: String, mask: [String], pageSize: Int = 100, token: String) async throws -> [FirestoreDocument] {
        var c = URLComponents(url: endpoint.documents.appending(path: collection), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "pageSize", value: String(min(max(pageSize, 1), 300)))] + mask.map { URLQueryItem(name: "mask.fieldPaths", value: $0) }
        struct Page: Decodable { let documents: [FirestoreDocument]? }
        let data = try await send(request(c.url!, token: token))
        do { return try JSONDecoder().decode(Page.self, from: data).documents ?? [] } catch {
            throw FirestoreError.decoding(String(describing: error).prefix(300).description)
        }
    }

    /// `POST :runQuery` on one collection, AND of `filters`, only the `select` fields returned.
    public func query(_ collection: String, filters: [FirestoreFilter], select: [String], limit: Int, token: String) async throws -> [FirestoreDocument] {
        var structured: [String: Any] = [
            "from": [["collectionId": collection]],
            "select": ["fields": select.map { ["fieldPath": $0] }],
            "limit": limit,
        ]
        if let w = Self.where(filters) { structured["where"] = w }
        let data = try await send(request(URL(string: endpoint.documents.absoluteString + ":runQuery")!, token: token,
                                          body: ["structuredQuery": structured]))
        struct Row: Decodable { let document: FirestoreDocument? }
        do { return try JSONDecoder().decode([Row].self, from: data).compactMap(\.document) } catch {
            throw FirestoreError.decoding(String(describing: error).prefix(300).description)
        }
    }

    /// `POST :runAggregationQuery` with `count()`: how many documents match, without reading them.
    public func count(_ collection: String, filters: [FirestoreFilter], token: String) async throws -> Int {
        var structured: [String: Any] = ["from": [["collectionId": collection]]]
        if let w = Self.where(filters) { structured["where"] = w }
        let body: [String: Any] = ["structuredAggregationQuery": ["structuredQuery": structured, "aggregations": [["alias": "n", "count": [:] as [String: Any]]]]]
        let data = try await send(request(URL(string: endpoint.documents.absoluteString + ":runAggregationQuery")!, token: token, body: body))
        struct Row: Decodable { struct Result: Decodable { let aggregateFields: [String: FirestoreValue]? }; let result: Result? }
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) } catch {
            throw FirestoreError.decoding(String(describing: error).prefix(300).description)
        }
        guard let value = rows.compactMap({ $0.result?.aggregateFields?["n"] }).first, let n = value.number else {
            throw FirestoreError.decoding("no count in the aggregation result")
        }
        return Int(n)
    }

    /// `GET {collection}/{id}?mask.fieldPaths=…`. nil when the document doesn't exist.
    public func get(_ collection: String, _ id: String, mask: [String], token: String) async throws -> FirestoreDocument? {
        var c = URLComponents(url: endpoint.documents.appending(path: collection).appending(path: id), resolvingAgainstBaseURL: false)!
        c.queryItems = mask.map { URLQueryItem(name: "mask.fieldPaths", value: $0) }
        do {
            let data = try await send(request(c.url!, token: token))
            return try JSONDecoder().decode(FirestoreDocument.self, from: data)
        } catch FirestoreError.server(status: 404, _) { return nil }
        catch let e as DecodingError { throw FirestoreError.decoding(String(describing: e).prefix(300).description) }
    }

    /// `POST :batchGet` with a mask. Missing documents are left out.
    public func batchGet(_ collection: String, ids: [String], mask: [String], token: String) async throws -> [FirestoreDocument] {
        guard !ids.isEmpty else { return [] }
        let names = ids.map { "\(endpoint.resourcePrefix)/\(collection)/\($0)" }
        let data = try await send(request(URL(string: endpoint.documents.absoluteString + ":batchGet")!, token: token,
                                          body: ["documents": names, "mask": ["fieldPaths": mask]]))
        struct Row: Decodable { let found: FirestoreDocument? }
        do { return try JSONDecoder().decode([Row].self, from: data).compactMap(\.found) } catch {
            throw FirestoreError.decoding(String(describing: error).prefix(300).description)
        }
    }

    static func `where`(_ filters: [FirestoreFilter]) -> [String: Any]? {
        switch filters.count {
        case 0: nil
        case 1: filters[0].json
        default: ["compositeFilter": ["op": "AND", "filters": filters.map(\.json)]]
        }
    }
}

// MARK: - JWT claims

/// Reads the payload of a JWT (a Firebase ID token) without verifying it. Only for showing and pre-checking what
/// the server will check itself (Talar's `role` claim); never a security decision on its own.
public enum JWTClaims {
    public static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
