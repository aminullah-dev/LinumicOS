import CryptoKit
import Foundation
import Security
import Testing
@testable import LinumicCore

// TEST FIXTURES only: freshly generated keys and stubbed console responses, never real data.

private final class Stub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> (Int, String)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func base64URLDecode(_ s: Substring) -> Data {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)!
}

private func claims(_ jwt: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: base64URLDecode(jwt.split(separator: ".")[1])) as! [String: Any]
}

// MARK: DER helpers to build a PKCS#8 key like the one in Google's JSON file.

private func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
    let n = body.count
    let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
    return [tag] + length + body
}

private func rsaFixture() throws -> (pem: String, publicKey: SecKey) {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    var error: Unmanaged<CFError>?
    let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &error))
    let pkcs1 = [UInt8](try #require(SecKeyCopyExternalRepresentation(key, &error)) as Data)
    let rsaOID: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    let pkcs8 = der(0x30, der(0x02, [0]) + der(0x30, rsaOID + [0x05, 0x00]) + der(0x04, pkcs1))
    let pem = "-----BEGIN PRIVATE KEY-----\n" + Data(pkcs8).base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r", with: "") + "\n-----END PRIVATE KEY-----\n"
    return (pem, try #require(SecKeyCopyPublicKey(key)))
}

@Suite("App Store Connect (read-only)")
struct AppStoreConnectTests {
    let key = P256.Signing.PrivateKey()
    var credentials: AppStoreConnectCredentials { AppStoreConnectCredentials(issuerID: "issuer-1", keyID: "KEY123", privateKeyPEM: key.pemRepresentation) }

    @Test func tokenIsAValidES256JWT() throws {
        let jwt = try AppStoreConnectClient(credentials: credentials, now: { now }).token()
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: base64URLDecode(parts[0])) as! [String: String]
        #expect(header == ["alg": "ES256", "kid": "KEY123", "typ": "JWT"])
        let c = try claims(jwt)
        #expect(c["iss"] as? String == "issuer-1" && c["aud"] as? String == "appstoreconnect-v1")
        #expect((c["exp"] as! Int) - (c["iat"] as! Int) <= 1200, "Apple rejects tokens valid for more than 20 minutes")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func rejectsANonKeyFile() {
        #expect(throws: StoreConsoleError.self) { try AppStoreConnectCredentials(issuerID: "i", keyID: "k", privateKeyPEM: "not a key").validate() }
    }

    @Test func readsVersionsWithGETsOnly() async throws {
        let stub = Stub { req in
            if req.url!.path == "/v1/apps" { return (200, #"{"data":[{"id":"123","attributes":{"bundleId":"sample.app"}}]}"#) }
            return (200, #"{"data":[{"id":"v1","attributes":{"versionString":"1.0.1","platform":"IOS","appVersionState":"WAITING_FOR_REVIEW","createdDate":"2026-09-20T10:00:00.000-07:00"}}]}"#)
        }
        let client = AppStoreConnectClient(credentials: credentials, transport: stub, now: { now })
        let id = try await client.appID(bundleID: "sample.app")
        #expect(id == "123")
        let versions = try await client.versions(appID: "123")
        #expect(versions == [AppStoreConnectVersion(versionString: "1.0.1", platform: "IOS", state: "WAITING_FOR_REVIEW", createdDate: versions.first?.createdDate)])
        #expect(versions.first?.createdDate != nil)
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(stub.requests.first?.url?.query?.contains("filter%5BbundleId%5D=sample.app") == true || stub.requests.first?.url?.query?.contains("filter[bundleId]=sample.app") == true)
    }

    @Test func unauthorizedIsExplained() async {
        let client = AppStoreConnectClient(credentials: credentials, transport: Stub { _ in (401, "{}") }, now: { now })
        await #expect(throws: StoreConsoleError.unauthorized("App Store Connect")) { try await client.appID(bundleID: "x") }
    }

    @Test func applySplitsLiveAndPendingPerPlatform() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let versions = [
            AppStoreConnectVersion(versionString: "1.0", platform: "IOS", state: "READY_FOR_DISTRIBUTION", createdDate: d(1)),
            AppStoreConnectVersion(versionString: "1.0.1", platform: "IOS", state: "WAITING_FOR_REVIEW", createdDate: d(3)),
            AppStoreConnectVersion(versionString: "0.9", platform: "IOS", state: "REPLACED_WITH_NEW_VERSION", createdDate: d(0)),
            AppStoreConnectVersion(versionString: "1.0", platform: "MAC_OS", state: "IN_REVIEW", createdDate: d(2)),
        ]
        let old = Source(kind: .appStore, reference: "App Store Connect API /v1/apps/9/appStoreVersions", observedAt: d(0))
        let owner = Source(kind: .ownerStatement, reference: "screenshot", observedAt: d(0))
        let listing = StoreListing(store: .appStore, appIdentifier: "sample.app", verification: Verification(status: .partiallyVerified, sources: [owner, old], verifiedAt: d(0)))
        let l = StoreConsoleSync.apply(versions, appID: "9", to: listing, at: now)
        #expect(l.productionVersion == "iOS 1.0")
        #expect(l.latestSubmittedVersion == "iOS 1.0.1, macOS 1.0")
        #expect(l.reviewStatus == "iOS 1.0.1: Waiting for review; macOS 1.0: In review")
        #expect(l.verification.status == .verified && l.verification.verifiedAt == now)
        #expect(l.verification.sources.contains(owner), "other evidence is kept")
        #expect(l.verification.sources.filter { $0.reference.hasPrefix("App Store Connect API") }.count == 1, "the previous API source is replaced")
        #expect(l.verification.issues.isEmpty)
    }
}

@Suite("Google Play (read-only)")
struct GooglePlayTests {
    @Test func parsesServiceAccountJSONAndRejectsOthers() throws {
        let (pem, _) = try rsaFixture()
        let json = try JSONSerialization.data(withJSONObject: ["type": "service_account", "client_email": "sa@sample.iam.gserviceaccount.com", "private_key": pem, "token_uri": "https://oauth2.googleapis.com/token"])
        let c = try GooglePlayCredentials(serviceAccountJSON: json)
        #expect(c.clientEmail == "sa@sample.iam.gserviceaccount.com")
        #expect(throws: StoreConsoleError.self) { try GooglePlayCredentials(serviceAccountJSON: Data(#"{"type":"authorized_user"}"#.utf8)) }
    }

    @Test func assertionIsSignedWithRS256() throws {
        let (pem, publicKey) = try rsaFixture()
        let client = GooglePlayClient(credentials: GooglePlayCredentials(clientEmail: "sa@sample", privateKeyPEM: pem), now: { now })
        let jwt = try client.assertion(at: now)
        let parts = jwt.split(separator: ".")
        let c = try claims(jwt)
        #expect(c["scope"] as? String == "https://www.googleapis.com/auth/androidpublisher")
        #expect(c["aud"] as? String == "https://oauth2.googleapis.com/token")
        var error: Unmanaged<CFError>?
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, base64URLDecode(parts[2]) as CFData, &error))
    }

    @Test func readsTracksWithoutAnEdit() async throws {
        let (pem, _) = try rsaFixture()
        let stub = Stub { req in
            if req.url!.host() == "oauth2.googleapis.com" { return (200, #"{"access_token":"ya29.sample","expires_in":3600}"#) }
            if req.url!.path.hasSuffix("/tracks/production/releases") {
                return (200, #"{"releases":[{"releaseName":"2.1.5","track":"production","activeArtifacts":[{"versionCode":22}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_PUBLISHED"}]}"#)
            }
            if req.url!.path.hasSuffix("/tracks/alpha/releases") {
                return (200, #"{"releases":[{"releaseName":"2.1.6","activeArtifacts":[{"versionCode":23}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_IN_REVIEW"}]}"#)
            }
            if req.url!.path.hasSuffix("/tracks/beta/releases") { return (200, "") }  // empty body, as the live API sends
            return (404, "{}")
        }
        let client = GooglePlayClient(credentials: GooglePlayCredentials(clientEmail: "sa@sample", privateKeyPEM: pem), transport: stub, now: { now })
        let releases = try await client.allReleases(packageName: "sample.app")
        #expect(releases.map(\.label) == ["2.1.5 (22)", "2.1.6 (23)"])
        #expect(releases.last?.track == "alpha", "the track comes from the request when the API omits it")
        #expect(stub.requests.filter { $0.url!.host() == "oauth2.googleapis.com" }.count == 1, "the access token is reused")
        #expect(!stub.requests.contains { $0.url!.path.contains("/edits") }, "no edit is ever created")
        #expect(stub.requests.filter { $0.url!.host() != "oauth2.googleapis.com" }.allSatisfy { $0.httpMethod == "GET" })

        let listing = StoreConsoleSync.apply(releases, packageName: "sample.app", to: StoreListing(store: .googlePlay, appIdentifier: "sample.app"), at: now)
        #expect(listing.productionVersion == "2.1.5")
        #expect(listing.reviewStatus == "Live: production 2.1.5 (22); alpha 2.1.6 (23): In review")
        #expect(listing.reviewPhase == .live)
        #expect(listing.verification.status == .verified && listing.verification.issues.isEmpty)
    }

    @Test func versionCodesMayBeStrings() throws {
        // Google encodes int64 as a JSON string; this is what the live API returned.
        let json = #"{"releaseName":"2.1.5","track":"production","activeArtifacts":[{"versionCode":"22"}],"releaseLifecycleState":"RELEASE_LIFECYCLE_STATE_PUBLISHED"}"#
        let r = try JSONDecoder().decode(PlayRelease.self, from: Data(json.utf8))
        #expect(r.versionCodes == [22] && r.label == "2.1.5 (22)")
    }

    @Test func playReleaseNamesAndHeadline() {
        // Shapes returned by the live API on 2026-09-23.
        let r = PlayRelease(releaseName: "4 (1.1.0)", track: "production", versionCodes: [4], state: "RELEASE_LIFECYCLE_STATE_IN_REVIEW")
        #expect(r.versionName == "1.1.0" && r.label == "1.1.0 (4)")
        #expect(PlayRelease(releaseName: "Closed Test v1", track: "alpha", versionCodes: [3], state: "").label == "Closed Test v1 (3)")
        #expect(PlayRelease(releaseName: "6", track: "alpha", versionCodes: [6], state: "").label == "6")
        #expect(PlayRelease(releaseName: "1.2.3 (6)", track: "alpha", versionCodes: [6], state: "").label == "1.2.3 (6)")

        let live = PlayRelease(releaseName: "10 (1.0.10)", track: "production", versionCodes: [10], state: "RELEASE_LIFECYCLE_STATE_PUBLISHED")
        let draft = PlayRelease(releaseName: nil, track: "alpha", versionCodes: [], state: "RELEASE_LIFECYCLE_STATE_DRAFT")
        let l = StoreConsoleSync.apply([live, draft], packageName: "p", to: StoreListing(store: .googlePlay), at: now)
        #expect(l.productionVersion == "1.0.10")
        #expect(l.reviewStatus == "Live: production 1.0.10 (10)", "a draft on a testing track doesn't hide a live release")
        #expect(l.reviewPhase == .live)

        let review = StoreConsoleSync.apply([r, PlayRelease(releaseName: "1 (1.0)", track: "alpha", versionCodes: [2], state: "RELEASE_LIFECYCLE_STATE_PUBLISHED")], packageName: "p", to: StoreListing(store: .googlePlay), at: now)
        #expect(review.reviewPhase == .pending)
        #expect(review.latestSubmittedVersion == "1.1.0 (4)")
        #expect(review.productionVersion == nil)
    }

    @Test func failuresAreGroupedByError() {
        var r = StoreConsoleSync.Report()
        r.failed = ["b.app": "403", "a.app": "403", "c.app": "500"]
        #expect(r.failureSummary == "403 — a.app, b.app\n500 — c.app")
    }

    @Test func humanizesStates() {
        #expect(humanizeState("RELEASE_LIFECYCLE_STATE_APPROVED_NOT_PUBLISHED") == "Approved not published")
        #expect(humanizeState("READY_FOR_DISTRIBUTION") == "Ready for distribution")
    }
}

@Suite("Review phase")
struct ReviewPhaseTests {
    @Test func liveProductionWinsOverTestingTrackNoise() {
        // Stored text from 2026-09-23 for SafeBeauty on Google Play: production 2.1.5 is live, and an
        // empty draft sits on the beta track. That listing is Live, not "Not submitted".
        let safeBeauty = StoreListing(store: .googlePlay, productionVersion: "2.1.5",
                                      reviewStatus: "beta —: Draft; alpha 14 (1.9) (14): Published; internal 3 (1.0) (3): Published")
        #expect(safeBeauty.reviewPhase == .live)
        // A version actually waiting keeps its phase even when an older one is live (VELRO Ride on the App Store).
        let velro = StoreListing(store: .appStore, productionVersion: "1.0.0", latestSubmittedVersion: "1.0.1", reviewStatus: "1.0.1: Prepare for submission")
        #expect(velro.reviewPhase == .notSubmitted)
        // Rejections and reviews always show.
        let rejected = StoreListing(store: .googlePlay, productionVersion: "1.0", reviewStatus: "production 1.1 (5): Not approved; Live: production 1.0 (4)")
        #expect(rejected.reviewPhase == .rejected)
        // Testing-only apps stay Testing (VELRO on Google Play).
        #expect(StoreListing(store: .googlePlay, reviewStatus: "alpha 1.2.3 (6): Published").reviewPhase == .testing)
    }

    @Test func classifiesSeedAndConsoleTexts() {
        let cases: [(String?, ReviewPhase)] = [
            ("Green check in App Store Connect (live)", .live),
            ("Pending: yellow clock in App Store Connect (the screenshot doesn't say which state)", .pending),
            ("Available on Google Play (production)", .live),
            ("In review (production)", .pending),
            ("Closed testing only (no production release)", .testing),
            ("Live, nothing pending", .live),
            ("iOS 1.0.1: Waiting for review; macOS 1.0: In review", .pending),
            ("alpha 1.2.3 (6): Published", .testing),
            ("1.0.1: Prepare for submission", .notSubmitted),
            ("iOS 1.0: Prepare for submission; macOS 1.0: Prepare for submission", .notSubmitted),
            ("production 2.1.6 (23): Draft", .notSubmitted),
            ("production 2.1.6 (23): Not approved", .rejected),
            ("", .unknown), (nil, .unknown), ("Something else", .unknown),
        ]
        for (text, expected) in cases { #expect(ReviewPhase(reviewStatus: text) == expected, "\(text ?? "nil")") }
    }
}
