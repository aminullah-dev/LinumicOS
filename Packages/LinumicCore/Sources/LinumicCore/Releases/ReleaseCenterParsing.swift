import Foundation

/// Parses the Release Center's API responses. Pure functions over `Data`, so each one is tested against recorded
/// responses in `Tests/LinumicCoreTests/Fixtures/release-*.json`.
public enum ReleaseCenterParser {
    // MARK: App Store Connect

    private struct Ref: Decodable { let id: String; let type: String? }
    private struct ToOne: Decodable { let data: Ref? }

    /// `GET /v1/apps/{id}/appStoreVersions?include=build`: versions with their attached build.
    public static func appStoreVersions(_ data: Data) throws -> [AppStoreVersionInfo] {
        struct Attributes: Decodable {
            let versionString: String
            let platform: String?
            let appVersionState: String?
            let appStoreState: String?
            let releaseType: String?
            let earliestReleaseDate: Date?
            let createdDate: Date?
        }
        struct Relationships: Decodable { let build: ToOne? }
        struct Item: Decodable { let id: String; let attributes: Attributes; let relationships: Relationships? }
        struct BuildAttributes: Decodable { let version: String?; let uploadedDate: Date?; let processingState: String?; let expired: Bool? }
        struct Included: Decodable { let id: String; let type: String; let attributes: BuildAttributes? }
        struct Response: Decodable { let data: [Item]; let included: [Included]? }

        let r = try decodeResponse(Response.self, from: data, decoder: AppStoreConnectClient.decoder, what: "appStoreVersions")
        let builds = Dictionary((r.included ?? []).filter { $0.type == "builds" }.map { ($0.id, $0.attributes) }, uniquingKeysWith: { a, _ in a })
        return r.data.map { item in
            let a = item.attributes
            var build: AppStoreBuildInfo?
            if let id = item.relationships?.build?.data?.id {
                let b = builds[id] ?? nil
                build = AppStoreBuildInfo(id: id, number: b?.version ?? "?", version: a.versionString, platform: a.platform,
                                          uploadedAt: b?.uploadedDate, processingState: b?.processingState, expired: b?.expired)
            }
            return AppStoreVersionInfo(id: item.id, versionString: a.versionString, platform: a.platform ?? "UNKNOWN",
                                       state: a.appVersionState ?? a.appStoreState ?? "UNKNOWN", releaseType: a.releaseType,
                                       earliestReleaseDate: a.earliestReleaseDate, createdAt: a.createdDate, build: build)
        }
    }

    /// `GET /v1/appStoreVersions/{id}`: one version (used to check the state right before and after a release).
    public static func appStoreVersion(_ data: Data) throws -> AppStoreVersionInfo {
        struct Attributes: Decodable {
            let versionString: String
            let platform: String?
            let appVersionState: String?
            let appStoreState: String?
            let releaseType: String?
            let createdDate: Date?
        }
        struct Item: Decodable { let id: String; let attributes: Attributes }
        struct Response: Decodable { let data: Item }
        let r = try decodeResponse(Response.self, from: data, decoder: AppStoreConnectClient.decoder, what: "appStoreVersion")
        let a = r.data.attributes
        return AppStoreVersionInfo(id: r.data.id, versionString: a.versionString, platform: a.platform ?? "UNKNOWN",
                                   state: a.appVersionState ?? a.appStoreState ?? "UNKNOWN", releaseType: a.releaseType, createdAt: a.createdDate)
    }

    /// `GET /v1/builds?filter[app]=…&include=preReleaseVersion`: newest builds with processing state.
    public static func appStoreBuilds(_ data: Data) throws -> [AppStoreBuildInfo] {
        struct Attributes: Decodable { let version: String; let uploadedDate: Date?; let processingState: String?; let expired: Bool? }
        struct Relationships: Decodable { let preReleaseVersion: ToOne? }
        struct Item: Decodable { let id: String; let attributes: Attributes; let relationships: Relationships? }
        struct PreAttributes: Decodable { let version: String?; let platform: String? }
        struct Included: Decodable { let id: String; let type: String; let attributes: PreAttributes? }
        struct Response: Decodable { let data: [Item]; let included: [Included]? }
        let r = try decodeResponse(Response.self, from: data, decoder: AppStoreConnectClient.decoder, what: "builds")
        let pre = Dictionary((r.included ?? []).filter { $0.type == "preReleaseVersions" }.map { ($0.id, $0.attributes) }, uniquingKeysWith: { a, _ in a })
        return r.data.map { b in
            let p = b.relationships?.preReleaseVersion?.data.flatMap { pre[$0.id] } ?? nil
            return AppStoreBuildInfo(id: b.id, number: b.attributes.version, version: p?.version, platform: p?.platform,
                                     uploadedAt: b.attributes.uploadedDate, processingState: b.attributes.processingState,
                                     expired: b.attributes.expired)
        }
    }

    /// The first `detail` (or `title`) of an App Store Connect error body, for a readable message.
    public static func appStoreErrorDetail(_ data: Data) -> String? {
        struct E: Decodable { let title: String?; let detail: String?; let code: String? }
        struct R: Decodable { let errors: [E]? }
        guard let first = (try? JSONDecoder().decode(R.self, from: data))?.errors?.first else { return nil }
        return first.detail ?? first.title ?? first.code
    }

    /// The JSON:API body of `POST /v1/appStoreVersionReleaseRequests` for one version.
    public static func releaseRequestBody(versionID: String) -> Data {
        let body: [String: Any] = [
            "data": [
                "type": "appStoreVersionReleaseRequests",
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: Google Play

    /// `GET applications/{package}/edits/{edit}/tracks`: every track with status, rollout fraction and notes.
    public static func playEditTracks(_ data: Data) throws -> [PlayTrackInfo] {
        struct Note: Decodable { let language: String?; let text: String? }
        struct Release: Decodable {
            let name: String?
            let versionCodes: [FlexibleInt]?
            let status: String?
            let userFraction: Double?
            let releaseNotes: [Note]?
        }
        struct Track: Decodable { let track: String; let releases: [Release]? }
        struct Response: Decodable { let tracks: [Track]? }
        let r = try decodeResponse(Response.self, from: data, what: "edits.tracks")
        return (r.tracks ?? []).map { t in
            PlayTrackInfo(track: t.track, releases: (t.releases ?? []).map { rel in
                PlayTrackRelease(name: rel.name, versionCodes: (rel.versionCodes ?? []).compactMap(\.value),
                                 status: .from(editStatus: rel.status), rawStatus: rel.status ?? "unknown",
                                 userFraction: rel.userFraction,
                                 releaseNoteLanguages: (rel.releaseNotes ?? []).filter { !($0.text ?? "").isEmpty }.compactMap(\.language))
            })
        }
    }

    /// Builds tracks from releases.list results (no rollout fraction, no notes: those stay nil, i.e. unknown).
    public static func playTracks(from releases: [PlayRelease]) -> [PlayTrackInfo] {
        Dictionary(grouping: releases, by: \.track).map { track, list in
            PlayTrackInfo(track: track, releases: list.map {
                PlayTrackRelease(name: $0.releaseName, versionCodes: $0.versionCodes, status: .from(lifecycle: $0.state), rawStatus: $0.state)
            })
        }
    }

    // MARK: GitHub

    static var gitHubDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// `GET /repos/{r}/pulls?state=open`. Mergeability and CI are filled in later from the single-PR read and runs.
    public static func gitHubPulls(_ data: Data) throws -> [GitHubPullInfo] {
        struct Branch: Decodable { let ref: String; let sha: String? }
        struct User: Decodable { let login: String?; let type: String? }
        struct PR: Decodable {
            let number: Int
            let title: String
            let draft: Bool?
            let html_url: URL
            let created_at: Date?
            let updated_at: Date?
            let base: Branch
            let head: Branch
            let user: User?
        }
        let list = try decodeResponse([PR].self, from: data, decoder: gitHubDecoder, what: "pulls")
        return list.map {
            GitHubPullInfo(number: $0.number, title: $0.title, base: $0.base.ref, head: $0.head.ref, headSHA: $0.head.sha ?? "",
                           isDraft: $0.draft ?? false, url: $0.html_url,
                           isBot: $0.user?.type == "Bot" || ($0.user?.login ?? "").hasSuffix("[bot]"),
                           createdAt: $0.created_at, updatedAt: $0.updated_at)
        }
    }

    /// `GET /repos/{r}/pulls/{n}`: `mergeable` and `mergeable_state`.
    public static func gitHubMergeability(_ data: Data) throws -> (mergeable: Bool?, state: String?) {
        struct PR: Decodable { let mergeable: Bool?; let mergeable_state: String? }
        let pr = try decodeResponse(PR.self, from: data, decoder: gitHubDecoder, what: "pull")
        return (pr.mergeable, pr.mergeable_state)
    }

    /// `GET /repos/{r}/actions/runs?...`.
    public static func gitHubRuns(_ data: Data) throws -> [GitHubWorkflowRunInfo] {
        struct Run: Decodable {
            let id: Int
            let name: String?
            let workflow_id: Int?
            let event: String?
            let status: String?
            let conclusion: String?
            let html_url: URL?
            let created_at: Date?
            let head_sha: String?
        }
        struct Response: Decodable { let workflow_runs: [Run] }
        return try decodeResponse(Response.self, from: data, decoder: gitHubDecoder, what: "actions/runs").workflow_runs.map {
            GitHubWorkflowRunInfo(id: $0.id, name: $0.name ?? "?", workflowID: $0.workflow_id, event: $0.event, status: $0.status ?? "unknown",
                                  conclusion: $0.conclusion, url: $0.html_url, createdAt: $0.created_at, headSHA: $0.head_sha)
        }
    }

    /// `GET /repos/{r}/releases/latest`.
    public static func gitHubLatestRelease(_ data: Data) throws -> GitHubReleaseRef {
        struct R: Decodable { let tag_name: String; let name: String?; let published_at: Date?; let html_url: URL? }
        let r = try decodeResponse(R.self, from: data, decoder: gitHubDecoder, what: "releases/latest")
        return GitHubReleaseRef(kind: .release, tag: r.tag_name, name: r.name?.isEmpty == true ? nil : r.name, publishedAt: r.published_at, url: r.html_url)
    }

    /// `GET /repos/{r}/tags?per_page=1`: the newest tag, or nil when the repository has none.
    public static func gitHubNewestTag(_ data: Data, slug: String) throws -> GitHubReleaseRef? {
        struct T: Decodable { let name: String }
        guard let t = try decodeResponse([T].self, from: data, decoder: gitHubDecoder, what: "tags").first else { return nil }
        return GitHubReleaseRef(kind: .tag, tag: t.name, url: URL(string: "https://github.com/\(slug)/releases/tag/\(t.name)"))
    }
}

/// Google encodes int64 as a JSON string ("22"); accept a number or a string.
struct FlexibleInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { value = n } else { value = Int((try? c.decode(String.self)) ?? "") }
    }
}
