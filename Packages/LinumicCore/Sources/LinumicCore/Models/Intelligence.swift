import Foundation

// MARK: - Market intelligence
//
// Rules (docs/market-intelligence.md): every evidence item names its source and when it was
// collected, and every finding points at evidence. Derived findings state their method.
// Nothing here is generated. It all starts from what a person records.

public enum MarketSourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case dataset, publication, news, survey, interview, customerFeedback, productRequest
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dataset: L("Dataset")
        case .publication: L("Publication")
        case .news: L("News")
        case .survey: L("Survey")
        case .interview: L("Interview")
        case .customerFeedback: L("Customer feedback")
        case .productRequest: L("Product request")
        }
    }
}

public struct MarketSource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: MarketSourceKind
    public var publisher: String?
    public var url: URL?
    public var language: String?
    /// Why this source can (or can't) be trusted, and any terms-of-use limits.
    public var reliabilityNote: String

    public init(id: UUID = UUID(), name: String, kind: MarketSourceKind, publisher: String? = nil, url: URL? = nil, language: String? = nil, reliabilityNote: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.publisher = publisher
        self.url = url
        self.language = language
        self.reliabilityNote = reliabilityNote
    }
}

/// One observation taken from a source: a quote, a figure or a request, as it was found.
public struct MarketEvidence: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var excerpt: String
    public var publishedAt: Date?
    public var collectedAt: Date
    public var region: String?
    public var sector: String?
    public var language: String?
    public var tags: [String]

    public init(id: UUID = UUID(), sourceID: UUID, excerpt: String, publishedAt: Date? = nil, collectedAt: Date = .now,
                region: String? = nil, sector: String? = nil, language: String? = nil, tags: [String] = []) {
        self.id = id
        self.sourceID = sourceID
        self.excerpt = excerpt
        self.publishedAt = publishedAt
        self.collectedAt = collectedAt
        self.region = region
        self.sector = sector
        self.language = language
        self.tags = tags
    }
}

public enum FindingKind: String, Codable, CaseIterable, Sendable {
    /// Stated directly by the evidence.
    case verified
    /// An interpretation of the evidence. The method must be stated.
    case derived
    public var title: String { self == .verified ? L("Verified") : L("Derived") }
}

public struct MarketFinding: Codable, Hashable, Sendable, Identifiable {
    public enum Review: String, Codable, CaseIterable, Sendable {
        case draft, reviewed
        public var title: String { L(rawValue.capitalized) }
    }

    public var id: UUID
    public var statement: String
    public var kind: FindingKind
    public var evidenceIDs: [UUID]
    public var method: String
    public var productIDs: [String]
    public var review: Review
    public var createdAt: Date
    public var createdBy: String

    public init(id: UUID = UUID(), statement: String, kind: FindingKind, evidenceIDs: [UUID], method: String = "",
                productIDs: [String] = [], review: Review = .draft, createdAt: Date = .now, createdBy: String = "Owner") {
        self.id = id
        self.statement = statement
        self.kind = kind
        self.evidenceIDs = evidenceIDs
        self.method = method
        self.productIDs = productIDs
        self.review = review
        self.createdAt = createdAt
        self.createdBy = createdBy
    }
}

public struct MarketIntelligence: Codable, Hashable, Sendable {
    public var sources: [MarketSource]
    public var evidence: [MarketEvidence]
    public var findings: [MarketFinding]

    public init(sources: [MarketSource] = [], evidence: [MarketEvidence] = [], findings: [MarketFinding] = []) {
        self.sources = sources
        self.evidence = evidence
        self.findings = findings
    }

    public func source(for evidence: MarketEvidence) -> MarketSource? { sources.first { $0.id == evidence.sourceID } }
    public func evidence(for finding: MarketFinding) -> [MarketEvidence] { evidence.filter { finding.evidenceIDs.contains($0.id) } }

    /// Rule violations. Empty when every evidence item has a source and every finding has evidence.
    public var issues: [String] {
        var result: [String] = []
        let sourceIDs = Set(sources.map(\.id))
        let evidenceIDs = Set(evidence.map(\.id))
        for e in evidence where !sourceIDs.contains(e.sourceID) {
            result.append("Evidence \"\(e.excerpt.prefix(40))\" has no source")
        }
        for e in evidence where e.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append("Evidence \(e.id) is empty")
        }
        for f in findings {
            if f.evidenceIDs.isEmpty { result.append("Finding \"\(f.statement.prefix(40))\" cites no evidence") }
            if !Set(f.evidenceIDs).isSubset(of: evidenceIDs) { result.append("Finding \"\(f.statement.prefix(40))\" cites missing evidence") }
            if f.kind == .derived && f.method.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append("Derived finding \"\(f.statement.prefix(40))\" doesn't state its method")
            }
        }
        return result
    }

    /// Removes a source only when no evidence depends on it.
    public mutating func removeSource(_ id: UUID) -> Bool {
        guard !evidence.contains(where: { $0.sourceID == id }) else { return false }
        sources.removeAll { $0.id == id }
        return true
    }

    /// Removes evidence only when no finding cites it.
    public mutating func removeEvidence(_ id: UUID) -> Bool {
        guard !findings.contains(where: { $0.evidenceIDs.contains(id) }) else { return false }
        evidence.removeAll { $0.id == id }
        return true
    }
}

// MARK: - Marketing content calendar

public enum ContentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case productAnnouncement, releaseAnnouncement, campaign, general
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .productAnnouncement: L("Product announcement")
        case .releaseAnnouncement: L("Release announcement")
        case .campaign: L("Campaign")
        case .general: L("General")
        }
    }
}

/// Publishing workflow. Nothing is posted by Linumic OS: "published" is recorded by a
/// person after they publish, and only once the post was approved.
public enum ContentStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea, draft, inReview, approved, scheduled, published, cancelled
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: L("Idea")
        case .draft: L("Draft")
        case .inReview: L("In Review")
        case .approved: L("Approved")
        case .scheduled: L("Scheduled")
        case .published: L("Published")
        case .cancelled: L("Cancelled")
        }
    }

    /// Allowed next states.
    public var next: [ContentStatus] {
        switch self {
        case .idea: [.draft, .cancelled]
        case .draft: [.inReview, .cancelled]
        case .inReview: [.approved, .draft, .cancelled]
        case .approved: [.scheduled, .published, .draft, .cancelled]
        case .scheduled: [.published, .approved, .cancelled]
        case .published: []
        case .cancelled: [.draft]
        }
    }
}

public struct ContentItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var networks: [SocialNetwork]
    public var productID: String?
    public var kind: ContentKind
    public var campaign: String?
    public var language: String?
    public var status: ContentStatus
    public var scheduledFor: Date?
    public var approvedBy: String?
    public var approvedAt: Date?
    public var publishedURL: URL?
    public var publishedAt: Date?
    public var notes: String

    public init(id: UUID = UUID(), title: String, body: String = "", networks: [SocialNetwork] = [], productID: String? = nil,
                kind: ContentKind = .general, campaign: String? = nil, language: String? = nil, status: ContentStatus = .draft,
                scheduledFor: Date? = nil, notes: String = "") {
        self.id = id
        self.title = title
        self.body = body
        self.networks = networks
        self.productID = productID
        self.kind = kind
        self.campaign = campaign
        self.language = language
        self.status = status
        self.scheduledFor = scheduledFor
        self.notes = notes
    }

    public enum TransitionError: Error, Equatable, LocalizedError {
        case notAllowed(from: ContentStatus, to: ContentStatus)
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed(let from, let to): LF("Can't move from %@ to %@.", from.title, to.title)
            case .missing(let what): LF("%@ is required.", L(what))
            }
        }
    }

    /// Moves along the workflow, recording who approved and where it was published.
    public mutating func transition(to target: ContentStatus, by person: String = "Owner", scheduledFor date: Date? = nil,
                                    publishedURL url: URL? = nil, at now: Date = .now) throws {
        guard status.next.contains(target) else { throw TransitionError.notAllowed(from: status, to: target) }
        switch target {
        case .inReview:
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TransitionError.missing("Post text") }
            if networks.isEmpty { throw TransitionError.missing("At least one network") }
        case .approved:
            approvedBy = person
            approvedAt = now
        case .scheduled:
            guard let date = date ?? scheduledFor else { throw TransitionError.missing("A scheduled date") }
            scheduledFor = date
        case .published:
            guard let url else { throw TransitionError.missing("The link to the published post") }
            publishedURL = url
            publishedAt = now
        case .draft:
            approvedBy = nil
            approvedAt = nil
        case .idea, .cancelled:
            break
        }
        status = target
    }
}
