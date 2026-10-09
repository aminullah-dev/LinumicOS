import Foundation

// The Release Center's reads, on the existing clients and the credentials they already hold (no second copy of
// any credential). The App layer supplies the URLSession transport and decides when to call these.
//
// Writes: exactly one, `AppStoreConnectClient.requestRelease(versionID:)`. The Play read opens an edit only to read
// tracks and deletes it at once; an edit changes nothing until it is committed, and nothing here commits.

public enum ReleaseCenterError: Error, LocalizedError, Equatable {
    /// Apple answered 403 to the release request: the key's role can't release versions.
    case releaseNotPermitted(String?)
    /// The version isn't (or is no longer) approved and waiting for a manual release.
    case versionNotAwaitingRelease(String)
    /// Apple refused the release request for another reason.
    case releaseRefused(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .releaseNotPermitted(let detail):
            LF("App Store Connect refused the release (403): the API key in Settings → Integrations can read but not release. Releasing needs a key with the App Manager or Admin role. Nothing was changed. %@", detail ?? "")
        case .versionNotAwaitingRelease(let state):
            LF("This version is no longer waiting for a manual release (its state is now %@). Nothing was sent.", state)
        case .releaseRefused(let code, let detail):
            LF("App Store Connect refused the release (HTTP %d). Nothing was changed. %@", code, detail ?? "")
        }
    }
}

// MARK: - App Store Connect

extension AppStoreConnectClient {
    /// Up to 20 versions per app with the build attached to each.
    public func releaseVersions(appID: String) async throws -> [AppStoreVersionInfo] {
        let data = try await get("v1/apps/\(appID)/appStoreVersions", query: [
            URLQueryItem(name: "fields[appStoreVersions]", value: "versionString,platform,appVersionState,appStoreState,releaseType,earliestReleaseDate,createdDate,build"),
            URLQueryItem(name: "include", value: "build"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate,processingState,expired"),
            URLQueryItem(name: "limit", value: "20"),
        ])
        return try ReleaseCenterParser.appStoreVersions(data)
    }

    /// The newest builds of an app with their processing state.
    public func releaseBuilds(appID: String, limit: Int = 8) async throws -> [AppStoreBuildInfo] {
        let data = try await get("v1/builds", query: [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate,expired,processingState,preReleaseVersion"),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
            URLQueryItem(name: "fields[preReleaseVersions]", value: "version,platform"),
        ])
        return try ReleaseCenterParser.appStoreBuilds(data)
    }

    /// One version, read fresh.
    public func appStoreVersion(id: String) async throws -> AppStoreVersionInfo {
        let data = try await get("v1/appStoreVersions/\(id)", query: [
            URLQueryItem(name: "fields[appStoreVersions]", value: "versionString,platform,appVersionState,appStoreState,releaseType,createdDate"),
        ])
        return try ReleaseCenterParser.appStoreVersion(data)
    }

    /// Everything the Release Center shows for one App Store app. Failures are carried in `error`, never thrown.
    public func releaseCenterStatus(for app: ReleaseApp, now: Date) async -> AppStoreAppStatus {
        do {
            guard let id = try await appID(bundleID: app.appIdentifier) else {
                return AppStoreAppStatus(app: app, ascAppID: nil, fetchedAt: now,
                                         error: LF("No app with bundle id %@ in this App Store Connect account.", app.appIdentifier))
            }
            let versions = try await releaseVersions(appID: id)
            // Builds are extra detail: a failure there doesn't hide the versions.
            let builds = (try? await releaseBuilds(appID: id)) ?? []
            return AppStoreAppStatus(app: app, ascAppID: id, versions: versions, builds: builds, fetchedAt: now)
        } catch {
            return AppStoreAppStatus(app: app, ascAppID: nil, fetchedAt: now, error: error.localizedDescription)
        }
    }

    /// The one write: asks Apple to release an approved version that waits for a manual release.
    /// Sent once and never retried by this code.
    public func requestRelease(versionID: String) async throws {
        let (data, status) = try await send("POST", "v1/appStoreVersionReleaseRequests",
                                            body: ReleaseCenterParser.releaseRequestBody(versionID: versionID))
        switch status {
        case 200..<300: return
        case 401: throw StoreConsoleError.unauthorized(Self.service)
        case 403: throw ReleaseCenterError.releaseNotPermitted(ReleaseCenterParser.appStoreErrorDetail(data))
        default: throw ReleaseCenterError.releaseRefused(status, ReleaseCenterParser.appStoreErrorDetail(data))
        }
    }
}

/// Releasing an approved App Store version: check, send once, read back.
public enum AppStoreReleaseAction {
    /// 1. Reads the version again; if it isn't PENDING_DEVELOPER_RELEASE any more, nothing is sent.
    /// 2. Sends the release request once.
    /// 3. Reads the version back: processing for distribution or live counts as verified.
    /// Every path returns a record for the action log, including failures.
    public static func release(app: ReleaseApp, version: AppStoreVersionInfo, using client: AppStoreConnectClient,
                               now: @Sendable () -> Date = { .now }) async -> ReleaseActionRecord {
        func record(_ outcome: ReleaseActionRecord.Outcome, state: String?, _ message: String?) -> ReleaseActionRecord {
            ReleaseActionRecord(at: now(), action: "appstore.release", appName: app.name, appIdentifier: app.appIdentifier,
                                versionID: version.id, versionString: version.versionString, platform: version.platform,
                                buildNumber: version.build?.number, stateBefore: version.state, stateAfter: state,
                                outcome: outcome, message: message)
        }
        let current: AppStoreVersionInfo
        do { current = try await client.appStoreVersion(id: version.id) } catch {
            return record(.notSent, state: nil, error.localizedDescription)
        }
        guard current.canBeReleasedByOwner else {
            return record(.notSent, state: current.state, ReleaseCenterError.versionNotAwaitingRelease(current.state).localizedDescription)
        }
        do { try await client.requestRelease(versionID: version.id) } catch {
            return record(.failed, state: current.state, error.localizedDescription)
        }
        do {
            let after = try await client.appStoreVersion(id: version.id)
            let moved = [.processing, .live, .pendingAppleRelease].contains(after.phase)
            return record(moved ? .verified : .unverified, state: after.state,
                          moved ? nil : LF("Apple accepted the request, but the version still reads %@. Check again in a few minutes.", after.state))
        } catch {
            return record(.unverified, state: nil, LF("Apple accepted the request; reading it back failed: %@", error.localizedDescription))
        }
    }
}

// MARK: - Google Play

extension GooglePlayClient {
    private func call(_ method: String, _ path: String) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://androidpublisher.googleapis.com/")!.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        return (data, response.statusCode)
    }

    /// Tracks with status, rollout share and release notes, read through an edit that is deleted right after and
    /// never committed (an uncommitted edit changes nothing, see Safe beauty/DEPLOY.md). If Play refuses the edit
    /// (for example a read-only account), falls back to releases.list, which needs no edit but says less.
    public func releaseCenterStatus(for app: ReleaseApp, now: Date) async -> PlayAppStatus {
        let base = "androidpublisher/v3/applications/\(app.appIdentifier)/edits"
        var note: String?
        do {
            let (created, status) = try await call("POST", base)
            if (200..<300).contains(status) {
                struct Edit: Decodable { let id: String }
                let edit = try decodeResponse(Edit.self, from: created, what: "edits.insert")
                let tracks: Result<[PlayTrackInfo], Error>
                do {
                    let (data, s) = try await call("GET", "\(base)/\(edit.id)/tracks")
                    tracks = (200..<300).contains(s) ? .success(try ReleaseCenterParser.playEditTracks(data))
                        : .failure(StoreConsoleError.from(status: s, service: Self.service, path: "edits.tracks"))
                } catch { tracks = .failure(error) }
                // Always delete the edit. If this fails, Play discards an unused edit on its own after it expires.
                _ = try? await call("DELETE", "\(base)/\(edit.id)")
                switch tracks {
                case .success(let list): return PlayAppStatus(app: app, tracks: list, detail: .edit, fetchedAt: now)
                case .failure(let error): note = error.localizedDescription
                }
            } else if status == 404 {
                return PlayAppStatus(app: app, tracks: [], detail: .releasesList, fetchedAt: now,
                                     error: LF("No app with package %@ in this Play account.", app.appIdentifier))
            } else {
                note = LF("Play didn't open a read-only edit (HTTP %d), so rollout share and release notes aren't shown.", status)
            }
        } catch {
            note = error.localizedDescription
        }
        do {
            let releases = try await allReleases(packageName: app.appIdentifier)
            return PlayAppStatus(app: app, tracks: ReleaseCenterParser.playTracks(from: releases), detail: .releasesList,
                                 fetchedAt: now, detailNote: note)
        } catch {
            return PlayAppStatus(app: app, tracks: [], detail: .releasesList, fetchedAt: now, error: error.localizedDescription, detailNote: note)
        }
    }
}

// MARK: - GitHub

extension GitHubClient {
    /// Open PRs (with mergeability and CI for each head commit), CI on the default branch and the last release or
    /// tag of one repository. GET only. Failures are carried in `error`, never thrown.
    /// `recheckDelay`: GitHub computes mergeability lazily; PRs it hadn't computed yet are read once more after it.
    public func releaseStatus(_ repo: ReleaseRepo, recheckDelay: Duration = .milliseconds(1500)) async -> RepoReleaseStatus {
        let base = "repos/\(repo.slug)"
        do {
            struct Repo: Decodable { let default_branch: String }
            let branch = try ReleaseCenterParser.gitHubDecoder.decode(Repo.self, from: try await getData(base)).default_branch
            var pulls = try ReleaseCenterParser.gitHubPulls(try await getData("\(base)/pulls", query: [
                URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "100"),
            ]))
            for i in pulls.indices {
                if let m = try? ReleaseCenterParser.gitHubMergeability(try await getData("\(base)/pulls/\(pulls[i].number)")) {
                    pulls[i].mergeable = m.mergeable
                    pulls[i].mergeableState = m.state
                }
                if !pulls[i].headSHA.isEmpty, let runs = try? ReleaseCenterParser.gitHubRuns(try await getData("\(base)/actions/runs", query: [
                    URLQueryItem(name: "head_sha", value: pulls[i].headSHA), URLQueryItem(name: "per_page", value: "30"),
                ])) {
                    pulls[i].ciRuns = CIRollup.latestPerWorkflow(runs)
                    pulls[i].ci = CIRollup.from(runs)
                }
            }
            if pulls.contains(where: { $0.mergeable == nil && !$0.isDraft }) {
                try? await Task.sleep(for: recheckDelay)
                for i in pulls.indices where pulls[i].mergeable == nil && !pulls[i].isDraft {
                    if let m = try? ReleaseCenterParser.gitHubMergeability(try await getData("\(base)/pulls/\(pulls[i].number)")) {
                        pulls[i].mergeable = m.mergeable
                        pulls[i].mergeableState = m.state
                    }
                }
            }
            let mainRuns = (try? ReleaseCenterParser.gitHubRuns(try await getData("\(base)/actions/runs", query: [
                URLQueryItem(name: "branch", value: branch), URLQueryItem(name: "per_page", value: "30"),
                URLQueryItem(name: "exclude_pull_requests", value: "true"),
            ])))?.filter { !["pull_request", "pull_request_target"].contains($0.event ?? "") } ?? []

            var release: GitHubReleaseRef?
            var releaseRead = false
            do {
                release = try ReleaseCenterParser.gitHubLatestRelease(try await getData("\(base)/releases/latest"))
                releaseRead = true
            } catch GitHubError.notFound {
                // No published release: fall back to the newest tag. No tag either is a fact ("none"), not unknown.
                if let data = try? await getData("\(base)/tags", query: [URLQueryItem(name: "per_page", value: "1")]) {
                    do {
                        release = try ReleaseCenterParser.gitHubNewestTag(data, slug: repo.slug)
                        releaseRead = true
                    } catch {}
                }
            } catch {}

            return RepoReleaseStatus(repo: repo, defaultBranch: branch, pulls: pulls.sorted { $0.number < $1.number },
                                     mainCI: CIRollup.from(mainRuns), mainRuns: CIRollup.latestPerWorkflow(mainRuns),
                                     lastRelease: release, lastReleaseRead: releaseRead, fetchedAt: now())
        } catch {
            return RepoReleaseStatus(repo: repo, defaultBranch: nil, fetchedAt: now(), error: error.localizedDescription)
        }
    }
}
