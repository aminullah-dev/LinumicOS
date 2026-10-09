import Foundation

// Release Center: where every app is in every store, what waits on the owner, and whether every repository is green.
//
// Every value here is an observation read from App Store Connect, the Google Play Developer API or GitHub, stamped
// with the endpoint it came from and the time it was read. Nothing is guessed: a value the API didn't return stays nil
// and the UI shows it as unknown.

// MARK: - Which apps and repositories

/// One app on one store, taken from an inventory store listing (which carries its own evidence).
public struct ReleaseApp: Codable, Hashable, Sendable, Identifiable {
    public var store: AppStore
    /// Bundle id (App Store) or package name (Google Play).
    public var appIdentifier: String
    /// The listing's app name, shown as recorded (a name of record, not translated).
    public var name: String
    public var productID: String
    public var productName: String
    /// Where the identifier was recorded: the listing's first source reference.
    public var source: String

    public var id: String { "\(store.rawValue)|\(appIdentifier)" }

    public init(store: AppStore, appIdentifier: String, name: String, productID: String, productName: String, source: String) {
        self.store = store
        self.appIdentifier = appIdentifier
        self.name = name
        self.productID = productID
        self.productName = productName
        self.source = source
    }
}

/// A GitHub repository the Release Center watches.
public struct ReleaseRepo: Codable, Hashable, Sendable, Identifiable {
    /// `owner/name`.
    public var slug: String
    public var productName: String
    public var source: String

    public var id: String { slug }
    public var url: URL { URL(string: "https://github.com/\(slug)")! }

    public init(slug: String, productName: String, source: String) {
        self.slug = slug
        self.productName = productName
        self.source = source
    }
}

public enum ReleaseCatalog {
    /// The GitHub account whose product repositories are watched.
    public static let owner = "aminullah-dev"

    /// Repository kinds that ship a product (code repositories). Websites, research, marketing and release-only
    /// repositories have no pull requests to merge for a release.
    static let codeTypes: Set<RepositoryType> = [.monorepo, .application, .backend]

    /// Repositories that hold product code but aren't an inventory product's repository.
    /// Linumic OS itself: `git remote get-url origin` in ~/Projects/Multiplatform/Linumic/LinumicCommandCenter (2026-10-09).
    public static let extraRepos: [ReleaseRepo] = [
        ReleaseRepo(slug: "aminullah-dev/LinumicOS", productName: "Linumic OS",
                    source: "git remote of ~/Projects/Multiplatform/Linumic/LinumicCommandCenter (2026-10-09)"),
    ]

    /// Every App Store and Google Play listing in the inventory that has an identifier. A listing without one can't
    /// be read from a console, so it is left out rather than guessed.
    public static func apps(from products: [Product]) -> [ReleaseApp] {
        var seen = Set<String>()
        var out: [ReleaseApp] = []
        for product in products {
            for listing in product.storeListings {
                guard let id = listing.appIdentifier?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { continue }
                let app = ReleaseApp(store: listing.store, appIdentifier: id, name: listing.appName ?? id, productID: product.id,
                                     productName: product.name,
                                     source: listing.verification.sources.first?.reference ?? "Inventory store listing")
                if seen.insert(app.id).inserted { out.append(app) }
            }
        }
        return out.sorted { ($0.store.rawValue, $0.productName, $0.name) < ($1.store.rawValue, $1.productName, $1.name) }
    }

    /// The owner's code repositories from the inventory, plus `extraRepos`.
    public static func repos(from products: [Product]) -> [ReleaseRepo] {
        var seen = Set<String>()
        var out: [ReleaseRepo] = []
        for product in products {
            for repo in product.repositories where codeTypes.contains(repo.type) {
                guard let slug = repo.gitHubSlug, slug.lowercased().hasPrefix(owner.lowercased() + "/") else { continue }
                if seen.insert(slug.lowercased()).inserted {
                    out.append(ReleaseRepo(slug: slug, productName: product.name, source: "Inventory repository of \(product.name)"))
                }
            }
        }
        for extra in extraRepos where seen.insert(extra.slug.lowercased()).inserted { out.append(extra) }
        return out.sorted { $0.slug.lowercased() < $1.slug.lowercased() }
    }
}

// MARK: - App Store

/// What an App Store version's state means for the owner.
public enum AppStoreVersionPhase: String, Codable, Sendable, CaseIterable {
    case live
    case preparing
    case waitingForReview
    case inReview
    /// Approved; with a manual release it waits for the owner to press Release.
    case pendingDeveloperRelease
    /// Approved with a scheduled date, or Apple is releasing it.
    case pendingAppleRelease
    case processing
    case rejected
    /// Pulled from review by the developer.
    case developerRejected
    case historical
    case unknown

    /// Maps `appVersionState` (current) or `appStoreState` (older) to a phase. Unknown values stay `.unknown`.
    public static func from(_ raw: String) -> AppStoreVersionPhase {
        switch raw {
        case "READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "PREORDER_READY_FOR_SALE": .live
        case "PREPARE_FOR_SUBMISSION", "WAITING_FOR_EXPORT_COMPLIANCE", "PENDING_CONTRACT": .preparing
        case "WAITING_FOR_REVIEW", "READY_FOR_REVIEW": .waitingForReview
        case "IN_REVIEW": .inReview
        case "PENDING_DEVELOPER_RELEASE": .pendingDeveloperRelease
        case "PENDING_APPLE_RELEASE", "ACCEPTED": .pendingAppleRelease
        case "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE": .processing
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY": .rejected
        case "DEVELOPER_REJECTED": .developerRejected
        case "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "NOT_APPLICABLE": .historical
        default: .unknown
        }
    }

    public var title: String {
        switch self {
        case .live: L("Live")
        case .preparing: L("Preparing for submission")
        case .waitingForReview: L("Waiting for review")
        case .inReview: L("In review")
        case .pendingDeveloperRelease: L("Approved, waiting for you to release")
        case .pendingAppleRelease: L("Approved, Apple releases it")
        case .processing: L("Processing for the App Store")
        case .rejected: L("Rejected")
        case .developerRejected: L("Removed from review")
        case .historical: L("Replaced")
        case .unknown: L("Unknown state")
        }
    }
}

/// A build as App Store Connect reports it.
public struct AppStoreBuildInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The build number (`CFBundleVersion`).
    public var number: String
    /// The marketing version from the build's pre-release version, when included.
    public var version: String?
    public var platform: String?
    public var uploadedAt: Date?
    /// PROCESSING, FAILED, INVALID or VALID.
    public var processingState: String?
    public var expired: Bool?

    public init(id: String, number: String, version: String? = nil, platform: String? = nil, uploadedAt: Date? = nil,
                processingState: String? = nil, expired: Bool? = nil) {
        self.id = id
        self.number = number
        self.version = version
        self.platform = platform
        self.uploadedAt = uploadedAt
        self.processingState = processingState
        self.expired = expired
    }

    public var processingFailed: Bool { processingState == "FAILED" || processingState == "INVALID" }
}

/// One App Store version with the build attached to it.
public struct AppStoreVersionInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var versionString: String
    /// IOS, MAC_OS, TV_OS, VISION_OS.
    public var platform: String
    /// The raw state as Apple sent it (`appVersionState`, else `appStoreState`).
    public var state: String
    /// MANUAL, AFTER_APPROVAL or SCHEDULED.
    public var releaseType: String?
    public var earliestReleaseDate: Date?
    public var createdAt: Date?
    public var build: AppStoreBuildInfo?

    public init(id: String, versionString: String, platform: String, state: String, releaseType: String? = nil,
                earliestReleaseDate: Date? = nil, createdAt: Date? = nil, build: AppStoreBuildInfo? = nil) {
        self.id = id
        self.versionString = versionString
        self.platform = platform
        self.state = state
        self.releaseType = releaseType
        self.earliestReleaseDate = earliestReleaseDate
        self.createdAt = createdAt
        self.build = build
    }

    public var phase: AppStoreVersionPhase { .from(state) }

    /// Only an approved version that waits for the developer can be released from here.
    public var canBeReleasedByOwner: Bool { phase == .pendingDeveloperRelease }

    public var platformTitle: String {
        AppStoreConnectVersion(versionString: versionString, platform: platform, state: state).platformTitle
    }

    public var releaseTypeTitle: String? {
        switch releaseType {
        case "MANUAL": L("Manual release")
        case "AFTER_APPROVAL": L("Automatic after approval")
        case "SCHEDULED": L("Scheduled")
        case let other?: other
        case nil: nil
        }
    }
}

/// One App Store app as read from App Store Connect.
public struct AppStoreAppStatus: Codable, Hashable, Sendable, Identifiable {
    public var app: ReleaseApp
    /// The App Store Connect app id, or nil when the account has no app with this bundle id.
    public var ascAppID: String?
    public var versions: [AppStoreVersionInfo]
    public var builds: [AppStoreBuildInfo]
    public var fetchedAt: Date
    public var error: String?

    public var id: String { app.id }

    public init(app: ReleaseApp, ascAppID: String?, versions: [AppStoreVersionInfo] = [], builds: [AppStoreBuildInfo] = [],
                fetchedAt: Date, error: String? = nil) {
        self.app = app
        self.ascAppID = ascAppID
        self.versions = versions
        self.builds = builds
        self.fetchedAt = fetchedAt
        self.error = error
    }

    public var platforms: [String] { Array(Set(versions.map(\.platform))).sorted() }

    private func newest(_ list: [AppStoreVersionInfo]) -> AppStoreVersionInfo? {
        list.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// The live version on one platform.
    public func live(platform: String) -> AppStoreVersionInfo? {
        newest(versions.filter { $0.platform == platform && $0.phase == .live })
    }

    /// The newest version on one platform that is neither live nor replaced: the one in progress.
    public func inProgress(platform: String) -> AppStoreVersionInfo? {
        let candidates = versions.filter { $0.platform == platform && $0.phase != .live && $0.phase != .historical }
        guard let v = newest(candidates) else { return nil }
        // A version older than the live one isn't "in progress" (it was abandoned).
        if let live = live(platform: platform), let a = v.createdAt, let b = live.createdAt, a < b { return nil }
        return v
    }

    public var endpoint: String { "App Store Connect API /v1/apps/\(ascAppID ?? "?")/appStoreVersions" }
}

// MARK: - Google Play

public enum PlayTrackStatus: String, Codable, Sendable {
    case completed, inProgress, halted, draft, unknown

    /// Edits API `status` values ("completed", "inProgress", "halted", "draft").
    public static func from(editStatus raw: String?) -> PlayTrackStatus {
        switch raw {
        case "completed": .completed
        case "inProgress": .inProgress
        case "halted": .halted
        case "draft": .draft
        default: .unknown
        }
    }

    /// releases.list `releaseLifecycleState`: it says less (no rollout fraction, no halted/in-progress split).
    public static func from(lifecycle raw: String) -> PlayTrackStatus {
        switch raw {
        case "RELEASE_LIFECYCLE_STATE_PUBLISHED": .completed
        case "RELEASE_LIFECYCLE_STATE_DRAFT": .draft
        default: .unknown
        }
    }

    public var title: String {
        switch self {
        case .completed: L("Rolled out")
        case .inProgress: L("Staged rollout")
        case .halted: L("Halted")
        case .draft: L("Draft")
        case .unknown: L("Unknown state")
        }
    }
}

/// One release on one Play track.
public struct PlayTrackRelease: Codable, Hashable, Sendable {
    public var name: String?
    public var versionCodes: [Int]
    public var status: PlayTrackStatus
    /// The raw state as Google sent it.
    public var rawStatus: String
    /// Share of users for a staged rollout (0...1); nil when not staged or not reported.
    public var userFraction: Double?
    /// Languages with release notes; nil when the read didn't include notes (releases.list).
    public var releaseNoteLanguages: [String]?

    public init(name: String?, versionCodes: [Int], status: PlayTrackStatus, rawStatus: String, userFraction: Double? = nil,
                releaseNoteLanguages: [String]? = nil) {
        self.name = name
        self.versionCodes = versionCodes
        self.status = status
        self.rawStatus = rawStatus
        self.userFraction = userFraction
        self.releaseNoteLanguages = releaseNoteLanguages
    }

    /// A draft with no version codes is Play's empty placeholder, not a release.
    public var isEmptyDraft: Bool { status == .draft && versionCodes.isEmpty }

    public var label: String {
        PlayRelease(releaseName: name, track: "", versionCodes: versionCodes, state: rawStatus).label
    }
}

public struct PlayTrackInfo: Codable, Hashable, Sendable, Identifiable {
    public var track: String
    public var releases: [PlayTrackRelease]

    public var id: String { track }

    public init(track: String, releases: [PlayTrackRelease]) {
        self.track = track
        self.releases = releases
    }

    /// production first, then the testing tracks from widest to narrowest, then custom tracks.
    static func order(_ track: String) -> Int {
        ["production": 0, "beta": 1, "alpha": 2, "internal": 3][track] ?? 4
    }
}

/// One Google Play app as read from the Play Developer API.
public struct PlayAppStatus: Codable, Hashable, Sendable, Identifiable {
    public enum Detail: String, Codable, Sendable {
        /// Read through an edit (never committed, deleted afterwards): status, rollout fraction and release notes.
        case edit
        /// Read through releases.list: version codes and published/draft only.
        case releasesList
    }

    public var app: ReleaseApp
    public var tracks: [PlayTrackInfo]
    public var detail: Detail
    public var fetchedAt: Date
    public var error: String?
    /// Why the edit read wasn't used, when it fell back to releases.list.
    public var detailNote: String?

    public var id: String { app.id }

    public init(app: ReleaseApp, tracks: [PlayTrackInfo], detail: Detail, fetchedAt: Date, error: String? = nil, detailNote: String? = nil) {
        self.app = app
        self.tracks = tracks.sorted { (PlayTrackInfo.order($0.track), $0.track) < (PlayTrackInfo.order($1.track), $1.track) }
        self.detail = detail
        self.fetchedAt = fetchedAt
        self.error = error
        self.detailNote = detailNote
    }

    public var endpoint: String {
        switch detail {
        case .edit: "Google Play Developer API applications/\(app.appIdentifier)/edits/{edit}/tracks (edit deleted, never committed)"
        case .releasesList: "Google Play Developer API applications/\(app.appIdentifier)/tracks/*/releases"
        }
    }
}

// MARK: - GitHub

/// The combined result of every workflow that ran for a commit (newest run of each workflow).
public enum CIRollup: String, Codable, Sendable {
    case success, failure, pending, none

    public var title: String {
        switch self {
        case .success: L("CI passing")
        case .failure: L("CI failing")
        case .pending: L("CI running")
        case .none: L("No CI runs")
        }
    }
}

public struct GitHubWorkflowRunInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var workflowID: Int?
    public var event: String?
    public var status: String
    public var conclusion: String?
    public var url: URL?
    public var createdAt: Date?
    public var headSHA: String?

    public init(id: Int, name: String, workflowID: Int? = nil, event: String? = nil, status: String, conclusion: String? = nil,
                url: URL? = nil, createdAt: Date? = nil, headSHA: String? = nil) {
        self.id = id
        self.name = name
        self.workflowID = workflowID
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.url = url
        self.createdAt = createdAt
        self.headSHA = headSHA
    }

    var isFailure: Bool { status == "completed" && ["failure", "timed_out", "startup_failure", "action_required"].contains(conclusion ?? "") }
    var isSuccessLike: Bool { status == "completed" && ["success", "skipped", "neutral"].contains(conclusion ?? "") }
}

extension CIRollup {
    /// Newest run of each workflow, then: any failure → failure; any still running → pending; all passed → success.
    /// GitHub's own Dependabot/Pages runs (event "dynamic") aren't the repository's CI and are ignored. A cancelled
    /// newest run counts as neither pass nor fail; if nothing else ran, the rollup is `.none`.
    public static func from(_ runs: [GitHubWorkflowRunInfo]) -> CIRollup {
        let ci = runs.filter { $0.event != "dynamic" }
        var newest: [String: GitHubWorkflowRunInfo] = [:]
        for run in ci {
            let key = run.workflowID.map(String.init) ?? run.name
            if let current = newest[key], (current.createdAt ?? .distantPast) >= (run.createdAt ?? .distantPast) { continue }
            newest[key] = run
        }
        let latest = Array(newest.values)
        if latest.contains(where: \.isFailure) { return .failure }
        if latest.contains(where: { $0.status != "completed" }) { return .pending }
        if latest.contains(where: \.isSuccessLike) { return .success }
        return .none
    }

    /// The newest run of each workflow, newest first (what the rollup was computed from).
    public static func latestPerWorkflow(_ runs: [GitHubWorkflowRunInfo]) -> [GitHubWorkflowRunInfo] {
        var newest: [String: GitHubWorkflowRunInfo] = [:]
        for run in runs where run.event != "dynamic" {
            let key = run.workflowID.map(String.init) ?? run.name
            if let current = newest[key], (current.createdAt ?? .distantPast) >= (run.createdAt ?? .distantPast) { continue }
            newest[key] = run
        }
        return newest.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}

public struct GitHubPullInfo: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var base: String
    public var head: String
    public var headSHA: String
    public var isDraft: Bool
    public var url: URL
    /// From the single-PR read; nil while GitHub is still computing it.
    public var mergeable: Bool?
    /// clean, unstable, blocked, behind, dirty, draft, has_hooks or unknown.
    public var mergeableState: String?
    public var isBot: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var ci: CIRollup
    public var ciRuns: [GitHubWorkflowRunInfo]

    public var id: Int { number }

    public init(number: Int, title: String, base: String, head: String, headSHA: String, isDraft: Bool = false, url: URL,
                mergeable: Bool? = nil, mergeableState: String? = nil, isBot: Bool = false, createdAt: Date? = nil,
                updatedAt: Date? = nil, ci: CIRollup = .none, ciRuns: [GitHubWorkflowRunInfo] = []) {
        self.number = number
        self.title = title
        self.base = base
        self.head = head
        self.headSHA = headSHA
        self.isDraft = isDraft
        self.url = url
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.isBot = isBot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ci = ci
        self.ciRuns = ciRuns
    }

    public var mergeableTitle: String {
        switch mergeableState {
        case "clean": L("Mergeable")
        case "unstable": L("Mergeable, some checks failing")
        case "has_hooks": L("Mergeable")
        case "blocked": L("Blocked by branch rules")
        case "behind": L("Behind its base branch")
        case "dirty": L("Has conflicts")
        case "draft": L("Draft")
        case "unknown", nil: L("GitHub is still checking")
        case let other?: other
        }
    }

    /// GitHub says it can be merged without conflicts and nothing blocks it.
    public var isCleanlyMergeable: Bool {
        !isDraft && mergeable == true && ["clean", "has_hooks"].contains(mergeableState ?? "")
    }
}

public struct GitHubReleaseRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case release, tag }
    public var kind: Kind
    public var tag: String
    public var name: String?
    public var publishedAt: Date?
    public var url: URL?

    public init(kind: Kind, tag: String, name: String? = nil, publishedAt: Date? = nil, url: URL? = nil) {
        self.kind = kind
        self.tag = tag
        self.name = name
        self.publishedAt = publishedAt
        self.url = url
    }
}

public struct RepoReleaseStatus: Codable, Hashable, Sendable, Identifiable {
    public var repo: ReleaseRepo
    public var defaultBranch: String?
    public var pulls: [GitHubPullInfo]
    public var mainCI: CIRollup
    public var mainRuns: [GitHubWorkflowRunInfo]
    /// The last published release, else the newest tag, else nil (none exists; `lastReleaseRead` says it was read).
    public var lastRelease: GitHubReleaseRef?
    public var lastReleaseRead: Bool
    public var fetchedAt: Date
    public var error: String?

    public var id: String { repo.id }

    public init(repo: ReleaseRepo, defaultBranch: String?, pulls: [GitHubPullInfo] = [], mainCI: CIRollup = .none,
                mainRuns: [GitHubWorkflowRunInfo] = [], lastRelease: GitHubReleaseRef? = nil, lastReleaseRead: Bool = false,
                fetchedAt: Date, error: String? = nil) {
        self.repo = repo
        self.defaultBranch = defaultBranch
        self.pulls = pulls
        self.mainCI = mainCI
        self.mainRuns = mainRuns
        self.lastRelease = lastRelease
        self.lastReleaseRead = lastReleaseRead
        self.fetchedAt = fetchedAt
        self.error = error
    }

    public var stacks: [PullStack] { PullStacks.detect(pulls, defaultBranch: defaultBranch ?? "main") }
}

// MARK: - Snapshot

/// Everything the Release Center last read, kept on this device (`release-center.json`) so the screen and the
/// Dashboard count show the last reading with its time after a relaunch. Never holds a credential.
public struct ReleaseCenterSnapshot: Codable, Hashable, Sendable {
    public var appStore: [AppStoreAppStatus]
    public var play: [PlayAppStatus]
    public var repos: [RepoReleaseStatus]
    public var appStoreReadAt: Date?
    public var playReadAt: Date?
    public var gitHubReadAt: Date?
    /// Why a whole source couldn't be read (no credentials, credentials unreadable).
    public var appStoreNote: String?
    public var playNote: String?
    public var gitHubNote: String?

    public init(appStore: [AppStoreAppStatus] = [], play: [PlayAppStatus] = [], repos: [RepoReleaseStatus] = [],
                appStoreReadAt: Date? = nil, playReadAt: Date? = nil, gitHubReadAt: Date? = nil,
                appStoreNote: String? = nil, playNote: String? = nil, gitHubNote: String? = nil) {
        self.appStore = appStore
        self.play = play
        self.repos = repos
        self.appStoreReadAt = appStoreReadAt
        self.playReadAt = playReadAt
        self.gitHubReadAt = gitHubReadAt
        self.appStoreNote = appStoreNote
        self.playNote = playNote
        self.gitHubNote = gitHubNote
    }

    public var waiting: [WaitingItem] { WaitingOnYou.items(self) }
}
