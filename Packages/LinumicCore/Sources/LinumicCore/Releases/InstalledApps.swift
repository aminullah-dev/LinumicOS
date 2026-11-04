import Foundation

// MARK: - Installed on this Mac, against the newest release
//
// On 2026-11-03 the owner's Mac held KhayatYar 1.12.1, a test build, in /Applications while tag v1.13.0 already existed,
// and nobody noticed until a customer build was made. This compares the app in /Applications with the newest release of
// its product: current, behind (and by which release), a build newer than every release (or of a product with none yet),
// a test build (the app says it was not built from the release's tag), not installed, or unknown and why.
//
// It reads an app's Info.plist and nothing else of it: the app is never run and its data is never opened. The newest
// release comes from the GitHub tags and releases the Release Center already reads. Everything below is pure, so the
// rules are tested without the app; the App only lists /Applications and reads the files (`LocalInstalledAppFiles`).

/// A product's Mac app that Linumic OS looks for in /Applications.
public struct InstalledAppSpec: Hashable, Sendable, Identifiable {
    /// The product's platform in `ProductsCatalog` ("khayatyar.app.macOS").
    public var slotID: String
    /// `CompanyProduct.id`.
    public var productID: String
    /// The app's name, as recorded (a name of record, not translated).
    public var name: String
    /// What the Info.plist at `path` must say (`CFBundleIdentifier`); another app there is never compared.
    public var bundleID: String
    /// The app's folder in /Applications ("KhayatYar.app").
    public var bundleName: String
    /// The repository whose version tags and GitHub releases are the product's releases.
    public var repo: String
    /// Where this entry comes from.
    public var source: String

    public var id: String { slotID }

    public init(slotID: String, productID: String, name: String, bundleID: String, bundleName: String, repo: String, source: String) {
        self.slotID = slotID
        self.productID = productID
        self.name = name
        self.bundleID = bundleID
        self.bundleName = bundleName
        self.repo = repo
        self.source = source
    }

    public static let folder = "/Applications"
    public var path: String { "\(Self.folder)/\(bundleName)" }
    public var infoPlistPath: String { "\(path)/Contents/Info.plist" }
}

public enum InstalledAppCatalog {
    /// An app may say how it was built in its Info.plist: `LinumicBuildChannel` ("release" only when built from its version
    /// tag with nothing uncommitted, anything else is a test build) and `LinumicBuildCommit` (the commit it was built from).
    /// Without them a build of the release's version can't be told from a test build of the same version, and it is
    /// shown as such, never as current.
    public static let channelKey = "LinumicBuildChannel"
    public static let commitKey = "LinumicBuildCommit"
    /// The channel of a build made from its version tag.
    public static let releaseChannel = "release"

    /// The products' Mac apps whose releases are GitHub tags. VELRO Ops and the WorkTrack console shell are not here:
    /// their releases are a store version and an unversioned deploy, not a tag.
    public static let apps: [InstalledAppSpec] = [
        // KhayatYar compiles its channel and commit into the app (BuildInfo, from core/build.gradle.kts:132,145 in
        // aminullah-dev/AfghanJama), not into the Info.plist, so a test build of the newest version reads as "same version".
        InstalledAppSpec(slotID: "khayatyar.app.macOS", productID: "khayatyar", name: "KhayatYar", bundleID: "com.afghanjama.khayatyar",
                         bundleName: "KhayatYar.app", repo: "aminullah-dev/AfghanJama",
                         source: "CFBundleIdentifier in /Applications/KhayatYar.app/Contents/Info.plist (read 2026-11-04); releases are the tags v<version> (AfghanJama core/build.gradle.kts:132)"),
        InstalledAppSpec(slotID: "linumicos.app.macOS", productID: "linumicos", name: "Linumic OS", bundleID: "com.linumic.commandcenter",
                         bundleName: "LinumicOS.app", repo: "aminullah-dev/LinumicOS",
                         source: "project.yml in this repository (PRODUCT_BUNDLE_IDENTIFIER, PRODUCT_NAME)"),
        InstalledAppSpec(slotID: "mediflow.app.macOS", productID: "mediflow", name: "MediFlow", bundleID: "com.mediflow.mediflow",
                         bundleName: "MediFlow.app", repo: "aminullah-dev/MediFlow",
                         source: "CFBundleIdentifier in /Applications/MediFlow.app/Contents/Info.plist (read 2026-11-04); releases are the tags v<version> on GitHub"),
    ]

    public static func apps(forProduct id: String) -> [InstalledAppSpec] { apps.filter { $0.productID == id } }
}

// MARK: Reading the Info.plist

/// The parts of an app's Info.plist that are compared. Nothing else is kept.
public struct InstalledAppInfo: Hashable, Sendable {
    public var bundleID: String?
    /// `CFBundleShortVersionString`.
    public var version: String?
    /// `CFBundleVersion`.
    public var build: String?
    /// `LinumicBuildChannel`, when the app records it.
    public var channel: String?
    /// `LinumicBuildCommit`, when the app records it.
    public var commit: String?

    public init(bundleID: String?, version: String?, build: String? = nil, channel: String? = nil, commit: String? = nil) {
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.channel = channel
        self.commit = commit
    }

    /// An Info.plist, XML or binary. Throws when it is not a property-list dictionary.
    public static func parse(_ data: Data) throws -> InstalledAppInfo {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        func text(_ key: String) -> String? {
            let value = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        return InstalledAppInfo(bundleID: text("CFBundleIdentifier"), version: text("CFBundleShortVersionString"), build: text("CFBundleVersion"),
                                channel: text(InstalledAppCatalog.channelKey), commit: text(InstalledAppCatalog.commitKey))
    }

    /// "1.13.0", "0.3.0 (3)": the build only when it says something the version doesn't.
    public var label: String {
        let v = version ?? "?"
        guard let build, build != version else { return v }
        return "\(v) (\(build))"
    }
}

/// Where the reader looks. The App lists /Applications and reads one file per app; tests give a folder of their own.
public protocol InstalledAppFileSystem: Sendable {
    /// The names in a folder; throws when it can't be listed.
    func names(in folder: String) throws -> [String]
    func contents(of path: String) throws -> Data
}

/// This Mac's files, through FileManager. Linumic OS's App Sandbox lets it list /Applications and read an app's
/// Info.plist with no added entitlement (checked 2026-11-04 with the app's own entitlements, see docs/security.md).
public struct LocalInstalledAppFiles: InstalledAppFileSystem {
    public init() {}
    public func names(in folder: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder) }
    public func contents(of path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
}

public enum InstalledAppReader {
    /// Each spec's app as /Applications holds it, keyed by spec id. An app is "not installed" only when /Applications was
    /// listed and its folder is not there; when the folder can't be listed, every app is unknown.
    public static func read(_ specs: [InstalledAppSpec] = InstalledAppCatalog.apps, using files: InstalledAppFileSystem,
                            now: Date) -> [String: Sourced<InstalledAppInfo>] {
        let names: Set<String>
        do {
            names = Set(try files.names(in: InstalledAppSpec.folder).map { $0.lowercased() })
        } catch {
            let why = LF("Could not look in /Applications: %@", error.localizedDescription)
            return Dictionary(uniqueKeysWithValues: specs.map { ($0.id, .unknown(why)) })
        }
        var out: [String: Sourced<InstalledAppInfo>] = [:]
        for spec in specs {
            guard names.contains(spec.bundleName.lowercased()) else {
                out[spec.id] = .none(L("Not installed in /Applications on this Mac."), source: InstalledAppSpec.folder, readAt: now)
                continue
            }
            let info: InstalledAppInfo
            do {
                info = try InstalledAppInfo.parse(try files.contents(of: spec.infoPlistPath))
            } catch {
                out[spec.id] = .unknown(LF("%1$@ is in /Applications, but its Info.plist could not be read: %2$@", spec.bundleName, error.localizedDescription))
                continue
            }
            guard info.bundleID == spec.bundleID else {
                out[spec.id] = .unknown(LF("%1$@ is another app (%2$@), so it is not compared.", spec.path, info.bundleID ?? "?"))
                continue
            }
            out[spec.id] = .known(info, source: spec.infoPlistPath, readAt: now)
        }
        return out
    }
}

// MARK: The newest release

/// The newest release of a product: the highest version among its repository's version tags and its latest GitHub release.
public struct ReleaseMark: Hashable, Sendable {
    public var tag: String
    public var version: SemanticVersion
    /// A published GitHub release, or a tag with no release.
    public var kind: GitHubReleaseRef.Kind
    /// The commit the tag points at, when the tags were read.
    public var commit: String?
    public var url: URL?
    public var publishedAt: Date?
    /// False when only the latest release was read, not the tags: a newer tag may exist.
    public var complete: Bool

    public init(tag: String, version: SemanticVersion, kind: GitHubReleaseRef.Kind, commit: String? = nil, url: URL? = nil,
                publishedAt: Date? = nil, complete: Bool) {
        self.tag = tag
        self.version = version
        self.kind = kind
        self.commit = commit
        self.url = url
        self.publishedAt = publishedAt
        self.complete = complete
    }

    /// "v1.13.0 (tag, no GitHub release)", "v0.2.0 (GitHub release)".
    public var label: String {
        kind == .release ? LF("%@ (GitHub release)", tag) : LF("%@ (tag, no GitHub release)", tag)
    }
}

// MARK: The comparison

/// How the app was built, as far as the app says.
public enum InstalledBuildKind: Hashable, Sendable {
    /// From the release's tag: its channel is "release", or its commit is the tag's.
    case fromTag
    /// Not from the release's tag; the sentence says how that is known.
    case test(String)
    /// The app does not record it.
    case notRecorded

    public var isTest: Bool { if case .test = self { true } else { false } }
}

public enum InstalledVerdict: Hashable, Sendable {
    /// The newest release's version, built from its tag.
    case current(release: String)
    /// The newest release's version; the app does not record whether it was built from that tag, so it is not called current.
    case sameVersion(release: String)
    /// Older than the newest release.
    case behind(installed: String, release: String, testBuild: Bool)
    /// The newest release's version, but not built from its tag.
    case testBuild(installed: String, release: String, why: String)
    /// Newer than the newest release, or the product has no release yet (`release` nil).
    case unreleased(installed: String, release: String?)
    case notInstalled
    case unknown(String)

    /// Behind or a test build: the owner installs the release. Shown on the Center.
    public var needsOwner: Bool {
        switch self {
        case .behind, .testBuild: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .current: L("Current")
        case .sameVersion: L("Same version")
        case .behind: L("Behind")
        case .testBuild: L("Test build")
        case .unreleased: L("Unreleased build")
        case .notInstalled: L("Not installed")
        case .unknown: L("Unknown")
        }
    }

    /// One sentence that says what is installed against what.
    public var sentence: String {
        switch self {
        case .current(let release):
            LF("The newest release, %@, built from its tag.", release)
        case .sameVersion(let release):
            LF("The version of the newest release, %@. The app does not record whether it was built from that tag.", release)
        case .behind(let installed, let release, let test):
            test ? LF("%1$@, a test build, is behind the newest release, %2$@.", installed, release)
                 : LF("%1$@ is behind the newest release, %2$@.", installed, release)
        case .testBuild(let installed, let release, let why):
            LF("%1$@ is the version of %2$@, but not built from that tag: %3$@", installed, release, why)
        case .unreleased(let installed, let release?):
            LF("%1$@ is newer than the newest release, %2$@: a build that was not released.", installed, release)
        case .unreleased(let installed, nil):
            LF("%@ is installed, and the repository has no release or version tag yet.", installed)
        case .notInstalled:
            L("Not installed in /Applications on this Mac.")
        case .unknown(let why):
            why
        }
    }
}

/// One app: what is installed, the newest release, and the verdict.
public struct InstalledAppStatus: Hashable, Sendable, Identifiable {
    public var spec: InstalledAppSpec
    public var installed: Sourced<InstalledAppInfo>
    public var newest: Sourced<ReleaseMark>
    public var verdict: InstalledVerdict

    public var id: String { spec.id }

    public init(spec: InstalledAppSpec, installed: Sourced<InstalledAppInfo>, newest: Sourced<ReleaseMark>, verdict: InstalledVerdict) {
        self.spec = spec
        self.installed = installed
        self.newest = newest
        self.verdict = verdict
    }

    /// The Center's line: "KhayatYar on this Mac is 1.12.1, behind v1.13.0".
    public var centerLine: String {
        switch verdict {
        case .behind(let installed, let release, let test):
            test ? LF("%1$@ on this Mac is %2$@, a test build, behind %3$@", spec.name, installed, release)
                 : LF("%1$@ on this Mac is %2$@, behind %3$@", spec.name, installed, release)
        case .testBuild(_, let release, _):
            LF("%1$@ on this Mac is a test build of %2$@", spec.name, release)
        default:
            spec.name
        }
    }
}

public enum InstalledAppCheck {
    /// The newest release of `repo` from the Release Center's reading: the highest version among its version tags and its
    /// latest GitHub release. Without the tags (a reading from before they were read), only a release older than what is
    /// installed can be used; the comparison says what that can't tell.
    public static func newestRelease(of repo: String, in snapshot: ReleaseCenterSnapshot) -> Sourced<ReleaseMark> {
        guard let status = snapshot.repos.first(where: { $0.repo.slug.caseInsensitiveCompare(repo) == .orderedSame }) else {
            return .unknown(LF("Releases has not read %@ yet.", repo))
        }
        if let error = status.error {
            return .unknown(LF("Releases could not read %1$@: %2$@", repo, error))
        }
        let tagsRead = status.versionTags != nil
        var candidates: [ReleaseMark] = []
        if let r = status.lastRelease, let v = SemanticVersion(r.tag) {
            candidates.append(ReleaseMark(tag: r.tag, version: v, kind: r.kind, commit: r.commit, url: r.url, publishedAt: r.publishedAt,
                                          complete: tagsRead))
        }
        if let t = status.versionTags?.newest, let v = SemanticVersion(t.tag) {
            candidates.append(ReleaseMark(tag: t.tag, version: v, kind: .tag, commit: t.commit, url: t.url, complete: true))
        }
        let source = tagsRead ? LF("GitHub tags and releases of %@", repo) : LF("GitHub releases of %@", repo)
        guard var best = candidates.max(by: { $0.version < $1.version }) else {
            return tagsRead ? .none(LF("%@ has no release and no version tag.", repo), source: source, readAt: status.fetchedAt)
                            : .unknown(LF("The tags of %@ were not read yet.", repo))
        }
        // The same version as a published release and as a tag: the release, with the tag's commit.
        for c in candidates where c.version == best.version {
            if c.kind == .release, best.kind == .tag {
                let commit = best.commit
                best = c
                best.commit = best.commit ?? commit
            } else if best.commit == nil {
                best.commit = c.commit
            }
        }
        best.complete = tagsRead
        return .known(best, source: source, readAt: status.fetchedAt)
    }

    /// How the app was built, from what it records. `sameVersion`: whether the installed version is the release's (a
    /// commit is compared only then; the tag of another version says nothing about this build).
    public static func buildKind(_ info: InstalledAppInfo, release: ReleaseMark?, sameVersion: Bool) -> InstalledBuildKind {
        if let channel = info.channel, channel.lowercased() != InstalledAppCatalog.releaseChannel {
            return .test(LF("its build channel is “%@”.", channel))
        }
        if sameVersion, let release, let built = commit(info.commit), let tagged = commit(release.commit) {
            let same = built.hasPrefix(tagged) || tagged.hasPrefix(built)
            return same ? .fromTag : .test(LF("it was built from commit %1$@, and %2$@ is commit %3$@.", String(built.prefix(7)), release.tag,
                                                String(tagged.prefix(7))))
        }
        return info.channel != nil ? .fromTag : .notRecorded
    }

    /// A commit id of at least seven hex digits, lowercased; anything else ("local", "") says nothing.
    static func commit(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), t.count >= 7, t.count <= 64,
              t.allSatisfy(\.isHexDigit) else { return nil }
        return t
    }

    /// The verdict. Unknown is never turned into current: an unread Info.plist, a version that is not a number or a
    /// release that was not read stay unknown, with why.
    public static func compare(installed: Sourced<InstalledAppInfo>, newest: Sourced<ReleaseMark>) -> InstalledVerdict {
        let info: InstalledAppInfo
        switch installed {
        case .unknown(let why): return .unknown(why)
        case .none: return .notInstalled
        case .known(let i, _, _): info = i
        }
        guard let raw = info.version else {
            return .unknown(L("The app's Info.plist has no version (CFBundleShortVersionString)."))
        }
        guard let version = SemanticVersion(raw) else {
            return .unknown(LF("The app's version “%@” is not a version number, so it is not compared.", raw))
        }
        let release: ReleaseMark
        switch newest {
        case .unknown(let why): return .unknown(why)
        case .none: return .unreleased(installed: raw, release: nil)
        case .known(let r, _, _): release = r
        }
        if version < release.version {
            return .behind(installed: raw, release: release.tag, testBuild: buildKind(info, release: release, sameVersion: false).isTest)
        }
        // Equal or newer, but a newer tag than the release read may exist: that can't be told.
        guard release.complete else {
            return .unknown(LF("Only the GitHub release %@ was read, not the tags, so a newer tag may exist.", release.tag))
        }
        if release.version < version {
            return .unreleased(installed: raw, release: release.tag)
        }
        switch buildKind(info, release: release, sameVersion: true) {
        case .fromTag: return .current(release: release.tag)
        case .test(let why): return .testBuild(installed: raw, release: release.tag, why: why)
        case .notRecorded: return .sameVersion(release: release.tag)
        }
    }

    /// Every spec's status, in the catalog's order. `installed` is `InstalledAppReader.read`'s result; a spec missing
    /// from it was not checked (an iPhone or iPad has no /Applications to read).
    public static func statuses(_ specs: [InstalledAppSpec] = InstalledAppCatalog.apps, installed: [String: Sourced<InstalledAppInfo>],
                                releases: ReleaseCenterSnapshot) -> [InstalledAppStatus] {
        specs.map { spec in
            let app = installed[spec.id] ?? .unknown(L("/Applications was not read on this device."))
            let newest = newestRelease(of: spec.repo, in: releases)
            return InstalledAppStatus(spec: spec, installed: app, newest: newest, verdict: compare(installed: app, newest: newest))
        }
    }
}
