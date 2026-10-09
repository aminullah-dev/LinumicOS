import Foundation

// Read-only release tracking for the platforms hub: the latest release with download counts, recent
// releases, the version files on the default branch, the latest run of every workflow on that branch,
// and the open pull-request count. GET requests only, all conditional when the client has an ETag cache.

extension GitHubClient {
    private struct RepoDTO: Decodable { let default_branch: String }

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable { let name: String; let download_count: Int; let browser_download_url: URL? }
        let tag_name: String
        let name: String?
        let published_at: Date?
        let draft: Bool
        let prerelease: Bool
        let html_url: URL?
        let assets: [Asset]

        var model: GitHubRelease {
            GitHubRelease(tag: tag_name, name: name?.nilIfEmpty, publishedAt: published_at, isPrerelease: prerelease, url: html_url,
                          assets: assets.map { .init(name: $0.name, downloadCount: $0.download_count, url: $0.browser_download_url) })
        }
    }

    private struct WorkflowsDTO: Decodable {
        struct Workflow: Decodable { let id: Int; let name: String; let path: String; let state: String }
        let workflows: [Workflow]
    }

    private struct RunsDTO: Decodable {
        struct Run: Decodable {
            let status: String
            let conclusion: String?
            let created_at: Date?
            let html_url: URL?
            let head_sha: String?
            let event: String?
        }
        let workflow_runs: [Run]
    }

    private struct PullDTO: Decodable { let number: Int }

    /// Reads one repository for the hub. Throws only when the repository itself can't be read (then the
    /// caller keeps the previous data); any other part that fails is listed in `problems` and left empty.
    public func releaseTracking(slug: String, versionFiles: [VersionFileSpec]) async throws -> RepoReleaseTracking {
        let parts = slug.split(separator: "/")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GitHubError.invalidSlug(slug) }
        let base = "repos/\(parts[0])/\(parts[1])"
        let branch = try await get(base, as: RepoDTO.self).default_branch
        var problems: [String] = []

        // Latest release: 404 is a fact ("no release"), not an error.
        let latest: RepoReleaseTracking.LatestRelease?
        do {
            latest = .release(try await get("\(base)/releases/latest", as: ReleaseDTO.self).model)
        } catch GitHubError.notFound {
            latest = RepoReleaseTracking.LatestRelease.none
        } catch {
            latest = nil
            problems.append(LF("Latest release: %@", error.localizedDescription))
        }

        var recent: [GitHubRelease] = []
        do {
            recent = try await get("\(base)/releases", query: [URLQueryItem(name: "per_page", value: "10")], as: [ReleaseDTO].self)
                .filter { !$0.draft }.map(\.model)
        } catch {
            problems.append(LF("Releases: %@", error.localizedDescription))
        }

        var openPulls: Int?
        do {
            openPulls = try await get("\(base)/pulls", query: [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "100")],
                                      as: [PullDTO].self).count
        } catch {
            problems.append(LF("Pull requests: %@", error.localizedDescription))
        }

        // Workflows defined in the repository; GitHub's dynamic ones (Dependabot, Pages) are left out.
        var workflows: [WorkflowStatus]?
        do {
            let defined = try await get("\(base)/actions/workflows", query: [URLQueryItem(name: "per_page", value: "100")], as: WorkflowsDTO.self)
                .workflows.filter { $0.path.hasPrefix(".github/workflows/") && $0.state == "active" }
            var statuses: [WorkflowStatus] = []
            for w in defined {
                do {
                    let run = try await get("\(base)/actions/workflows/\(w.id)/runs", query: [
                        URLQueryItem(name: "branch", value: branch),
                        URLQueryItem(name: "per_page", value: "1"),
                        URLQueryItem(name: "exclude_pull_requests", value: "true"),
                    ], as: RunsDTO.self).workflow_runs.first
                    statuses.append(WorkflowStatus(id: w.id, name: w.name, path: w.path, latestRun: run.map {
                        .init(status: $0.status, conclusion: $0.conclusion, createdAt: $0.created_at, url: $0.html_url, headSHA: $0.head_sha, event: $0.event)
                    }))
                } catch {
                    problems.append(LF("Workflow %@: %@", w.name, error.localizedDescription))
                }
            }
            workflows = statuses
        } catch {
            problems.append(LF("Workflows: %@", error.localizedDescription))
        }

        var versions: [VersionReading] = []
        for spec in versionFiles where spec.repo.caseInsensitiveCompare(slug) == .orderedSame {
            versions.append(await readVersion(spec, base: base, branch: branch))
        }

        return RepoReleaseTracking(slug: slug, defaultBranch: branch, latestRelease: latest, recentReleases: recent,
                                   workflows: workflows, openPullRequests: openPulls, versions: versions,
                                   problems: problems, error: nil, fetchedAt: now())
    }

    /// Reads one version file from the default branch through the contents API (raw media type).
    private func readVersion(_ spec: VersionFileSpec, base: String, branch: String) async -> VersionReading {
        let path = spec.path.split(separator: "/").map(String.init).joined(separator: "/")
        do {
            let data = try await getData("\(base)/contents/\(path)", query: [URLQueryItem(name: "ref", value: branch)],
                                         accept: "application/vnd.github.raw+json")
            let parsed = VersionFileParser.parse(String(decoding: data, as: UTF8.self), format: spec.format)
            return VersionReading(specID: spec.id, repo: spec.repo, path: spec.path, ref: branch, versionName: parsed.name,
                                  versionCode: parsed.code, line: parsed.line,
                                  error: parsed.name == nil ? L("The file has no version this app can read.") : nil, fetchedAt: now())
        } catch {
            return VersionReading(specID: spec.id, repo: spec.repo, path: spec.path, ref: branch, error: error.localizedDescription, fetchedAt: now())
        }
    }
}
