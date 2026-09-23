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

        let c = try? await commit  // an empty repository has no commits
        let published = (try await releases).filter { !$0.draft }
        let latestRun = (try? await runs)?.workflow_runs.first  // Actions may be disabled; that isn't an error
        let openPulls = try await pulls.count
        let openIssues = try await issues.filter { $0.pull_request == nil }.count
        let languageNames = try await languages.sorted { $0.value > $1.value }.map(\.key)

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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
