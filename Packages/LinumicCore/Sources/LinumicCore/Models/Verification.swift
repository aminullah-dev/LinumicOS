import Foundation

/// How well a fact is supported by evidence.
public enum VerificationStatus: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    /// A primary source states the fact directly (build config, GitHub API, store listing, owner).
    case verified
    /// Evidence supports part of the fact, or supports it only indirectly (e.g. a README claim).
    case partiallyVerified
    /// No evidence found yet.
    case unknown
    /// Sources disagree. Needs the owner's confirmation.
    case conflicting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .verified: L("Verified")
        case .partiallyVerified: L("Partially Verified")
        case .unknown: L("Unknown")
        case .conflicting: L("Conflicting")
        }
    }

    /// Order for "needs attention" sorting: conflicting first, verified last.
    private var attentionRank: Int {
        switch self {
        case .conflicting: 0
        case .unknown: 1
        case .partiallyVerified: 2
        case .verified: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.attentionRank < rhs.attentionRank }
}

/// Where a piece of evidence came from.
///
/// Local evidence is split by what was read, because a Gradle file or an Xcode project states a
/// platform directly while a README only claims it.
public enum SourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The Linumic owner said so (e.g. the initial product list, or a confirmation in the app).
    case ownerStatement
    /// Any other file on this Mac (README, docs), read without modification.
    /// The raw value predates the finer kinds below and is kept for stored inventories.
    case localRepository
    /// Git metadata of a local working copy (remote, branch, commits).
    case gitRepository
    /// Project configuration such as firebase.json, .firebaserc or deploy settings.
    case projectConfiguration
    /// An Xcode project or its XcodeGen spec.
    case xcodeProject
    /// A package manifest: package.json, pyproject.toml, pubspec.yaml, Package.swift…
    case packageManifest
    /// Android Gradle build configuration.
    case gradleConfiguration
    /// GitHub REST API (read-only).
    case gitHub
    /// A public web page.
    case website
    /// Apple's public App Store lookup or listing page.
    case appStore
    /// A public Google Play listing page, or the owner's Play Console.
    case googlePlay
    /// Anything that fits none of the above. Say what it is in the reference.
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ownerStatement: L("Owner")
        case .localRepository: L("Local file")
        case .gitRepository: L("Git repository")
        case .projectConfiguration: L("Project configuration")
        case .xcodeProject: L("Xcode project")
        case .packageManifest: L("Package manifest")
        case .gradleConfiguration: L("Gradle configuration")
        case .gitHub: L("GitHub")
        case .website: L("Website")
        case .appStore: L("App Store")
        case .googlePlay: L("Google Play")
        case .other: L("Other")
        }
    }

    /// Read from this Mac's filesystem.
    public var isLocal: Bool {
        [.localRepository, .gitRepository, .projectConfiguration, .xcodeProject, .packageManifest, .gradleConfiguration].contains(self)
    }

    /// A kind written by a newer version decodes as `.other` instead of failing the whole inventory.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceKind(rawValue: raw) ?? .other
    }
}

/// One piece of evidence: what kind, exactly where, and when it was observed.
public struct Source: Codable, Hashable, Sendable, Identifiable {
    public var kind: SourceKind
    /// A path, URL, or API endpoint precise enough for someone else to re-check.
    public var reference: String
    public var observedAt: Date
    /// What the source says, quoted or summarized.
    public var detail: String?

    public var id: String { "\(kind.rawValue)|\(reference)|\(observedAt.timeIntervalSince1970)" }

    // The registry's evidence vocabulary, over the stored fields.
    public var sourceType: SourceKind { kind }
    public var sourceReference: String { reference }
    public var observedValue: String? { detail }
    public var verifiedAt: Date { observedAt }

    /// Reference used when the owner confirms something inside the app.
    public static let ownerConfirmationReference = "Confirmed by the owner in Linumic OS"
    /// The same, as recorded before the product was renamed from "Linumic Command Center".
    public static let legacyOwnerConfirmationReferences: Set<String> = ["Confirmed by the owner in Linumic Command Center"]

    public init(kind: SourceKind, reference: String, observedAt: Date = .now, detail: String? = nil) {
        self.kind = kind
        self.reference = reference
        self.observedAt = observedAt
        self.detail = detail
    }
}

/// The verification state of a fact or relationship, with its evidence.
public struct Verification: Codable, Hashable, Sendable {
    public var status: VerificationStatus
    public var sources: [Source]
    public var verifiedAt: Date?
    public var notes: String

    public init(status: VerificationStatus, sources: [Source] = [], verifiedAt: Date? = nil, notes: String = "") {
        self.status = status
        self.sources = sources
        self.verifiedAt = verifiedAt
        self.notes = notes
    }

    public static let unknown = Verification(status: .unknown)

    public static func unknown(notes: String) -> Verification {
        Verification(status: .unknown, notes: notes)
    }

    /// Rule violations, e.g. "verified" without a source. Empty when consistent.
    public var issues: [String] {
        var result: [String] = []
        if status == .verified || status == .partiallyVerified {
            if sources.isEmpty { result.append("\(status.title) without any source") }
            if verifiedAt == nil { result.append("\(status.title) without a verification date") }
        }
        if status == .conflicting && sources.count < 2 && notes.isEmpty {
            result.append("Conflicting without the conflicting sources or a note explaining them")
        }
        return result
    }
}

/// A value together with the evidence for it. A `nil` value means unknown. Never fill it with a guess.
public struct Fact<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value?
    public var verification: Verification

    public init(_ value: Value?, _ verification: Verification) {
        self.value = value
        self.verification = verification
    }

    public static var unknown: Fact { Fact(nil, .unknown) }

    public static func unknown(notes: String) -> Fact { Fact(nil, .unknown(notes: notes)) }

    public var status: VerificationStatus { verification.status }

    /// Rule violations for this fact. Empty when consistent.
    public var issues: [String] {
        var result = verification.issues
        if value == nil && (status == .verified || status == .partiallyVerified) {
            result.append("\(status.title) but the value is empty")
        }
        if value != nil && status == .unknown {
            result.append("Has a value but is marked Unknown. Record its source, or clear it.")
        }
        return result
    }
}

public extension Array where Element == VerificationStatus {
    /// Roll-up of several statuses: any conflict wins, all verified is verified,
    /// nothing verified at all is unknown, anything else is partial.
    var rollUp: VerificationStatus {
        if isEmpty { return .unknown }
        if contains(.conflicting) { return .conflicting }
        if allSatisfy({ $0 == .verified }) { return .verified }
        if allSatisfy({ $0 == .unknown }) { return .unknown }
        return .partiallyVerified
    }
}
