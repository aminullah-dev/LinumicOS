import CryptoKit
import Foundation
import Security

// Read-only clients for the two store consoles. Both use only GET requests (plus Google's token
// exchange), never create an "edit", and never change a listing, a release or a review.
//
// - App Store Connect API: a team key with the Developer role (Issuer ID, Key ID, .p8 file).
// - Google Play Developer API: a service account with "View app information (read-only)",
//   read through applications.tracks.releases.list, which doesn't need an edit.
// Credentials live only in the Keychain.

public enum StoreConsoleError: Error, LocalizedError, Equatable {
    case invalidKey(String)
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case http(Int, String)
    /// The service answered, but not in the shape expected. Carries where decoding failed.
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let why): LF("The key can't be used: %@", why)
        case .unauthorized(let service): LF("%@ rejected the credentials (401). Check them in Settings → Integrations.", service)
        case .forbidden(let service): LF("%@ refused access (403). The account lacks read permission for this app, or a permission granted in the last day hasn't taken effect yet.", service)
        case .notFound(let what): LF("Not found: %@", what)
        case .http(let code, let service): LF("%@ returned HTTP %d.", service, code)
        case .unexpectedResponse(let detail): LF("Unexpected response: %@", detail)
        }
    }

    static func from(status: Int, service: String, path: String) -> StoreConsoleError {
        switch status {
        case 401: .unauthorized(service)
        case 403: .forbidden(service)
        case 404: .notFound(path)
        default: .http(status, service)
        }
    }
}

/// Decodes, and on failure says which field broke and shows the start of the body (responses carry no secrets).
func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder = JSONDecoder(), what: String) throws -> T {
    do { return try decoder.decode(type, from: data) } catch let error as DecodingError {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): context = c
        @unknown default: throw error
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        let body = String(decoding: data.prefix(160), as: UTF8.self)
        throw StoreConsoleError.unexpectedResponse("\(what) [\(path)] \(context.debugDescription) — \(body)")
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private func jwtPart(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64URL()
}

// MARK: - App Store Connect

public struct AppStoreConnectCredentials: Codable, Sendable, Equatable {
    public var issuerID: String
    public var keyID: String
    /// Contents of the AuthKey_XXXX.p8 file (PKCS#8 PEM).
    public var privateKeyPEM: String

    public init(issuerID: String, keyID: String, privateKeyPEM: String) {
        self.issuerID = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.privateKeyPEM = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fails early if the .p8 isn't an ES256 private key.
    public func validate() throws {
        _ = try signingKey()
        if issuerID.isEmpty || keyID.isEmpty { throw StoreConsoleError.invalidKey(L("Issuer ID and Key ID are required.")) }
    }

    func signingKey() throws -> P256.Signing.PrivateKey {
        do { return try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) } catch {
            throw StoreConsoleError.invalidKey(L("The .p8 file isn't an App Store Connect private key."))
        }
    }
}

/// One App Store version as App Store Connect reports it.
public struct AppStoreConnectVersion: Sendable, Equatable, Decodable {
    public var versionString: String
    public var platform: String
    /// `appVersionState` when present, otherwise the older `appStoreState`.
    public var state: String
    public var createdDate: Date?

    public init(versionString: String, platform: String, state: String, createdDate: Date? = nil) {
        self.versionString = versionString
        self.platform = platform
        self.state = state
        self.createdDate = createdDate
    }

    private enum Keys: String, CodingKey { case versionString, platform, appVersionState, appStoreState, createdDate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        versionString = try c.decode(String.self, forKey: .versionString)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "UNKNOWN"
        state = try c.decodeIfPresent(String.self, forKey: .appVersionState) ?? c.decodeIfPresent(String.self, forKey: .appStoreState) ?? "UNKNOWN"
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate)
    }

    /// Live on the App Store.
    public var isLive: Bool { ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(state) }
    /// A superseded or abandoned version, not worth reporting as "submitted".
    var isHistorical: Bool { ["REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"].contains(state) }

    public var platformTitle: String {
        switch platform {
        case "IOS": "iOS"
        case "MAC_OS": "macOS"
        case "TV_OS": "tvOS"
        case "VISION_OS": "visionOS"
        default: platform
        }
    }
}

/// "WAITING_FOR_REVIEW" → "Waiting for review".
public func humanizeState(_ raw: String) -> String {
    let words = raw.replacingOccurrences(of: "RELEASE_LIFECYCLE_STATE_", with: "").split(separator: "_").map { $0.lowercased() }
    guard let first = words.first else { return raw }
    return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
}

public struct AppStoreConnectClient: Sendable {
    public static let service = "App Store Connect"
    private let credentials: AppStoreConnectCredentials
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let base = URL(string: "https://api.appstoreconnect.apple.com")!

    public init(credentials: AppStoreConnectCredentials, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// ES256 JWT valid for 15 minutes (Apple allows at most 20).
    public func token() throws -> String {
        let iat = Int(now().timeIntervalSince1970)
        let header = try jwtPart(["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"])
        let claims = try jwtPart(["iss": credentials.issuerID, "iat": iat, "exp": iat + 900, "aud": "appstoreconnect-v1"])
        let input = "\(header).\(claims)"
        let signature = try credentials.signingKey().signature(for: Data(input.utf8))
        return "\(input).\(signature.rawRepresentation.base64URL())"
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        var request = URLRequest(url: c.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw StoreConsoleError.from(status: response.statusCode, service: Self.service, path: path) }
        return data
    }

    private struct Page<Attributes: Decodable>: Decodable {
        struct Item: Decodable { let id: String; let attributes: Attributes }
        let data: [Item]
    }

    /// The App Store Connect app ID for a bundle ID, or nil if the account has no such app.
    public func appID(bundleID: String) async throws -> String? {
        struct A: Decodable { let bundleId: String }
        let data = try await get("v1/apps", query: [URLQueryItem(name: "filter[bundleId]", value: bundleID), URLQueryItem(name: "fields[apps]", value: "bundleId")])
        return try JSONDecoder().decode(Page<A>.self, from: data).data.first { $0.attributes.bundleId == bundleID }?.id
    }

    /// Apple's dates come with or without fractional seconds.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: s) { return date }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(s)"))
        }
        return decoder
    }

    public func versions(appID: String) async throws -> [AppStoreConnectVersion] {
        let data = try await get("v1/apps/\(appID)/appStoreVersions", query: [
            URLQueryItem(name: "fields[appStoreVersions]", value: "versionString,platform,appVersionState,appStoreState,createdDate"),
            URLQueryItem(name: "limit", value: "20"),
        ])
        return try decodeResponse(Page<AppStoreConnectVersion>.self, from: data, decoder: Self.decoder, what: "appStoreVersions").data.map(\.attributes)
    }

    /// Newest customer reviews (read-only; the Developer role may read them).
    public func customerReviews(appID: String, limit: Int = 10) async throws -> [CustomerReview] {
        struct A: Decodable { let rating: Int; let title: String?; let body: String?; let reviewerNickname: String?; let createdDate: Date?; let territory: String? }
        let data = try await get("v1/apps/\(appID)/customerReviews", query: [
            URLQueryItem(name: "sort", value: "-createdDate"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields[customerReviews]", value: "rating,title,body,reviewerNickname,createdDate,territory"),
        ])
        return try decodeResponse(Page<A>.self, from: data, decoder: Self.decoder, what: "customerReviews").data.map {
            CustomerReview(id: $0.id, rating: $0.attributes.rating, title: $0.attributes.title, body: $0.attributes.body,
                           reviewer: $0.attributes.reviewerNickname, territory: $0.attributes.territory, createdAt: $0.attributes.createdDate)
        }
    }

    /// Newest TestFlight builds with their marketing version and platform.
    public func testBuilds(appID: String, limit: Int = 5) async throws -> [TestBuild] {
        struct Ref: Decodable { let id: String }
        struct Rel: Decodable { struct D: Decodable { let data: Ref? }; let preReleaseVersion: D? }
        struct B: Decodable {
            struct A: Decodable { let version: String; let uploadedDate: Date?; let expirationDate: Date?; let expired: Bool?; let processingState: String? }
            let id: String; let attributes: A; let relationships: Rel?
        }
        struct Inc: Decodable { struct A: Decodable { let version: String?; let platform: String? }; let id: String; let type: String; let attributes: A? }
        struct R: Decodable { let data: [B]; let included: [Inc]? }
        let data = try await get("v1/builds", query: [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate,expirationDate,expired,processingState,preReleaseVersion"),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
            URLQueryItem(name: "fields[preReleaseVersions]", value: "version,platform"),
        ])
        let r = try decodeResponse(R.self, from: data, decoder: Self.decoder, what: "builds")
        let versions = Dictionary((r.included ?? []).filter { $0.type == "preReleaseVersions" }.map { ($0.id, $0.attributes) }, uniquingKeysWith: { a, _ in a })
        return r.data.map { b in
            let pre = b.relationships?.preReleaseVersion?.data.flatMap { versions[$0.id] } ?? nil
            return TestBuild(id: b.id, build: b.attributes.version, version: pre?.version, platform: pre?.platform,
                             processingState: b.attributes.processingState, expired: b.attributes.expired ?? false,
                             uploadedAt: b.attributes.uploadedDate, expiresAt: b.attributes.expirationDate)
        }
    }
}

// MARK: - Google Play

public struct GooglePlayCredentials: Codable, Sendable, Equatable {
    public var clientEmail: String
    /// PKCS#8 PEM from the service-account JSON key.
    public var privateKeyPEM: String
    public var tokenURI: URL

    private enum CodingKeys: String, CodingKey {
        case clientEmail = "client_email", privateKeyPEM = "private_key", tokenURI = "token_uri"
    }

    public init(clientEmail: String, privateKeyPEM: String, tokenURI: URL = URL(string: "https://oauth2.googleapis.com/token")!) {
        self.clientEmail = clientEmail
        self.privateKeyPEM = privateKeyPEM
        self.tokenURI = tokenURI
    }

    /// Parses the JSON key file Google Cloud downloads for a service account.
    public init(serviceAccountJSON: Data) throws {
        struct File: Decodable { let type: String?; let client_email: String?; let private_key: String?; let token_uri: String? }
        guard let f = try? JSONDecoder().decode(File.self, from: serviceAccountJSON), f.type == "service_account",
              let email = f.client_email, let key = f.private_key else {
            throw StoreConsoleError.invalidKey(L("This isn't a Google service-account JSON key."))
        }
        self.init(clientEmail: email, privateKeyPEM: key, tokenURI: f.token_uri.flatMap(URL.init(string:)) ?? URL(string: "https://oauth2.googleapis.com/token")!)
        _ = try signingKey()
    }

    func signingKey() throws -> SecKey {
        try RSAKey.privateKey(pem: privateKeyPEM)
    }
}

/// Minimal RSA key loading for RS256. Security.framework wants PKCS#1; Google ships PKCS#8.
enum RSAKey {
    static func privateKey(pem: String) throws -> SecKey {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw StoreConsoleError.invalidKey(L("The private key isn't valid PEM.")) }
        let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try unwrapPKCS8(der)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw StoreConsoleError.invalidKey(L("The private key isn't an RSA key."))
        }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var r = DERReader(Array(der))
        let outer = try r.read(tag: 0x30)
        var inner = DERReader(outer)
        _ = try inner.read(tag: 0x02)
        _ = try inner.read(tag: 0x30)
        return Data(try inner.read(tag: 0x04))
    }

    static func sign(_ message: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
            throw StoreConsoleError.invalidKey(L("Signing with the private key failed."))
        }
        return sig as Data
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var i = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        let bad = StoreConsoleError.invalidKey(L("The private key isn't valid PKCS#8."))
        guard i < bytes.count, bytes[i] == tag, i + 1 < bytes.count else { throw bad }
        i += 1
        var length = Int(bytes[i]); i += 1
        if length & 0x80 != 0 {
            let n = length & 0x7f
            guard n <= 4, i + n <= bytes.count else { throw bad }
            length = bytes[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        guard i + length <= bytes.count else { throw bad }
        defer { i += length }
        return Array(bytes[i..<i + length])
    }
}

/// One release on a Play track, as applications.tracks.releases.list returns it.
public struct PlayRelease: Sendable, Equatable, Decodable {
    public var releaseName: String?
    public var track: String
    public var versionCodes: [Int]
    public var state: String

    public init(releaseName: String?, track: String, versionCodes: [Int], state: String) {
        self.releaseName = releaseName
        self.track = track
        self.versionCodes = versionCodes
        self.state = state
    }

    private enum Keys: String, CodingKey { case releaseName, track, activeArtifacts, releaseLifecycleState }
    /// Google's JSON encodes int64 fields as strings ("22"), so accept either form.
    private struct Artifact: Decodable {
        let versionCode: Int?
        private enum Keys: String, CodingKey { case versionCode }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if let n = try? c.decodeIfPresent(Int.self, forKey: .versionCode) { versionCode = n }
            else { versionCode = (try c.decodeIfPresent(String.self, forKey: .versionCode)).flatMap { Int($0) } }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        releaseName = try c.decodeIfPresent(String.self, forKey: .releaseName)
        track = try c.decodeIfPresent(String.self, forKey: .track) ?? ""
        versionCodes = (try c.decodeIfPresent([Artifact].self, forKey: .activeArtifacts) ?? []).compactMap(\.versionCode)
        state = try c.decodeIfPresent(String.self, forKey: .releaseLifecycleState) ?? "RELEASE_LIFECYCLE_STATE_UNSPECIFIED"
    }

    public var isPublished: Bool { state == "RELEASE_LIFECYCLE_STATE_PUBLISHED" }

    /// "2.1.5 (22)", or just the codes when the release has no name.
    /// The version name. Play's default release name is "<versionCode> (<versionName>)", so that becomes "<versionName>".
    public var versionName: String? {
        guard let name = releaseName else { return nil }
        if let m = name.wholeMatch(of: /\d+ \((.+)\)/) { return String(m.1) }
        return name
    }

    /// "2.1.5 (22)", or just the codes when the release has no name.
    public var label: String {
        let codes = versionCodes.map(String.init).joined(separator: ", ")
        switch (versionName, codes.isEmpty) {
        case (let n?, false): return n == codes || n.hasSuffix("(\(codes))") ? n : "\(n) (\(codes))"
        case (let n?, true): return n
        case (nil, _): return codes.isEmpty ? "—" : codes
        }
    }
}

public actor GooglePlayClient {
    public static let service = "Google Play"
    /// The standard tracks. Closed testing uses "alpha" unless a custom track was created.
    public static let tracks = ["production", "beta", "alpha", "internal"]
    public static let scope = "https://www.googleapis.com/auth/androidpublisher"

    private let credentials: GooglePlayCredentials
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiresAt: Date)?

    public init(credentials: GooglePlayCredentials, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// The signed JWT assertion exchanged for an access token.
    nonisolated func assertion(at date: Date) throws -> String {
        let iat = Int(date.timeIntervalSince1970)
        let header = try jwtPart(["alg": "RS256", "typ": "JWT"])
        let claims = try jwtPart(["iss": credentials.clientEmail, "scope": Self.scope, "aud": credentials.tokenURI.absoluteString, "iat": iat, "exp": iat + 3600])
        let input = "\(header).\(claims)"
        let signature = try RSAKey.sign(Data(input.utf8), with: credentials.signingKey())
        return "\(input).\(signature.base64URL())"
    }

    func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > 60 { return cached.token }
        var request = URLRequest(url: credentials.tokenURI)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(try assertion(at: now()))"
        request.httpBody = Data(body.utf8)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw StoreConsoleError.from(status: response.statusCode == 400 ? 401 : response.statusCode, service: Self.service, path: "token") }
        struct T: Decodable { let access_token: String; let expires_in: Double? }
        let t = try decodeResponse(T.self, from: data, what: "token")
        cached = (t.access_token, now().addingTimeInterval(t.expires_in ?? 3600))
        return t.access_token
    }

    /// Releases on one track. A track the app doesn't use returns an empty list.
    public func releases(packageName: String, track: String) async throws -> [PlayRelease] {
        let path = "androidpublisher/v3/applications/\(packageName)/tracks/\(track)/releases"
        var request = URLRequest(url: URL(string: "https://androidpublisher.googleapis.com/")!.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 404 { return [] }
        // A track with no releases answers 200 with an empty body, not "{}".
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) && (200..<300).contains(response.statusCode) { return [] }
        guard (200..<300).contains(response.statusCode) else { throw StoreConsoleError.from(status: response.statusCode, service: Self.service, path: path) }
        struct R: Decodable { let releases: [PlayRelease]? }
        return try decodeResponse(R.self, from: data, what: track).releases?.map { var r = $0; if r.track.isEmpty { r.track = track }; return r } ?? []
    }

    public func allReleases(packageName: String) async throws -> [PlayRelease] {
        var result: [PlayRelease] = []
        for track in Self.tracks { result += try await releases(packageName: packageName, track: track) }
        return result
    }
}

// MARK: - Applying console data to listings
// The texts written into listings are data, not UI: they stay in English whatever the app language,
// so `ReviewPhase` can classify them and they read the same on every device.

public enum StoreConsoleSync {
    public struct Report: Sendable, Equatable {
        public var updated: [String] = []
        public var notInAccount: [String] = []
        public var failed: [String: String] = [:]

        /// Failures grouped by error, so six identical 403s read as one line: "error: a, b, c".
        public var failureSummary: String {
            Dictionary(grouping: failed.keys.sorted(), by: { failed[$0]! })
                .sorted { $0.key < $1.key }
                .map { "\($0.key) — \($0.value.joined(separator: ", "))" }
                .joined(separator: "\n")
        }
    }

    static let ascReferencePrefix = "App Store Connect API"
    static let playReferencePrefix = "Google Play Developer API"

    /// Writes an App Store listing from App Store Connect versions.
    /// Live version per platform → `productionVersion`; the newest version that isn't live or superseded → `latestSubmittedVersion` and `reviewStatus`.
    public static func apply(_ versions: [AppStoreConnectVersion], appID: String, to listing: StoreListing, at now: Date) -> StoreListing {
        var l = listing
        let byPlatform = Dictionary(grouping: versions, by: \.platform)
        let multi = byPlatform.count > 1
        func label(_ v: AppStoreConnectVersion) -> String { multi ? "\(v.platformTitle) \(v.versionString)" : v.versionString }
        let newest: ([AppStoreConnectVersion]) -> AppStoreConnectVersion? = { $0.max { ($0.createdDate ?? .distantPast) < ($1.createdDate ?? .distantPast) } }

        let live = byPlatform.keys.sorted().compactMap { newest(byPlatform[$0]!.filter(\.isLive)) }
        let pending = byPlatform.keys.sorted().compactMap { newest(byPlatform[$0]!.filter { !$0.isLive && !$0.isHistorical }) }
        l.productionVersion = live.isEmpty ? nil : live.map(label).joined(separator: ", ")
        l.latestSubmittedVersion = pending.isEmpty ? nil : pending.map(label).joined(separator: ", ")
        l.reviewStatus = pending.isEmpty ? (live.isEmpty ? nil : "Live, nothing pending")
            : pending.map { "\(label($0)): \(humanizeState($0.state))" }.joined(separator: "; ")

        let detail = versions.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }.prefix(6)
            .map { "\($0.platformTitle) \($0.versionString) \($0.state)" }.joined(separator: "; ")
        l.verification.sources.removeAll { $0.reference.hasPrefix(ascReferencePrefix) }
        l.verification.sources.append(Source(kind: .appStore, reference: "\(ascReferencePrefix) /v1/apps/\(appID)/appStoreVersions", observedAt: now, detail: detail))
        l.verification.status = .verified
        l.verification.verifiedAt = now
        return l
    }

    /// Writes a Google Play listing from its releases. The published production release → `productionVersion`;
    /// every other active release is listed with its track and state.
    public static func apply(_ releases: [PlayRelease], packageName: String, to listing: StoreListing, at now: Date) -> StoreListing {
        var l = listing
        let production = releases.first { $0.track == "production" && $0.isPublished }
        l.productionVersion = production.map { $0.versionName ?? $0.label }
        let pendingProduction = releases.filter { $0.track == "production" && !$0.isPublished }
        l.latestSubmittedVersion = pendingProduction.first?.label
        // Headline first (ReviewPhase reads the first clause): a production release under review or not
        // yet sent wins, then the live production release, then testing tracks. Drafts on testing tracks
        // are noise here; they stay in the source detail.
        let describe = { (r: PlayRelease) in "\(r.track) \(r.label): \(humanizeState(r.state))" }
        let testing = releases.filter { $0.track != "production" && $0.state != "RELEASE_LIFECYCLE_STATE_DRAFT" }
        let clauses = pendingProduction.map(describe) + (production.map { ["Live: production \($0.label)"] } ?? []) + testing.map(describe)
        l.reviewStatus = clauses.isEmpty ? nil : clauses.joined(separator: "; ")
        l.verification.sources.removeAll { $0.reference.hasPrefix(playReferencePrefix) }
        l.verification.sources.append(Source(kind: .googlePlay, reference: "\(playReferencePrefix) applications/\(packageName)/tracks/*/releases", observedAt: now,
                                             detail: releases.map { "\($0.track) \($0.label) \($0.state)" }.joined(separator: "; ")))
        l.verification.status = .verified
        l.verification.verifiedAt = now
        return l
    }

    public static func refreshAppStoreConnect(_ products: [Product], using client: AppStoreConnectClient, now: Date = .now) async -> ([Product], Report) {
        var result = products
        var report = Report()
        for (pi, product) in products.enumerated() {
            for (li, listing) in product.storeListings.enumerated() where listing.store == .appStore {
                guard let bundle = listing.appIdentifier else { continue }
                do {
                    guard let id = try await client.appID(bundleID: bundle) else { report.notInAccount.append(bundle); continue }
                    var l = apply(try await client.versions(appID: id), appID: id, to: listing, at: now)
                    // Reviews and test builds are extras: a failure there doesn't undo the version read.
                    var insights = l.insights ?? StoreInsights()
                    if let reviews = try? await client.customerReviews(appID: id) {
                        insights.reviews = reviews
                        insights.reviewsObservedAt = now
                    }
                    if let builds = try? await client.testBuilds(appID: id) {
                        insights.testBuilds = builds
                        insights.testBuildsObservedAt = now
                    }
                    l.insights = insights
                    result[pi].storeListings[li] = l
                    report.updated.append(bundle)
                } catch {
                    report.failed[bundle] = error.localizedDescription
                }
            }
        }
        return (result, report)
    }

    public static func refreshGooglePlay(_ products: [Product], using client: GooglePlayClient, now: Date = .now) async -> ([Product], Report) {
        var result = products
        var report = Report()
        for (pi, product) in products.enumerated() {
            for (li, listing) in product.storeListings.enumerated() where listing.store == .googlePlay {
                guard let package = listing.appIdentifier else { continue }
                do {
                    let releases = try await client.allReleases(packageName: package)
                    if releases.isEmpty { report.notInAccount.append(package); continue }
                    result[pi].storeListings[li] = apply(releases, packageName: package, to: listing, at: now)
                    report.updated.append(package)
                } catch {
                    report.failed[package] = error.localizedDescription
                }
            }
        }
        return (result, report)
    }
}
