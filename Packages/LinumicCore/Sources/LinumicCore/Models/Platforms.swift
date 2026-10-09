import Foundation

// Platforms hub: one place for every Linumic platform's versions, releases, CI and links.
//
// Two kinds of data, kept apart:
//   * `PlatformProfile` — reference facts written into the app with their source (where each product's
//     version lives, how it is sold, its admin and public links). See `PlatformCatalog`.
//   * `RepoReleaseTracking` — read-only GitHub observations, each stamped with the time it was read.
// Store versions are not duplicated here: they come from the inventory's store listings.

// MARK: - Reference facts

/// How a product reaches its customers.
public enum BusinessModel: String, Codable, Sendable, CaseIterable {
    /// Customers sign up and pay themselves (WorkTrack, Talar, SafeBeauty).
    case selfServe
    /// Sold with an offline LNM1 licence issued from the Licences screen (MediFlow, KhayatYar).
    case licence
    /// A free app people install from a store.
    case consumer
    /// Not recorded.
    case unknown

    public var title: String {
        switch self {
        case .selfServe: L("Self-serve sign-up")
        case .licence: L("Licence")
        case .consumer: L("Consumer app")
        case .unknown: L("Unknown")
        }
    }
}

/// Where a reference fact came from, and when it was last checked.
public struct CatalogSource: Codable, Hashable, Sendable {
    public var reference: String
    public var checkedAt: Date

    public init(_ reference: String, checkedAt: Date) {
        self.reference = reference
        self.checkedAt = checkedAt
    }
}

/// How to read the version out of a file on `main`.
public enum VersionFileFormat: Codable, Hashable, Sendable {
    /// Android `build.gradle(.kts)`: `versionName = "…"` and `versionCode = …` (first occurrence).
    case gradle
    /// A `key=value` properties file with the two keys named.
    case properties(nameKey: String, codeKey: String?)
    /// An XcodeGen `project.yml`: the target with this bundle identifier, falling back to the project-wide
    /// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
    case xcodegen(bundleID: String)
    /// `pyproject.toml`: `version = "…"`.
    case pyproject
    /// Flutter `pubspec.yaml`: `version: 1.0.0+1` (name + build).
    case pubspec
}

/// A version file on a repository's default branch.
public struct VersionFileSpec: Codable, Hashable, Sendable, Identifiable {
    /// `owner/name`.
    public var repo: String
    public var path: String
    public var format: VersionFileFormat
    /// What the version belongs to, e.g. "Android" or "iOS · VELRO Driver". Not translated (it's a label of record).
    public var component: String
    public var platform: Platform
    /// Bundle / application id, used to match the store listing for store drift.
    public var appIdentifier: String?
    /// The GitHub repository whose releases ship this component, when it is shipped that way.
    public var releaseRepo: String?
    /// Where this file was identified (report section, file:line).
    public var source: CatalogSource

    public var id: String { "\(repo)|\(path)|\(component)" }

    public init(repo: String, path: String, format: VersionFileFormat, component: String, platform: Platform,
                appIdentifier: String? = nil, releaseRepo: String? = nil, source: CatalogSource) {
        self.repo = repo
        self.path = path
        self.format = format
        self.component = component
        self.platform = platform
        self.appIdentifier = appIdentifier
        self.releaseRepo = releaseRepo
        self.source = source
    }
}

/// An admin console, sales page or other public address of a product.
public struct PlatformLink: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case admin, console, salesPage, productPage, website, download

        public var title: String {
            switch self {
            case .admin: L("Admin")
            case .console: L("Console")
            case .salesPage: L("Sales page")
            case .productPage: L("Product page")
            case .website: L("Website")
            case .download: L("Download page")
            }
        }

        /// Admin-side addresses are grouped apart from public ones.
        public var isAdmin: Bool { self == .admin || self == .console }
    }

    public var kind: Kind
    /// Shown as is (a name of record, e.g. "SafeBeauty · Salon Console").
    public var title: String
    public var url: URL
    public var source: CatalogSource

    public var id: String { url.absoluteString }

    public init(kind: Kind, title: String, url: URL, source: CatalogSource) {
        self.kind = kind
        self.title = title
        self.url = url
        self.source = source
    }
}

/// Reference facts for one product in the hub, keyed to an existing inventory product.
public struct PlatformProfile: Hashable, Sendable, Identifiable {
    public var productID: String
    /// The name the hub shows, e.g. "Tailor ERP / KhayatYar" for the AfghanJama record.
    public var title: String
    public var businessModel: BusinessModel
    public var businessModelSource: CatalogSource
    /// The licence product, for licence-model products (links to the Licences screen with counts).
    public var licenceProduct: LicenceProduct?
    public var versionFiles: [VersionFileSpec]
    public var links: [PlatformLink]
    /// Something the owner should know about this product's tracking, e.g. that no version file exists on main.
    public var trackingNote: String?

    public var id: String { productID }

    public init(productID: String, title: String, businessModel: BusinessModel, businessModelSource: CatalogSource,
                licenceProduct: LicenceProduct? = nil, versionFiles: [VersionFileSpec] = [], links: [PlatformLink] = [],
                trackingNote: String? = nil) {
        self.productID = productID
        self.title = title
        self.businessModel = businessModel
        self.businessModelSource = businessModelSource
        self.licenceProduct = licenceProduct
        self.versionFiles = versionFiles
        self.links = links
        self.trackingNote = trackingNote
    }
}

// MARK: - GitHub observations

/// A published GitHub release (drafts are never included).
public struct GitHubRelease: Codable, Hashable, Sendable, Identifiable {
    public struct Asset: Codable, Hashable, Sendable {
        public var name: String
        public var downloadCount: Int
        public var url: URL?

        public init(name: String, downloadCount: Int, url: URL? = nil) {
            self.name = name
            self.downloadCount = downloadCount
            self.url = url
        }
    }

    public var tag: String
    public var name: String?
    public var publishedAt: Date?
    public var isPrerelease: Bool
    public var url: URL?
    public var assets: [Asset]

    public var id: String { tag }
    public var totalDownloads: Int { assets.reduce(0) { $0 + $1.downloadCount } }
    /// The tag as a version (`v1.8.0` → 1.8.0), or nil when the tag isn't a version number (e.g. `android-app`).
    public var version: SemanticVersion? { SemanticVersion(tag) }

    public init(tag: String, name: String? = nil, publishedAt: Date? = nil, isPrerelease: Bool = false, url: URL? = nil, assets: [Asset] = []) {
        self.tag = tag
        self.name = name
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.url = url
        self.assets = assets
    }
}

/// One GitHub Actions workflow and its latest run on the default branch.
public struct WorkflowStatus: Codable, Hashable, Sendable, Identifiable {
    public struct Run: Codable, Hashable, Sendable {
        public var status: String
        public var conclusion: String?
        public var createdAt: Date?
        public var url: URL?
        public var headSHA: String?
        public var event: String?

        public init(status: String, conclusion: String? = nil, createdAt: Date? = nil, url: URL? = nil, headSHA: String? = nil, event: String? = nil) {
            self.status = status
            self.conclusion = conclusion
            self.createdAt = createdAt
            self.url = url
            self.headSHA = headSHA
            self.event = event
        }

        public var outcome: RepositorySnapshot.CIConclusion {
            if status != "completed" { return .inProgress }
            switch conclusion {
            case "success": return .success
            case "failure", "timed_out", "startup_failure": return .failure
            case "cancelled": return .cancelled
            default: return .none
            }
        }
    }

    public var id: Int
    public var name: String
    public var path: String
    /// `nil` when the workflow has never run on the default branch (e.g. manual-only, or other branches only).
    public var latestRun: Run?

    public init(id: Int, name: String, path: String, latestRun: Run? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.latestRun = latestRun
    }
}

/// The version read from one file on the default branch.
public struct VersionReading: Codable, Hashable, Sendable {
    public var specID: String
    public var repo: String
    public var path: String
    /// The branch the file was read from.
    public var ref: String
    public var versionName: String?
    public var versionCode: String?
    /// 1-based line of the version name in the file, for the source reference.
    public var line: Int?
    /// Why nothing could be read, if so.
    public var error: String?
    public var fetchedAt: Date

    public init(specID: String, repo: String, path: String, ref: String, versionName: String? = nil, versionCode: String? = nil,
                line: Int? = nil, error: String? = nil, fetchedAt: Date) {
        self.specID = specID
        self.repo = repo
        self.path = path
        self.ref = ref
        self.versionName = versionName
        self.versionCode = versionCode
        self.line = line
        self.error = error
        self.fetchedAt = fetchedAt
    }

    /// "1.3.0 (6)", "1.9.0", or nil.
    public var label: String? {
        guard let versionName else { return nil }
        return versionCode.map { "\(versionName) (\($0))" } ?? versionName
    }

    /// e.g. `aminullah-dev/WorkTrack app/build.gradle.kts:92 @ main`.
    public var sourceReference: String {
        "\(repo) \(path)\(line.map { ":\($0)" } ?? "") @ \(ref)"
    }
}

/// Everything the hub read about one repository, in one refresh.
public struct RepoReleaseTracking: Codable, Hashable, Sendable, Identifiable {
    public enum LatestRelease: Codable, Hashable, Sendable {
        case release(GitHubRelease)
        /// `/releases/latest` answered 404: the repository has no published (non-prerelease) release.
        case none
    }

    public var slug: String
    public var defaultBranch: String?
    /// `nil` until read; `.none` when GitHub says there is no release.
    public var latestRelease: LatestRelease?
    /// Newest first, at most 10.
    public var recentReleases: [GitHubRelease]
    /// Workflows defined in `.github/workflows/` (GitHub's built-in dynamic workflows are left out).
    public var workflows: [WorkflowStatus]?
    public var openPullRequests: Int?
    public var versions: [VersionReading]
    /// Parts that could not be read this time (the rest is still current).
    public var problems: [String]
    /// When the refresh last failed entirely, and why. The previous data is kept.
    public var error: String?
    public var fetchedAt: Date

    public var id: String { slug }

    public init(slug: String, defaultBranch: String? = nil, latestRelease: LatestRelease? = nil, recentReleases: [GitHubRelease] = [],
                workflows: [WorkflowStatus]? = nil, openPullRequests: Int? = nil, versions: [VersionReading] = [],
                problems: [String] = [], error: String? = nil, fetchedAt: Date) {
        self.slug = slug
        self.defaultBranch = defaultBranch
        self.latestRelease = latestRelease
        self.recentReleases = recentReleases
        self.workflows = workflows
        self.openPullRequests = openPullRequests
        self.versions = versions
        self.problems = problems
        self.error = error
        self.fetchedAt = fetchedAt
    }

    public var release: GitHubRelease? {
        if case .release(let r) = latestRelease { return r }
        return nil
    }

    public var failingWorkflows: [WorkflowStatus] {
        (workflows ?? []).filter { $0.latestRun?.outcome == .failure }
    }
}

// MARK: - Versions

/// A dotted numeric version (`1.2.3`, `v1.8.0`, `1.0.0+1`). Anything else isn't a version and parses as nil,
/// so a drift is only ever computed between two real version numbers.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }  // build metadata
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 5 else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCIIDigitCharacter), let n = Int(p) else { return nil }
            numbers.append(n)
        }
        components = numbers
    }

    /// The single version number inside a store label such as "8 (1.2.4)" or "iOS 1.0, macOS 1.0".
    /// Nil when there is none, or when the label holds two different versions (then a comparison would be a guess).
    public static func single(in label: String?) -> SemanticVersion? {
        guard let label else { return nil }
        let pattern = #/\d+(?:\.\d+)+/#
        let found = Set(label.matches(of: pattern).compactMap { SemanticVersion(String($0.output)) })
        return found.count == 1 ? found.first : nil
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// Reads a version name and code out of a version file's text. Pure, so it is tested against real file shapes.
public enum VersionFileParser {
    public struct Result: Equatable, Sendable {
        public var name: String?
        public var code: String?
        public var line: Int?
    }

    public static func parse(_ text: String, format: VersionFileFormat) -> Result {
        let lines = text.components(separatedBy: "\n")
        switch format {
        case .gradle:
            let name = firstMatch(lines, #/^\s*versionName\s*=?\s*"([^"]+)"/#)
            let code = firstMatch(lines, #/^\s*versionCode\s*=?\s*(\d+)/#)
            return Result(name: name?.value, code: code?.value, line: name?.line)
        case .properties(let nameKey, let codeKey):
            let name = property(lines, nameKey)
            let code = codeKey.flatMap { property(lines, $0) }
            return Result(name: name?.value, code: code?.value, line: name?.line)
        case .pyproject:
            let name = firstMatch(lines, #/^\s*version\s*=\s*"([^"]+)"/#)
            return Result(name: name?.value, code: nil, line: name?.line)
        case .pubspec:
            guard let v = firstMatch(lines, #/^version:\s*["']?([^"'\s#]+)/#) else { return Result() }
            let parts = v.value.split(separator: "+", maxSplits: 1).map(String.init)
            return Result(name: parts[0], code: parts.count > 1 ? parts[1] : nil, line: v.line)
        case .xcodegen(let bundleID):
            return xcodegen(lines, bundleID: bundleID)
        }
    }

    private static func firstMatch(_ lines: [String], _ regex: Regex<(Substring, Substring)>) -> (value: String, line: Int)? {
        for (i, line) in lines.enumerated() {
            if let m = line.firstMatch(of: regex) { return (String(m.output.1), i + 1) }
        }
        return nil
    }

    private static func property(_ lines: [String], _ key: String) -> (value: String, line: Int)? {
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("!"), let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : (value, i + 1)
            }
        }
        return nil
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// `KEY: value  # comment` → value without quotes.
    private static func yamlValue(_ line: String, key: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(key + ":") else { return nil }
        var v = String(t.dropFirst(key.count + 1))
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return v.isEmpty ? nil : v
    }

    /// The bundle's own settings block wins; otherwise the least-indented (project-wide) setting.
    private static func xcodegen(_ lines: [String], bundleID: String) -> Result {
        func projectWide(_ key: String) -> (value: String, line: Int)? {
            var best: (value: String, line: Int, indent: Int)?
            for (i, line) in lines.enumerated() {
                guard let v = yamlValue(line, key: key), !v.hasPrefix("$") else { continue }
                let n = indent(line)
                if best == nil || n < best!.indent { best = (v, i + 1, n) }
            }
            return best.map { ($0.value, $0.line) }
        }
        guard let idIndex = lines.firstIndex(where: { yamlValue($0, key: "PRODUCT_BUNDLE_IDENTIFIER") == bundleID }) else {
            return Result()   // the bundle isn't in this file: don't fall back to someone else's version
        }
        let level = indent(lines[idIndex])
        func sibling(_ key: String) -> (value: String, line: Int)? {
            // Walk up and down through lines that belong to the same settings block.
            for range in [Array((0..<idIndex).reversed()), Array((idIndex + 1)..<lines.count)] {
                for i in range {
                    let line = lines[i]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    let n = indent(line)
                    if n < level { break }
                    if n == level, let v = yamlValue(line, key: key), !v.hasPrefix("$") { return (v, i + 1) }
                }
            }
            return nil
        }
        let name = sibling("MARKETING_VERSION") ?? projectWide("MARKETING_VERSION")
        let code = sibling("CURRENT_PROJECT_VERSION") ?? projectWide("CURRENT_PROJECT_VERSION")
        return Result(name: name?.value, code: code?.value, line: name?.line)
    }
}
