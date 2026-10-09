import Foundation

// MARK: - Stacked pull requests

/// Pull requests that build on each other: the bottom one targets a normal branch, and each next one targets the
/// branch of the one below it. Listed in merge order, bottom first.
public struct PullStack: Hashable, Sendable, Identifiable {
    public var pulls: [GitHubPullInfo]
    /// The branch the bottom PR targets.
    public var rootBase: String
    /// True when the bottom PR targets the default branch.
    public var targetsDefaultBranch: Bool
    /// True when two PRs build on the same PR (a tree, not a single line). Merge order is then depth-first.
    public var isBranched: Bool

    public var id: Int { pulls.first?.number ?? 0 }
    public var bottom: GitHubPullInfo? { pulls.first }

    /// The owner merges stacks with merge commits from the bottom up (the top of the list down), so each later PR
    /// keeps its history and GitHub retargets it to the default branch.
    public static let mergeHint = "Merge from the top of the stack down, using Merge commit, not squash."
}

public enum PullStacks {
    /// Finds every chain of two or more open PRs where one PR's base is another open PR's head branch.
    public static func detect(_ pulls: [GitHubPullInfo], defaultBranch: String) -> [PullStack] {
        let byHead = Dictionary(pulls.map { ($0.head, $0) }, uniquingKeysWith: { a, b in a.number < b.number ? a : b })
        var children: [String: [GitHubPullInfo]] = [:]   // head branch -> PRs built on it
        for pr in pulls where byHead[pr.base] != nil && pr.base != pr.head {
            children[pr.base, default: []].append(pr)
        }
        let roots = pulls.filter { byHead[$0.base] == nil && children[$0.head] != nil }.sorted { $0.number < $1.number }
        var stacks: [PullStack] = []
        var used = Set<Int>()
        for root in roots {
            var order: [GitHubPullInfo] = []
            var branched = false
            func visit(_ pr: GitHubPullInfo) {
                guard used.insert(pr.number).inserted else { return }   // guards against cycles
                order.append(pr)
                let next = (children[pr.head] ?? []).sorted { $0.number < $1.number }
                if next.count > 1 { branched = true }
                next.forEach(visit)
            }
            visit(root)
            if order.count > 1 {
                stacks.append(PullStack(pulls: order, rootBase: root.base, targetsDefaultBranch: root.base == defaultBranch, isBranched: branched))
            }
        }
        return stacks
    }
}

// MARK: - Waiting on you

/// Something only the owner can do, with where it was read and when.
public struct WaitingItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// App Store version approved with a manual release: press Release.
        case releaseVersion
        case rejected
        case buildProcessingFailed
        case playDraft
        case playHalted
        case playStagedRollout
        case pullReady
        case stackReady
        case dependencyUpdatesReady
        case failingCI
    }

    public enum Severity: Int, Sendable, Comparable {
        case high = 0, normal = 1, info = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    public var severity: Severity
    /// The app or repository it concerns (a name of record).
    public var subject: String
    public var title: String
    public var detail: String?
    public var source: String
    public var observedAt: Date
    public var url: URL?
    /// For `.releaseVersion`: which app status and version the action applies to.
    public var appStatusID: String?
    public var versionID: String?

    public var id: String { "\(kind.rawValue)|\(subject)|\(versionID ?? url?.absoluteString ?? title)" }
}

public enum WaitingOnYou {
    /// The rules, in one place:
    /// - App Store: a version in PENDING_DEVELOPER_RELEASE (approved, manual release) or rejected; the newest build
    ///   failing processing.
    /// - Google Play: a halted release; a draft with version codes (staged by a script, waiting for "Start rollout");
    ///   a staged rollout below 100% (informational).
    /// - GitHub: failing CI on the default branch; a PR ready to merge (not a draft, GitHub says clean, and CI green,
    ///   or no CI at all in a repository without workflows); for a stack only the bottom PR, once ready; bot
    ///   dependency updates grouped per repository.
    public static func items(_ s: ReleaseCenterSnapshot) -> [WaitingItem] {
        var out: [WaitingItem] = []

        for app in s.appStore where app.error == nil {
            for platform in app.platforms {
                guard let v = app.inProgress(platform: platform) else { continue }
                let label = app.platforms.count > 1 ? "\(v.platformTitle) \(v.versionString)" : v.versionString
                let build = v.build.map { LF("build %@", $0.number) }
                switch v.phase {
                case .pendingDeveloperRelease:
                    out.append(WaitingItem(kind: .releaseVersion, severity: .high, subject: app.app.name,
                                           title: LF("Version %@ is approved and waits for you to release it", label),
                                           detail: build, source: app.endpoint, observedAt: app.fetchedAt,
                                           url: app.ascAppID.flatMap { URL(string: "https://appstoreconnect.apple.com/apps/\($0)/distribution") },
                                           appStatusID: app.id, versionID: v.id))
                case .rejected:
                    out.append(WaitingItem(kind: .rejected, severity: .high, subject: app.app.name,
                                           title: LF("Version %@ was rejected (%@)", label, v.state),
                                           detail: L("Read the message in App Store Connect's App Review section, fix, and resubmit."),
                                           source: app.endpoint, observedAt: app.fetchedAt,
                                           url: app.ascAppID.flatMap { URL(string: "https://appstoreconnect.apple.com/apps/\($0)/distribution") }))
                default: break
                }
            }
            if let newest = app.builds.max(by: { ($0.uploadedAt ?? .distantPast) < ($1.uploadedAt ?? .distantPast) }), newest.processingFailed {
                out.append(WaitingItem(kind: .buildProcessingFailed, severity: .normal, subject: app.app.name,
                                       title: LF("Build %@ failed processing (%@)", newest.number, newest.processingState ?? "?"),
                                       detail: nil, source: "App Store Connect API /v1/builds?filter[app]=\(app.ascAppID ?? "?")",
                                       observedAt: app.fetchedAt, url: nil))
            }
        }

        for app in s.play where app.error == nil {
            let console = URL(string: "https://play.google.com/console/")
            for track in app.tracks {
                for r in track.releases {
                    switch r.status {
                    case .halted:
                        out.append(WaitingItem(kind: .playHalted, severity: .high, subject: app.app.name,
                                               title: LF("The %@ release %@ is halted", track.track, r.label),
                                               detail: L("Resume or replace it in Play Console."), source: app.endpoint,
                                               observedAt: app.fetchedAt, url: console))
                    case .draft where !r.isEmptyDraft:
                        out.append(WaitingItem(kind: .playDraft, severity: .normal, subject: app.app.name,
                                               title: LF("Draft %@ on %@ waits for you to start the rollout", r.label, track.track),
                                               detail: r.releaseNoteLanguages.map { $0.isEmpty ? L("No release notes yet.") : LF("Release notes: %@", $0.joined(separator: ", ")) },
                                               source: app.endpoint, observedAt: app.fetchedAt, url: console))
                    case .inProgress:
                        let share = r.userFraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "?"
                        out.append(WaitingItem(kind: .playStagedRollout, severity: .info, subject: app.app.name,
                                               title: LF("%@ on %@ is rolled out to %@ of users", r.label, track.track, share),
                                               detail: L("Increase or complete the rollout in Play Console when it looks healthy."),
                                               source: app.endpoint, observedAt: app.fetchedAt, url: console))
                    default: break
                    }
                }
            }
        }

        for repo in s.repos where repo.error == nil {
            let branch = repo.defaultBranch ?? "main"
            let runsSource = "GitHub /repos/\(repo.repo.slug)/actions/runs?branch=\(branch)"
            if repo.mainCI == .failure {
                let failing = CIRollup.latestPerWorkflow(repo.mainRuns).filter(\.isFailure)
                out.append(WaitingItem(kind: .failingCI, severity: .high, subject: repo.repo.slug,
                                       title: LF("CI is failing on %@", branch),
                                       detail: failing.isEmpty ? nil : failing.map(\.name).joined(separator: ", "),
                                       source: runsSource, observedAt: repo.fetchedAt,
                                       url: failing.first?.url ?? URL(string: "https://github.com/\(repo.repo.slug)/actions")))
            }
            let noCIAtAll = repo.mainRuns.filter { $0.event != "dynamic" }.isEmpty
            func ready(_ pr: GitHubPullInfo) -> Bool {
                pr.isCleanlyMergeable && (pr.ci == .success || (pr.ci == .none && noCIAtAll))
            }
            let pullsSource = "GitHub /repos/\(repo.repo.slug)/pulls"
            let stacks = repo.stacks
            let stacked = Set(stacks.flatMap { $0.pulls.map(\.number) })
            for stack in stacks {
                guard let bottom = stack.bottom, ready(bottom) else { continue }
                let order = stack.pulls.map { "#\($0.number)" }.joined(separator: " → ")
                out.append(WaitingItem(kind: .stackReady, severity: .normal, subject: repo.repo.slug,
                                       title: LF("Stack of %d PRs ready: merge #%d first", stack.pulls.count, bottom.number),
                                       detail: "\(order). \(L(PullStack.mergeHint))" + (bottom.ci == .none ? " " + L("This repository has no CI.") : ""),
                                       source: pullsSource, observedAt: repo.fetchedAt, url: bottom.url))
            }
            let standalone = repo.pulls.filter { !stacked.contains($0.number) && ready($0) }
            let bots = standalone.filter(\.isBot)
            if bots.count > 1 {
                out.append(WaitingItem(kind: .dependencyUpdatesReady, severity: .info, subject: repo.repo.slug,
                                       title: LF("%d dependency updates are ready to merge", bots.count),
                                       detail: bots.map { "#\($0.number)" }.joined(separator: ", "),
                                       source: pullsSource, observedAt: repo.fetchedAt,
                                       url: URL(string: "https://github.com/\(repo.repo.slug)/pulls")))
            }
            for pr in standalone where !(pr.isBot && bots.count > 1) {
                out.append(WaitingItem(kind: .pullReady, severity: pr.isBot ? .info : .normal, subject: repo.repo.slug,
                                       title: LF("PR #%d is ready to merge: %@", pr.number, pr.title),
                                       detail: pr.ci == .none ? L("This repository has no CI.") : L("CI passing, no conflicts."),
                                       source: pullsSource, observedAt: repo.fetchedAt, url: pr.url))
            }
        }

        return out.sorted { ($0.severity, -$0.observedAt.timeIntervalSince1970, $0.subject) < ($1.severity, -$1.observedAt.timeIntervalSince1970, $1.subject) }
    }
}
