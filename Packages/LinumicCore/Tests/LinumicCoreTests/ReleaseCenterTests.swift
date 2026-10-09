import CryptoKit
import Foundation
import Security
import Testing
@testable import LinumicCore

// Fixtures `release-*.json` are real read-only responses captured on 2026-10-09 (App Store Connect GETs, a Play edit
// that was deleted without commit, Play releases.list, GitHub REST through `gh api`), reduced to the fields used.
// No token, key or personal data is in them. Tests marked "synthetic" change a state on purpose to cover a rule.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func day(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

private let readAt = day("2026-10-09T18:00:00Z")

final class ReleaseRecorder: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) throws -> (Int, Data)
    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = try handler(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var methods: [String] { lock.withLock { requests.map { $0.httpMethod ?? "?" } } }
    var paths: [String] { lock.withLock { requests.map { $0.url!.path() } } }
}

private let safeBeautyApp = ReleaseApp(store: .appStore, appIdentifier: "com.safebeauty.app", name: "SafeBeauty", productID: "safe-beauty",
                                       productName: "SafeBeauty", source: "test")
private let safeBeautyAndroid = ReleaseApp(store: .googlePlay, appIdentifier: "com.security.stealthapp", name: "SafeBeauty",
                                           productID: "safe-beauty", productName: "SafeBeauty", source: "test")

private func versionJSON(_ id: String, state: String) -> Data {
    Data(#"{"data":{"type":"appStoreVersions","id":"\#(id)","attributes":{"versionString":"1.0.2","platform":"IOS","appVersionState":"\#(state)","appStoreState":"\#(state)","releaseType":"MANUAL"}}}"#.utf8)
}

// MARK: - App Store Connect

@Suite("Release Center: App Store")
struct ReleaseCenterAppStoreTests {
    @Test func safeBeautyVersionsMatchWhatWasSubmitted() throws {
        let versions = try ReleaseCenterParser.appStoreVersions(try fixture("release-asc-versions-safebeauty"))
        #expect(versions.count == 3)
        let status = AppStoreAppStatus(app: safeBeautyApp, ascAppID: "6810050614", versions: versions, fetchedAt: readAt)
        let pending = try #require(status.inProgress(platform: "IOS"))
        #expect(pending.versionString == "1.0.2")
        #expect(pending.state == "WAITING_FOR_REVIEW")
        #expect(pending.phase == .waitingForReview)
        #expect(pending.releaseType == "MANUAL")
        #expect(pending.build?.number == "9")
        #expect(pending.build?.processingState == "VALID")
        let created = try #require(pending.createdAt)
        #expect(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "America/Los_Angeles")!, from: created).day == 9)
        #expect(pending.build?.uploadedAt == day("2026-10-09T16:36:41Z"))
        #expect(pending.canBeReleasedByOwner == false)
        let live = try #require(status.live(platform: "IOS"))
        #expect(live.versionString == "1.0.1")
        #expect(live.build?.number == "8")
    }

    @Test func twoPlatformVersionsWithoutBuilds() throws {
        let versions = try ReleaseCenterParser.appStoreVersions(try fixture("release-asc-versions-velro-ops"))
        let status = AppStoreAppStatus(app: safeBeautyApp, ascAppID: "x", versions: versions, fetchedAt: readAt)
        #expect(status.platforms == ["IOS", "MAC_OS"])
        #expect(status.inProgress(platform: "MAC_OS")?.phase == .preparing)
        #expect(status.inProgress(platform: "IOS")?.build == nil)
        #expect(status.live(platform: "IOS") == nil)
        #expect(WaitingOnYou.items(ReleaseCenterSnapshot(appStore: [status])).isEmpty)
    }

    @Test func buildsCarryMarketingVersionAndProcessingState() throws {
        let builds = try ReleaseCenterParser.appStoreBuilds(try fixture("release-asc-builds-safebeauty"))
        #expect(builds.count == 5)
        #expect(builds[0].number == "9")
        #expect(builds[0].version == "1.0.2")
        #expect(builds[0].processingState == "VALID")
        #expect(builds[2].version == "1.0.1")
        #expect(!builds.contains { $0.processingFailed })
    }

    @Test func stateMapping() {
        let table: [String: AppStoreVersionPhase] = [
            "READY_FOR_DISTRIBUTION": .live, "READY_FOR_SALE": .live, "PREPARE_FOR_SUBMISSION": .preparing,
            "WAITING_FOR_REVIEW": .waitingForReview, "IN_REVIEW": .inReview, "PENDING_DEVELOPER_RELEASE": .pendingDeveloperRelease,
            "PENDING_APPLE_RELEASE": .pendingAppleRelease, "PROCESSING_FOR_DISTRIBUTION": .processing, "REJECTED": .rejected,
            "METADATA_REJECTED": .rejected, "INVALID_BINARY": .rejected, "DEVELOPER_REJECTED": .developerRejected,
            "REPLACED_WITH_NEW_VERSION": .historical, "SOMETHING_NEW": .unknown,
        ]
        for (raw, phase) in table { #expect(AppStoreVersionPhase.from(raw) == phase, "\(raw)") }
    }

    @Test func releaseRequestBodyIsJSONAPI() throws {
        let body = try JSONSerialization.jsonObject(with: ReleaseCenterParser.releaseRequestBody(versionID: "v-1")) as! [String: Any]
        let data = body["data"] as! [String: Any]
        #expect(data["type"] as? String == "appStoreVersionReleaseRequests")
        let rel = (data["relationships"] as! [String: Any])["appStoreVersion"] as! [String: Any]
        #expect((rel["data"] as! [String: String]) == ["type": "appStoreVersions", "id": "v-1"])
    }
}

// MARK: - Release action

@Suite("Release Center: release action")
struct ReleaseActionTests {
    let client: (ReleaseRecorder) -> AppStoreConnectClient = { transport in
        AppStoreConnectClient(credentials: AppStoreConnectCredentials(issuerID: "issuer", keyID: "KEY", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
                              transport: transport, now: { readAt })
    }
    let version = AppStoreVersionInfo(id: "v-1", versionString: "1.0.2", platform: "IOS", state: "PENDING_DEVELOPER_RELEASE", releaseType: "MANUAL",
                                      build: AppStoreBuildInfo(id: "b", number: "9"))

    @Test func checksSendsOnceAndReadsBack() async throws {
        let reads = ReleaseCounter()
        let t = ReleaseRecorder { r in
            if r.httpMethod == "POST" { return (201, Data(#"{"data":{"type":"appStoreVersionReleaseRequests","id":"r1"}}"#.utf8)) }
            return (200, versionJSON("v-1", state: reads.next() == 0 ? "PENDING_DEVELOPER_RELEASE" : "PROCESSING_FOR_DISTRIBUTION"))
        }
        let record = await AppStoreReleaseAction.release(app: safeBeautyApp, version: version, using: client(t), now: { readAt })
        #expect(t.methods == ["GET", "POST", "GET"])
        #expect(t.paths[1] == "/v1/appStoreVersionReleaseRequests")
        let body = try #require(t.requests[1].httpBody)
        #expect(body == ReleaseCenterParser.releaseRequestBody(versionID: "v-1"))
        #expect(record.outcome == .verified)
        #expect(record.stateBefore == "PENDING_DEVELOPER_RELEASE")
        #expect(record.stateAfter == "PROCESSING_FOR_DISTRIBUTION")
        #expect(record.buildNumber == "9")
    }

    @Test func nothingIsSentWhenTheStateMoved() async {
        let t = ReleaseRecorder { _ in (200, versionJSON("v-1", state: "READY_FOR_DISTRIBUTION")) }
        let record = await AppStoreReleaseAction.release(app: safeBeautyApp, version: version, using: client(t))
        #expect(t.methods == ["GET"])
        #expect(record.outcome == .notSent)
        #expect(record.stateAfter == "READY_FOR_DISTRIBUTION")
    }

    @Test func forbiddenKeyIsExplainedAndNotRetried() async {
        let t = ReleaseRecorder { r in
            if r.httpMethod == "POST" {
                return (403, Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons","detail":"The API key in use does not allow this request"}]}"#.utf8))
            }
            return (200, versionJSON("v-1", state: "PENDING_DEVELOPER_RELEASE"))
        }
        let record = await AppStoreReleaseAction.release(app: safeBeautyApp, version: version, using: client(t))
        #expect(t.methods == ["GET", "POST"])
        #expect(record.outcome == .failed)
        #expect(record.message?.contains("App Manager or Admin") == true)
        #expect(record.message?.contains("does not allow this request") == true)
    }

    @Test func actionLogAppendsAndKeepsEverything() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "release-actions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ReleaseActionLog(fileURL: url)
        let a = ReleaseActionRecord(at: readAt, action: "appstore.release", appName: "SafeBeauty", appIdentifier: "com.safebeauty.app",
                                    versionID: "v", versionString: "1.0.2", platform: "IOS", buildNumber: "9", stateBefore: "PENDING_DEVELOPER_RELEASE",
                                    stateAfter: nil, outcome: .failed, message: "x")
        var b = a
        b.id = UUID()
        b.at = readAt.addingTimeInterval(60)
        b.outcome = .verified
        try await log.append(a)
        try await log.append(b)
        let all = try await log.load()
        #expect(all.map(\.outcome) == [.verified, .failed])
    }
}

final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

// MARK: - Google Play

private func rsaPEM() throws -> String {
    func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
        return [tag] + length + body
    }
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
    var error: Unmanaged<CFError>?
    let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &error))
    let pkcs1 = [UInt8](try #require(SecKeyCopyExternalRepresentation(key, &error)) as Data)
    let rsaOID: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    let pkcs8 = der(0x30, der(0x02, [0]) + der(0x30, rsaOID + [0x05, 0x00]) + der(0x04, pkcs1))
    return "-----BEGIN PRIVATE KEY-----\n" + Data(pkcs8).base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r", with: "") + "\n-----END PRIVATE KEY-----\n"
}

@Suite("Release Center: Google Play")
struct ReleaseCenterPlayTests {
    @Test func editTracksCarryStatusAndNotes() throws {
        let tracks = try ReleaseCenterParser.playEditTracks(try fixture("release-play-edit-tracks-safebeauty"))
        let status = PlayAppStatus(app: safeBeautyAndroid, tracks: tracks, detail: .edit, fetchedAt: readAt)
        #expect(status.tracks.map(\.track) == ["production", "beta", "alpha", "internal"])
        let production = try #require(status.tracks.first?.releases.first)
        #expect(production.status == .completed)
        #expect(production.versionCodes == [22])
        #expect(production.label == "2.1.5 (22)")
        #expect(production.releaseNoteLanguages == ["en-US", "fa-AF", "ps-AF"])
        #expect(production.userFraction == nil)
        #expect(status.tracks[1].releases.first?.isEmptyDraft == true)
        #expect(status.tracks[2].releases.first?.releaseNoteLanguages == ["fa-AF"])
        #expect(status.tracks[3].releases.first?.releaseNoteLanguages == [])
        // Live production and an empty placeholder draft: nothing waits on the owner.
        #expect(WaitingOnYou.items(ReleaseCenterSnapshot(play: [status])).isEmpty)
    }

    @Test func releasesListFallbackLeavesDetailsUnknown() throws {
        struct R: Decodable { let releases: [PlayRelease] }
        let alpha = try JSONDecoder().decode(R.self, from: try fixture("release-play-releases-alpha")).releases
        let beta = try JSONDecoder().decode(R.self, from: try fixture("release-play-releases-beta")).releases
        let tracks = ReleaseCenterParser.playTracks(from: alpha + beta)
        let a = try #require(tracks.first { $0.track == "alpha" }?.releases.first)
        #expect(a.status == .completed)
        #expect(a.versionCodes == [14])
        #expect(a.releaseNoteLanguages == nil)
        #expect(a.userFraction == nil)
        #expect(tracks.first { $0.track == "beta" }?.releases.first?.isEmptyDraft == true)
    }

    @Test func stagedDraftAndHaltedReleasesWaitOnTheOwner() {
        // Synthetic: the states SafeBeauty doesn't have right now.
        let tracks = [
            PlayTrackInfo(track: "production", releases: [
                PlayTrackRelease(name: "2.1.6", versionCodes: [23], status: .inProgress, rawStatus: "inProgress", userFraction: 0.2, releaseNoteLanguages: ["fa-AF"]),
                PlayTrackRelease(name: "2.1.5", versionCodes: [22], status: .completed, rawStatus: "completed"),
            ]),
            PlayTrackInfo(track: "beta", releases: [PlayTrackRelease(name: "2.2.0", versionCodes: [24], status: .draft, rawStatus: "draft", releaseNoteLanguages: [])]),
            PlayTrackInfo(track: "alpha", releases: [PlayTrackRelease(name: "2.0", versionCodes: [20], status: .halted, rawStatus: "halted")]),
        ]
        let items = WaitingOnYou.items(ReleaseCenterSnapshot(play: [PlayAppStatus(app: safeBeautyAndroid, tracks: tracks, detail: .edit, fetchedAt: readAt)]))
        #expect(items.map(\.kind) == [.playHalted, .playDraft, .playStagedRollout])
        #expect(items[1].detail?.isEmpty == false)
        #expect(items.allSatisfy { $0.source.contains("never committed") && $0.observedAt == readAt })
    }

    @Test func editIsReadThenDeletedNeverCommitted() async throws {
        let pem = try rsaPEM()
        let tracks = try fixture("release-play-edit-tracks-safebeauty")
        let t = ReleaseRecorder { r in
            let path = r.url!.path()
            if r.url!.host() == "oauth2.googleapis.com" { return (200, Data(#"{"access_token":"t","expires_in":3600}"#.utf8)) }
            if r.httpMethod == "POST", path.hasSuffix("/edits") { return (200, Data(#"{"id":"e1","expiryTimeSeconds":"1"}"#.utf8)) }
            if r.httpMethod == "GET", path.hasSuffix("/edits/e1/tracks") { return (200, tracks) }
            if r.httpMethod == "DELETE" { return (204, Data()) }
            return (500, Data())
        }
        let client = GooglePlayClient(credentials: GooglePlayCredentials(clientEmail: "sa@example.iam.gserviceaccount.com", privateKeyPEM: pem), transport: t, now: { readAt })
        let status = await client.releaseCenterStatus(for: safeBeautyAndroid, now: readAt)
        #expect(status.error == nil)
        #expect(status.detail == .edit)
        #expect(status.tracks.count == 4)
        let api = t.requests.filter { $0.url!.host() == "androidpublisher.googleapis.com" }
        #expect(api.map { $0.httpMethod! } == ["POST", "GET", "DELETE"])
        #expect(api[2].url!.path().hasSuffix("/edits/e1"))
        #expect(t.requests.allSatisfy { !$0.url!.absoluteString.contains(":commit") && $0.httpMethod != "PUT" && $0.httpMethod != "PATCH" })
    }

    @Test func refusedEditFallsBackToReleasesList() async throws {
        let pem = try rsaPEM()
        let alpha = try fixture("release-play-releases-alpha")
        let t = ReleaseRecorder { r in
            if r.url!.host() == "oauth2.googleapis.com" { return (200, Data(#"{"access_token":"t","expires_in":3600}"#.utf8)) }
            if r.httpMethod == "POST" { return (403, Data(#"{"error":{"code":403}}"#.utf8)) }
            if r.url!.path().hasSuffix("/tracks/alpha/releases") { return (200, alpha) }
            return (200, Data())
        }
        let client = GooglePlayClient(credentials: GooglePlayCredentials(clientEmail: "sa@example.iam.gserviceaccount.com", privateKeyPEM: pem), transport: t, now: { readAt })
        let status = await client.releaseCenterStatus(for: safeBeautyAndroid, now: readAt)
        #expect(status.detail == .releasesList)
        #expect(status.detailNote?.contains("403") == true)
        #expect(status.tracks.map(\.track) == ["alpha"])
        #expect(t.methods.filter { $0 == "DELETE" }.isEmpty)
    }
}

// MARK: - GitHub

private func pull(_ n: Int, base: String, head: String, state: String? = "clean", ci: CIRollup = .success, bot: Bool = false, draft: Bool = false) -> GitHubPullInfo {
    GitHubPullInfo(number: n, title: "PR \(n)", base: base, head: head, headSHA: "sha\(n)", isDraft: draft,
                   url: URL(string: "https://github.com/o/r/pull/\(n)")!, mergeable: state == "unknown" ? nil : true,
                   mergeableState: state, isBot: bot, ci: ci)
}

private let repo = ReleaseRepo(slug: "aminullah-dev/LinumicOS", productName: "Linumic OS", source: "test")

@Suite("Release Center: GitHub")
struct ReleaseCenterGitHubTests {
    @Test func stackedPullsFromTheRealList() throws {
        var pulls = try ReleaseCenterParser.gitHubPulls(try fixture("release-gh-pulls-linumicos"))
        #expect(pulls.map(\.number).sorted() == [6, 7])
        let m = try ReleaseCenterParser.gitHubMergeability(try fixture("release-gh-pull-7"))
        #expect(m.mergeable == true && m.state == "clean")
        for i in pulls.indices { pulls[i].mergeable = true; pulls[i].mergeableState = "clean" }
        let stacks = PullStacks.detect(pulls, defaultBranch: "main")
        #expect(stacks.count == 1)
        #expect(stacks[0].pulls.map(\.number) == [6, 7])
        #expect(stacks[0].targetsDefaultBranch)
        #expect(!stacks[0].isBranched)

        // LinumicOS has no workflows: the stack is ready, bottom first, with the merge hint.
        let status = RepoReleaseStatus(repo: repo, defaultBranch: "main", pulls: pulls, fetchedAt: readAt)
        let items = WaitingOnYou.items(ReleaseCenterSnapshot(repos: [status]))
        #expect(items.count == 1)
        #expect(items[0].kind == .stackReady)
        #expect(items[0].url?.absoluteString.hasSuffix("/pull/6") == true)
        #expect(items[0].detail?.contains("#6 → #7") == true)
        #expect(items[0].detail?.contains("Merge commit, not squash") == true)
    }

    @Test func stackShapes() {
        // Synthetic: a branched stack, a chain whose root targets another branch, a cycle, and a lone PR.
        let pulls = [
            pull(1, base: "main", head: "a"), pull(2, base: "a", head: "b"), pull(3, base: "a", head: "c"),
            pull(4, base: "develop", head: "d"), pull(5, base: "d", head: "e"),
            pull(6, base: "y", head: "x"), pull(7, base: "x", head: "y"),
            pull(8, base: "main", head: "z"),
        ]
        let stacks = PullStacks.detect(pulls, defaultBranch: "main")
        #expect(stacks.map { $0.pulls.map(\.number) } == [[1, 2, 3], [4, 5]])
        #expect(stacks[0].isBranched)
        #expect(!stacks[1].targetsDefaultBranch)
    }

    @Test func onlyTheBottomOfAStackIsReady() {
        let notReady = RepoReleaseStatus(repo: repo, defaultBranch: "main",
                                         pulls: [pull(1, base: "main", head: "a", ci: .failure), pull(2, base: "a", head: "b")],
                                         mainRuns: [GitHubWorkflowRunInfo(id: 1, name: "CI", status: "completed", conclusion: "success")], fetchedAt: readAt)
        #expect(WaitingOnYou.items(ReleaseCenterSnapshot(repos: [notReady])).isEmpty)
    }

    @Test func runsRollUpPerWorkflow() throws {
        #expect(CIRollup.from(try ReleaseCenterParser.gitHubRuns(try fixture("release-gh-runs-pr"))) == .success)
        let main = try ReleaseCenterParser.gitHubRuns(try fixture("release-gh-runs-worktrack-main"))
        #expect(main.contains { $0.event == "dynamic" })
        #expect(CIRollup.from(main) == .success)
        #expect(CIRollup.latestPerWorkflow(main).allSatisfy { $0.event != "dynamic" })
        // SafeBeauty's main failed on 2026-09-23 and passed since: only the newest run of each workflow counts.
        let sb = try ReleaseCenterParser.gitHubRuns(try fixture("release-gh-runs-safebeauty-main"))
        #expect(sb.contains { $0.conclusion == "failure" })
        #expect(CIRollup.from(sb) == .success)
        #expect(Set(CIRollup.latestPerWorkflow(sb).map(\.name)) == ["Build APK", "Pull request"])

        let t0 = day("2026-10-01T00:00:00Z"), t1 = day("2026-10-02T00:00:00Z")
        let failingNow = [GitHubWorkflowRunInfo(id: 1, name: "CI", workflowID: 9, status: "completed", conclusion: "success", createdAt: t0),
                          GitHubWorkflowRunInfo(id: 2, name: "CI", workflowID: 9, status: "completed", conclusion: "failure", createdAt: t1)]
        #expect(CIRollup.from(failingNow) == .failure)
        #expect(CIRollup.from([GitHubWorkflowRunInfo(id: 3, name: "CI", status: "in_progress", createdAt: t1)]) == .pending)
        #expect(CIRollup.from([]) == .none)
        #expect(CIRollup.from([GitHubWorkflowRunInfo(id: 4, name: "Dependabot", event: "dynamic", status: "completed", conclusion: "failure")]) == .none)
    }

    @Test func dependencyUpdatesAreGroupedAndFailingMainIsFlagged() throws {
        var pulls = try ReleaseCenterParser.gitHubPulls(try fixture("release-gh-pulls-worktrack"))
        #expect(pulls.count == 13)
        #expect(pulls.filter { $0.isBot }.count == 12)
        #expect(pulls.first { $0.number == 1 }?.isBot == false)
        for i in pulls.indices { pulls[i].mergeable = true; pulls[i].mergeableState = "clean"; pulls[i].ci = .success }
        let unknown = try #require(pulls.firstIndex { $0.number == 21 })
        pulls[unknown].mergeable = nil
        pulls[unknown].mergeableState = "unknown"   // GitHub still computing: not ready
        let wt = ReleaseRepo(slug: "aminullah-dev/WorkTrack", productName: "WorkTrack", source: "test")
        let failing = [GitHubWorkflowRunInfo(id: 1, name: "CI", workflowID: 1, event: "push", status: "completed", conclusion: "failure",
                                             url: URL(string: "https://github.com/aminullah-dev/WorkTrack/actions/runs/1"), createdAt: readAt)]
        let status = RepoReleaseStatus(repo: wt, defaultBranch: "main", pulls: pulls, mainCI: CIRollup.from(failing), mainRuns: failing, fetchedAt: readAt)
        let items = WaitingOnYou.items(ReleaseCenterSnapshot(repos: [status]))
        #expect(items.map(\.kind) == [.failingCI, .pullReady, .dependencyUpdatesReady])
        #expect(items[0].severity == .high)
        #expect(items[0].url?.absoluteString.hasSuffix("/runs/1") == true)
        #expect(items[1].title.contains("#1"))
        #expect(items[2].title.contains("11"))
        #expect(items[2].detail?.contains("#21") == false)
    }

    @Test func releaseStatusReadsOnlyWithGET() async throws {
        let pulls = try fixture("release-gh-pulls-linumicos")
        let pr = try fixture("release-gh-pull-7")
        let t = ReleaseRecorder { r in
            let p = r.url!.path()
            switch true {
            case p == "/repos/aminullah-dev/LinumicOS": return (200, Data(#"{"default_branch":"main"}"#.utf8))
            case p.hasSuffix("/pulls"): return (200, pulls)
            case p.contains("/pulls/"): return (200, pr)
            case p.hasSuffix("/actions/runs"): return (200, Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8))
            case p.hasSuffix("/releases/latest"): return (404, Data(#"{"message":"Not Found"}"#.utf8))
            case p.hasSuffix("/tags"): return (200, Data("[]".utf8))
            default: return (500, Data())
            }
        }
        let status = await GitHubClient(token: "t", transport: t, now: { readAt }).releaseStatus(repo, recheckDelay: .zero)
        #expect(status.error == nil)
        #expect(status.defaultBranch == "main")
        #expect(status.pulls.count == 2)
        #expect(status.pulls.allSatisfy { $0.mergeableState == "clean" && $0.ci == .none })
        #expect(status.mainCI == .none)
        #expect(status.lastRelease == nil && status.lastReleaseRead)
        #expect(t.methods.allSatisfy { $0 == "GET" })
        #expect(t.requests.allSatisfy { $0.url!.host() == "api.github.com" && $0.httpBody == nil })
    }

    @Test func latestReleaseParses() throws {
        let r = try ReleaseCenterParser.gitHubLatestRelease(try fixture("release-gh-release-latest"))
        #expect(r.tag == "android-app")
        #expect(r.name == "SafeBeauty for Android")
        #expect(r.publishedAt == day("2026-08-25T18:39:52Z"))
    }
}

// MARK: - Waiting on you, catalog, snapshot

@Suite("Release Center: rules and catalog")
struct ReleaseCenterRulesTests {
    @Test func approvedManualVersionAndRejectionWaitOnTheOwner() throws {
        // Synthetic: SafeBeauty's real 1.0.2 moved to PENDING_DEVELOPER_RELEASE; a second app rejected.
        var versions = try ReleaseCenterParser.appStoreVersions(try fixture("release-asc-versions-safebeauty"))
        let i = try #require(versions.firstIndex { $0.versionString == "1.0.2" })
        versions[i].state = "PENDING_DEVELOPER_RELEASE"
        let sb = AppStoreAppStatus(app: safeBeautyApp, ascAppID: "6810050614", versions: versions, fetchedAt: readAt)
        let other = ReleaseApp(store: .appStore, appIdentifier: "x.y", name: "Other", productID: "p", productName: "P", source: "t")
        let rejected = AppStoreAppStatus(app: other, ascAppID: "1", versions: [
            AppStoreVersionInfo(id: "r", versionString: "2.0", platform: "IOS", state: "REJECTED", createdAt: readAt),
        ], builds: [AppStoreBuildInfo(id: "b", number: "12", uploadedAt: readAt, processingState: "FAILED")], fetchedAt: readAt.addingTimeInterval(-60))
        let items = WaitingOnYou.items(ReleaseCenterSnapshot(appStore: [sb, rejected]))
        #expect(items.map(\.kind) == [.releaseVersion, .rejected, .buildProcessingFailed])
        #expect(items[0].versionID == versions[i].id)
        #expect(items[0].appStatusID == sb.id)
        #expect(items[0].title.contains("1.0.2"))
        #expect(items[0].detail?.contains("9") == true)
        #expect(items[0].source == "App Store Connect API /v1/apps/6810050614/appStoreVersions")
        // The real state (waiting for review) is not something the owner can act on.
        let real = AppStoreAppStatus(app: safeBeautyApp, ascAppID: "6810050614",
                                     versions: try ReleaseCenterParser.appStoreVersions(try fixture("release-asc-versions-safebeauty")), fetchedAt: readAt)
        #expect(WaitingOnYou.items(ReleaseCenterSnapshot(appStore: [real])).isEmpty)
    }

    @Test func failedReadsNeverProduceItems() {
        let broken = AppStoreAppStatus(app: safeBeautyApp, ascAppID: nil, versions: [
            AppStoreVersionInfo(id: "r", versionString: "2.0", platform: "IOS", state: "REJECTED"),
        ], fetchedAt: readAt, error: "403")
        #expect(WaitingOnYou.items(ReleaseCenterSnapshot(appStore: [broken])).isEmpty)
    }

    @Test func catalogComesFromTheInventory() throws {
        let seed = try SeedInventory.load()
        let apps = ReleaseCatalog.apps(from: seed.products)
        let ios = apps.filter { $0.store == .appStore }.map(\.appIdentifier).sorted()
        let android = apps.filter { $0.store == .googlePlay }.map(\.appIdentifier).sorted()
        // The same seven bundle ids App Store Connect listed on 2026-10-09 (GET /v1/apps).
        #expect(ios == ["af.market.nerkhtimes", "af.namazia.app", "af.velro.driver", "af.velro.ops", "af.velro.passenger", "app.worktrack", "com.safebeauty.app"])
        #expect(android == ["af.market.nerkhtimes", "af.namazia.app", "af.velro.driver", "af.velro.passenger", "app.worktrack", "com.security.stealthapp"])
        #expect(apps.allSatisfy { !$0.source.isEmpty })
        let repos = ReleaseCatalog.repos(from: seed.products).map(\.slug)
        #expect(repos.contains("aminullah-dev/LinumicOS"))
        #expect(repos.contains("aminullah-dev/stealth-service-vault-"))
        #expect(!repos.contains("aminullah-dev/talar-releases"))
        #expect(repos.allSatisfy { $0.hasPrefix("aminullah-dev/") })
    }

    @Test func snapshotRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "release-center-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReleaseCenterStore(fileURL: url)
        #expect(store.load() == ReleaseCenterSnapshot())
        let s = ReleaseCenterSnapshot(appStore: [AppStoreAppStatus(app: safeBeautyApp, ascAppID: "1",
                                                                   versions: try ReleaseCenterParser.appStoreVersions(try fixture("release-asc-versions-safebeauty")),
                                                                   fetchedAt: readAt)],
                                      repos: [RepoReleaseStatus(repo: repo, defaultBranch: "main", pulls: [pull(6, base: "main", head: "a")], fetchedAt: readAt)],
                                      appStoreReadAt: readAt)
        try store.save(s)
        #expect(store.load() == s)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Bearer"))
    }
}
