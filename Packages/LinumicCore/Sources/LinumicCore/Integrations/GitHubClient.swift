import Foundation

/// Minimal HTTP abstraction so the GitHub client can be tested with recorded responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum GitHubError: Error, LocalizedError, Equatable {
    case unauthorized
    case notFound(String)
    case rateLimited(resetAt: Date?)
    case http(Int)
    case invalidSlug(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: L("GitHub rejected the token (401). Check it in Settings → Integrations.")
        case .notFound(let path): LF("Not found on GitHub (404): %@. A private repository needs a token with access to it.", path)
        case .rateLimited(let reset): reset.map { LF("GitHub rate limit reached. Resets at %@.", $0.formatted(date: .omitted, time: .shortened)) } ?? L("GitHub rate limit reached.")
        case .http(let code): LF("GitHub returned HTTP %d.", code)
        case .invalidSlug(let s): "\"\(s)\" is not an owner/name repository slug."
        }
    }
}

/// Read-only GitHub REST client. It has GET requests only: no push, merge, delete,
/// or settings changes exist in this type.
public struct GitHubClient: RepositoryHostClient {
    public static let apiBase = URL(string: "https://api.github.com")!

    private let transport: HTTPTransport
    private let token: String?
    private let now: @Sendable () -> Date

    /// `token` is optional: without one, only public repositories can be read (60 requests/hour).
    public init(token: String?, transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { .now }) {
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.transport = transport
        self.now = now
    }

    // MARK: Wire formats (only the fields we use)

    private struct RepoDTO: Decodable {
        let name: String
        let full_name: String
        let `private`: Bool
        let visibility: String?
        let description: String?
        let homepage: String?
        let default_branch: String
    }

    private struct CommitDTO: Decodable {
        struct Inner: Decodable {
            struct Person: Decodable { let name: String?; let date: Date? }
            let message: String
            let author: Person?
            let committer: Person?
        }
        let sha: String
        let commit: Inner
    }

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable { let name: String }
        let tag_name: String
        let name: String?
        let published_at: Date?
        let draft: Bool
        let assets: [Asset]
    }

    private struct IssueDTO: Decodable {
        let pull_request: [String: String?]?
    }

    private struct RunsDTO: Decodable {
        struct Run: Decodable { let status: String; let conclusion: String? }
        let workflow_runs: [Run]
    }

    private struct RepoListingDTO: Decodable {
        let full_name: String
        let `private`: Bool
        let archived: Bool?
        let pushed_at: Date?
    }

    /// We only need the count of each security-alert list, so one id field is enough to decode.
    private struct AlertDTO: Decodable { let number: Int }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        var components = URLComponents(url: Self.apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LinumicOS", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        case 401: throw GitHubError.unauthorized
        case 404: throw GitHubError.notFound(path)
        case 403, 429:
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || response.statusCode == 429 {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw GitHubError.rateLimited(resetAt: reset)
            }
            throw GitHubError.http(response.statusCode)
        default: throw GitHubError.http(response.statusCode)
        }
    }

    /// Returns the raw HTTP status of a GET without decoding a body. Used for existence probes
    /// (e.g. branch protection, where 404 is a meaningful "not protected", not an error).
    private func status(of path: String) async -> Int? {
        var request = URLRequest(url: Self.apiBase.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LinumicOS", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try? await transport.send(request).1.statusCode
    }

    /// Count of open alerts from one of the security-alert list endpoints. Best-effort:
    /// returns `nil` (Unknown) whenever the list can't be read — feature disabled, no scope,
    /// or any HTTP/transport error. Never invents a zero.
    private func openAlertCount(_ path: String) async -> Int? {
        do {
            let alerts = try await get(path, query: [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "per_page", value: "100"),
            ], as: [AlertDTO].self)
            return alerts.count
        } catch { return nil }
    }

    /// Whether the default branch has a protection rule. 200 = protected, 404 = not protected,
    /// anything else (403 no scope, transport error) = Unknown (`nil`).
    private func defaultBranchProtected(base: String, branch: String) async -> Bool? {
        switch await status(of: "\(base)/branches/\(branch)/protection") {
        case 200: return true
        case 404: return false
        default: return nil
        }
    }

    /// Reads the read-only security posture of a repository. Every field is independent and
    /// best-effort, so a repo with Dependabot on but secret-scanning off still reports what it can.
    private func security(base: String, branch: String) async -> RepositorySnapshot.Security {
        async let dependabot = openAlertCount("\(base)/dependabot/alerts")
        async let secrets = openAlertCount("\(base)/secret-scanning/alerts")
        async let code = openAlertCount("\(base)/code-scanning/alerts")
        async let protection = defaultBranchProtected(base: base, branch: branch)
        return await RepositorySnapshot.Security(
            dependabotAlerts: dependabot,
            secretScanningAlerts: secrets,
            codeScanningAlerts: code,
            defaultBranchProtected: protection,
            observedAt: now()
        )
    }

    /// Lists every repository the authenticated user owns (private included), newest push first.
    /// Without a token it falls back to the owner's public repositories. Archived repos are kept
    /// (they still carry history worth watching) but flagged by the caller via the snapshot.
    public func listOwnedRepositories(fallbackOwner: String? = nil) async throws -> [RepositorySnapshot.Listing] {
        var all: [RepoListingDTO] = []
        var page = 1
        while true {
            let batch: [RepoListingDTO]
            if token != nil {
                batch = try await get("user/repos", query: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "affiliation", value: "owner"),
                    URLQueryItem(name: "sort", value: "pushed"),
                ], as: [RepoListingDTO].self)
            } else {
                guard let owner = fallbackOwner?.nilIfEmpty else { throw GitHubError.unauthorized }
                batch = try await get("users/\(owner)/repos", query: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "sort", value: "pushed"),
                ], as: [RepoListingDTO].self)
            }
            all.append(contentsOf: batch)
            if batch.count < 100 || page >= 10 { break }  // guard against runaway pagination
            page += 1
        }
        return all.map {
            .init(slug: $0.full_name, isPrivate: $0.`private`, isArchived: $0.archived ?? false, pushedAt: $0.pushed_at)
        }
    }

    private static func conclusion(of run: RunsDTO.Run?) -> RepositorySnapshot.CIConclusion {
        guard let run else { return .none }
        if run.status != "completed" { return .inProgress }
        switch run.conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "cancelled": return .cancelled
        default: return .none
        }
    }

    /// Reads one repository. Counts are capped at 100 per list (one page). Larger numbers are reported as 100.
    public func snapshot(slug: String) async throws -> RepositorySnapshot {
        let parts = slug.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GitHubError.invalidSlug(slug) }
        let base = "repos/\(parts[0])/\(parts[1])"
        let page = [URLQueryItem(name: "per_page", value: "100")]

        let repo = try await get(base, as: RepoDTO.self)
        async let commit = get("\(base)/commits/\(repo.default_branch)", as: CommitDTO.self)
        async let releases = get("\(base)/releases", query: page, as: [ReleaseDTO].self)
        async let pulls = get("\(base)/pulls", query: page + [URLQueryItem(name: "state", value: "open")], as: [IssueDTO].self)
        async let issues = get("\(base)/issues", query: page + [URLQueryItem(name: "state", value: "open")], as: [IssueDTO].self)
        async let languages = get("\(base)/languages", as: [String: Int].self)
        async let runs = get("\(base)/actions/runs", query: [URLQueryItem(name: "branch", value: repo.default_branch), URLQueryItem(name: "per_page", value: "1")], as: RunsDTO.self)
        async let security = security(base: base, branch: repo.default_branch)

        let c = try? await commit  // an empty repository has no commits
        let published = (try await releases).filter { !$0.draft }
        let latestRun = (try? await runs)?.workflow_runs.first  // Actions may be disabled; that isn't an error
        let openPulls = try await pulls.count
        let openIssues = try await issues.filter { $0.pull_request == nil }.count
        let languageNames = try await languages.sorted { $0.value > $1.value }.map(\.key)
        let securitySnapshot = await security

        return RepositorySnapshot(
            slug: repo.full_name,
            visibility: repo.visibility.flatMap(RepositoryVisibility.init(rawValue:)) ?? (repo.private ? .private : .public),
            description: repo.description,
            homepage: repo.homepage?.nilIfEmpty.flatMap(URL.init(string:)),
            defaultBranch: repo.default_branch,
            latestCommit: c.map { .init(sha: $0.sha, message: $0.commit.message.components(separatedBy: "\n").first ?? "",
                                        author: $0.commit.author?.name, date: $0.commit.committer?.date ?? $0.commit.author?.date) },
            releaseCount: published.count,
            latestRelease: published.first.map { .init(tag: $0.tag_name, name: $0.name, publishedAt: $0.published_at, assets: $0.assets.map(\.name)) },
            openPullRequests: openPulls,
            openIssues: openIssues,
            languages: languageNames,
            ciConclusion: Self.conclusion(of: latestRun),
            security: securitySnapshot,
            fetchedAt: now()
        )
    }
}

/// Refreshes the GitHub snapshots of every GitHub repository in the inventory. Read-only.
public enum RepositorySync {
    public struct Report: Sendable, Equatable {
        public var updated: [String] = []
        public var failed: [String: String] = [:]
        public var skipped: [String] = []
    }

    /// Returns updated products plus a report. Only `gitHub` snapshots change. Links, types and
    /// verification are never modified by a sync.
    public static func refresh(_ products: [Product], using client: RepositoryHostClient) async -> ([Product], Report) {
        var result = products
        var report = Report()
        for (pi, product) in products.enumerated() {
            for (ri, repo) in product.repositories.enumerated() {
                guard let slug = repo.gitHubSlug else {
                    report.skipped.append(repo.name)
                    continue
                }
                do {
                    result[pi].repositories[ri].gitHub = try await client.snapshot(slug: slug)
                    report.updated.append(slug)
                } catch {
                    report.failed[slug] = error.localizedDescription
                }
            }
        }
        return (result, report)
    }
}

/// Discovers and refreshes the oversight register from GitHub. Read-only: it lists the owner's
/// repositories, keeps every slug it finds, and refreshes each one's snapshot (which carries the
/// security posture). Existing snapshots are kept when a refresh fails, so a transient error never
/// blanks the dashboard.
public enum OversightSync {
    public struct Report: Sendable, Equatable {
        public var discovered: [String] = []   // slugs seen for the first time
        public var updated: [String] = []       // snapshots refreshed this run
        public var failed: [String: String] = [:]
        public var listError: String?           // the repository list itself could not be read
    }

    /// Returns the merged, refreshed register plus a report. `owner` is the public fallback used
    /// when there is no token. Archived repositories are included. The result preserves prior
    /// snapshots for any repo that failed to refresh.
    public static func refresh(
        _ existing: [OversightRepo], using client: GitHubClient, owner: String?, now: @Sendable () -> Date = { .now }
    ) async -> ([OversightRepo], Report) {
        var report = Report()
        var bySlug: [String: OversightRepo] = Dictionary(uniqueKeysWithValues: existing.map { ($0.slug, $0) })

        // 1. Discover the full repository set.
        let listings: [RepositorySnapshot.Listing]
        do {
            listings = try await client.listOwnedRepositories(fallbackOwner: owner)
        } catch {
            // Keep whatever we already had; just report that discovery failed.
            report.listError = error.localizedDescription
            return (existing, report)
        }
        for listing in listings where bySlug[listing.slug] == nil {
            report.discovered.append(listing.slug)
            bySlug[listing.slug] = OversightRepo(slug: listing.slug, isPrivate: listing.isPrivate,
                                                 isArchived: listing.isArchived, pushedAt: listing.pushedAt, observedAt: now())
        }
        // Refresh listing-level facts (visibility, archived, push time) for known repos too.
        for listing in listings {
            bySlug[listing.slug]?.isPrivate = listing.isPrivate
            bySlug[listing.slug]?.isArchived = listing.isArchived
            bySlug[listing.slug]?.pushedAt = listing.pushedAt
        }

        // 2. Refresh each repo's snapshot (includes security). Best-effort per repo.
        for slug in bySlug.keys {
            do {
                let snapshot = try await client.snapshot(slug: slug)
                bySlug[slug]?.snapshot = snapshot
                bySlug[slug]?.scanError = nil
                bySlug[slug]?.observedAt = now()
                report.updated.append(slug)
            } catch {
                bySlug[slug]?.scanError = error.localizedDescription
                bySlug[slug]?.observedAt = now()
                report.failed[slug] = error.localizedDescription
            }
        }

        let merged = bySlug.values.sorted {
            ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast)
        }
        return (merged, report)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
