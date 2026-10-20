import Foundation

// MARK: - The two reads the Products and Agents pages add
//
// Both are GitHub GETs through the existing client and token (no new key, no other host):
//   * the newest commits on a repository's default branch: `GET /repos/{r}` and `GET /repos/{r}/commits?sha=<branch>&per_page=100`
//     (only the committer dates and the newest sha are kept);
//   * the newest pull requests of a repository: `GET /repos/{r}/pulls?state=all&sort=created&direction=desc&per_page=50`
//     (only the agents' pull requests are kept).
// Everything else on the pages comes from what the Platforms hub, the Release Center, the licence ledger and the Monitor
// already read.

extension GitHubClient {
    /// The newest commits on the default branch of one repository.
    public func mainHistory(slug: String) async throws -> MainHistory {
        let parts = slug.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GitHubError.invalidSlug(slug) }
        let base = "repos/\(parts[0])/\(parts[1])"
        struct Repo: Decodable { let default_branch: String }
        let branch = try ProductsParser.decoder.decode(Repo.self, from: try await getData(base)).default_branch
        let data = try await getData("\(base)/commits", query: [
            URLQueryItem(name: "sha", value: branch), URLQueryItem(name: "per_page", value: String(MainHistory.pageSize)),
        ])
        let commits = try ProductsParser.commits(data)
        return MainHistory(repo: slug, branch: branch, commitDates: commits.map(\.date), newestSHA: commits.first?.sha,
                           isComplete: commits.count < MainHistory.pageSize, readAt: now())
    }

    /// The newest pull requests of one repository (open, merged and closed), keeping only the agents'.
    public func agentPullWindow(slug: String, slugs: Set<String>) async throws -> RepoPullWindow {
        let parts = slug.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GitHubError.invalidSlug(slug) }
        let data = try await getData("repos/\(parts[0])/\(parts[1])/pulls", query: [
            URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc"), URLQueryItem(name: "per_page", value: String(RepoPullWindow.pageSize)),
        ])
        return try ProductsParser.pullWindow(data, repo: slug, slugs: slugs, readAt: now())
    }
}

/// Parses the two reads. Pure, so each is tested against recorded responses (`Fixtures/products-*.json`).
public enum ProductsParser {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// `GET /repos/{r}/commits`: each commit's sha and committer date (the time it landed on the branch, for a merge or a
    /// squash), falling back to the author date. Nothing else of a commit is decoded.
    public static func commits(_ data: Data) throws -> [(sha: String, date: Date)] {
        struct Person: Decodable { let date: Date? }
        struct Inner: Decodable { let committer: Person?; let author: Person? }
        struct Commit: Decodable { let sha: String; let commit: Inner }
        let list = try decodeResponse([Commit].self, from: data, decoder: decoder, what: "commits")
        return list.compactMap { c in (c.commit.committer?.date ?? c.commit.author?.date).map { (c.sha, $0) } }
    }

    /// `GET /repos/{r}/pulls?state=all`: the page's size and oldest creation time, and the agents' pull requests on it.
    public static func pullWindow(_ data: Data, repo: String, slugs: Set<String>, readAt: Date) throws -> RepoPullWindow {
        struct Branch: Decodable { let ref: String }
        struct PR: Decodable {
            let number: Int
            let title: String
            let state: String
            let draft: Bool?
            let html_url: URL
            let created_at: Date
            let updated_at: Date?
            let closed_at: Date?
            let merged_at: Date?
            let head: Branch
        }
        let list = try decodeResponse([PR].self, from: data, decoder: decoder, what: "pulls")
        let pulls: [AgentPull] = list.compactMap { pr in
            guard let slug = AgentMatcher.slug(title: pr.title, head: pr.head.ref, slugs: slugs) else { return nil }
            let state: AgentPull.State = pr.state == "open" ? .open : (pr.merged_at != nil ? .merged : .closed)
            return AgentPull(slug: slug, repo: repo, number: pr.number, title: pr.title, head: pr.head.ref, state: state,
                             isDraft: pr.draft ?? false, url: pr.html_url, createdAt: pr.created_at, updatedAt: pr.updated_at,
                             closedAt: pr.closed_at, mergedAt: pr.merged_at)
        }
        return RepoPullWindow(repo: repo, pulls: pulls, pageCount: list.count, oldestCreatedAt: list.map(\.created_at).min(),
                              isComplete: list.count < RepoPullWindow.pageSize, readAt: readAt)
    }
}

// MARK: - Refresh

/// Reads what the two pages add, read-only, one repository after another. A repository that fails keeps its previous
/// reading with the error attached, so a transient failure never blanks a page; a rate limit stops the round.
public enum ProductsSync {
    public struct Report: Sendable, Equatable {
        public var updated: [String] = []
        public var failed: [String: String] = [:]
    }

    /// The repositories whose default-branch commits the Products page uses: every compared platform's version file
    /// repository and every product's code repository.
    public static func historyRepos(products: [Product], catalog: [CompanyProduct] = ProductsCatalog.products,
                                    versionFiles: [VersionFileSpec] = PlatformCatalog.profiles.flatMap(\.versionFiles) + ProductsCatalog.extraVersionFiles) -> [String] {
        let specs = Dictionary(versionFiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [String] = []
        func add(_ slug: String) { if seen.insert(slug.lowercased()).inserted { out.append(slug) } }
        for product in catalog {
            let inventory = product.inventoryID.flatMap { id in products.first { $0.id == id } }
            for slot in product.slots { if let repo = slot.versionSpec.flatMap({ specs[$0] })?.repo { add(repo) } }
            for repo in ProductsBuilder.repositories(product, inventory: inventory) { add(repo) }
        }
        return out
    }

    public static func refresh(products: [Product], file: ProductsFile, using client: GitHubClient,
                               registry: AgentRegistry = .bundled) async -> (ProductsFile, Report) {
        var report = Report()
        var out = file
        var stop: String?
        func failed(_ repo: String, _ error: Error) {
            if case GitHubError.rateLimited = error { stop = error.localizedDescription }
            report.failed[repo] = error.localizedDescription
        }

        // Linumic OS: its version file, releases, workflows and pull request count (the Platforms hub has no row for it).
        for spec in ProductsCatalog.extraVersionFiles {
            if let stop { report.failed[spec.repo] = stop; continue }
            do {
                let tracking = try await client.releaseTracking(slug: spec.repo, versionFiles: [spec])
                out.extraTracking.removeAll { $0.slug.caseInsensitiveCompare(spec.repo) == .orderedSame }
                out.extraTracking.append(tracking)
                report.updated.append(spec.repo)
            } catch {
                failed(spec.repo, error)
                if let i = out.extraTracking.firstIndex(where: { $0.slug.caseInsensitiveCompare(spec.repo) == .orderedSame }) {
                    out.extraTracking[i].error = error.localizedDescription
                }
            }
        }

        for repo in historyRepos(products: products) {
            if let stop { out.historyErrors[repo] = stop; report.failed[repo] = stop; continue }
            do {
                let history = try await client.mainHistory(slug: repo)
                out.history.removeAll { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
                out.history.append(history)
                out.historyErrors[repo] = nil
                report.updated.append(repo)
            } catch {
                failed(repo, error)
                out.historyErrors[repo] = error.localizedDescription
            }
        }

        let slugs = Set(registry.agents.map(\.slug))
        for repo in registry.repositories {
            if let stop { mark(repo, stop, &out); report.failed[repo] = stop; continue }
            do {
                let window = try await client.agentPullWindow(slug: repo, slugs: slugs)
                out.pullWindows.removeAll { $0.id == window.id }
                out.pullWindows.append(window)
                report.updated.append(repo)
            } catch {
                failed(repo, error)
                mark(repo, error.localizedDescription, &out)
            }
        }
        out.lastRefresh = client.now()
        return (out, report)
    }

    private static func mark(_ repo: String, _ message: String, _ file: inout ProductsFile) {
        if let i = file.pullWindows.firstIndex(where: { $0.id == repo.lowercased() }) { file.pullWindows[i].error = message }
        // Never read before: nothing to keep, so it stays unread (the report and the page say so).
    }
}

// MARK: - Local cache

/// What the two pages read, kept on this device (`products-agents.json`, next to `inventory.json`) so they show the last
/// reading with its time after a relaunch. Observations only (dates, version files, the agents' pull request titles and
/// links), no credential and no response body; rebuilt by the next refresh.
public struct ProductsFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var history: [MainHistory]
    public var historyErrors: [String: String]
    public var extraTracking: [RepoReleaseTracking]
    public var pullWindows: [RepoPullWindow]
    public var lastRefresh: Date?

    public init(history: [MainHistory] = [], historyErrors: [String: String] = [:], extraTracking: [RepoReleaseTracking] = [],
                pullWindows: [RepoPullWindow] = [], lastRefresh: Date? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.history = history
        self.historyErrors = historyErrors
        self.extraTracking = extraTracking
        self.pullWindows = pullWindows
        self.lastRefresh = lastRefresh
    }
}

public struct ProductsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "products-agents.json")
    }

    /// A missing, unreadable or newer-schema file loads as empty: it is a cache.
    public func load() -> ProductsFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? InventoryCoding.decoder().decode(ProductsFile.self, from: data),
              file.schemaVersion <= ProductsFile.currentSchemaVersion else { return ProductsFile() }
        return file
    }

    public func save(_ file: ProductsFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(file).write(to: fileURL, options: [.atomic])
    }
}
