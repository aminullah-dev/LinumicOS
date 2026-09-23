import Foundation
import Testing
@testable import LinumicCore

// SAMPLE data for testing only.

@Suite("Market intelligence")
struct MarketIntelligenceTests {
    @Test func evidenceNeedsSourceAndFindingsNeedEvidence() {
        let source = MarketSource(name: "SAMPLE survey", kind: .survey)
        let e = MarketEvidence(sourceID: source.id, excerpt: "SAMPLE excerpt", collectedAt: Date(timeIntervalSince1970: 0))
        var m = MarketIntelligence(sources: [source], evidence: [e])
        #expect(m.issues.isEmpty)

        m.findings = [MarketFinding(statement: "SAMPLE derived", kind: .derived, evidenceIDs: [e.id])]
        #expect(m.issues.contains { $0.contains("method") })
        m.findings[0].method = "Counted requests"
        #expect(m.issues.isEmpty)

        m.findings.append(MarketFinding(statement: "SAMPLE orphan", kind: .verified, evidenceIDs: []))
        #expect(m.issues.contains { $0.contains("cites no evidence") })
        m.evidence.append(MarketEvidence(sourceID: UUID(), excerpt: "orphan"))
        #expect(m.issues.contains { $0.contains("has no source") })
    }

    @Test func cannotRemoveReferencedRecords() {
        let source = MarketSource(name: "S", kind: .news)
        let e = MarketEvidence(sourceID: source.id, excerpt: "x")
        var m = MarketIntelligence(sources: [source], evidence: [e], findings: [MarketFinding(statement: "f", kind: .verified, evidenceIDs: [e.id])])
        let removed1 = m.removeSource(source.id)
        #expect(!removed1)
        let removed2 = m.removeEvidence(e.id)
        #expect(!removed2)
        m.findings.removeAll()
        let removed3 = m.removeEvidence(e.id)
        #expect(removed3)
        let removed4 = m.removeSource(source.id)
        #expect(removed4)
    }

    @Test func olderInventoryWithoutNewSectionsStillLoads() throws {
        let json = #"{"schemaVersion":2,"products":[]}"#
        let inv = try InventoryCoding.decode(Data(json.utf8))
        #expect(inv.market == MarketIntelligence())
        #expect(inv.content.isEmpty)
    }
}

@Suite("Content workflow")
struct ContentWorkflowTests {
    @Test func happyPathRecordsApprovalAndPublication() throws {
        var item = ContentItem(title: "SAMPLE", body: "Text", networks: [.linkedIn])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try item.transition(to: .inReview)
        try item.transition(to: .approved, by: "Owner", at: now)
        #expect(item.approvedAt == now)
        try item.transition(to: .scheduled, scheduledFor: now)
        try item.transition(to: .published, publishedURL: URL(string: "https://example.com/post"), at: now)
        #expect(item.status == .published)
        #expect(item.status.next.isEmpty)
    }

    @Test func cannotSkipApproval() {
        var item = ContentItem(title: "SAMPLE", body: "Text", networks: [.x])
        #expect(throws: ContentItem.TransitionError.notAllowed(from: .draft, to: .published)) {
            try item.transition(to: .published, publishedURL: URL(string: "https://example.com"))
        }
    }

    @Test func reviewNeedsTextAndNetworkAndPublishNeedsLink() throws {
        var empty = ContentItem(title: "SAMPLE")
        #expect(throws: ContentItem.TransitionError.missing("Post text")) { try empty.transition(to: .inReview) }
        empty.body = "x"
        #expect(throws: ContentItem.TransitionError.missing("At least one network")) { try empty.transition(to: .inReview) }
        var approved = ContentItem(title: "SAMPLE", body: "x", networks: [.facebook])
        try approved.transition(to: .inReview)
        try approved.transition(to: .approved)
        #expect(throws: ContentItem.TransitionError.missing("The link to the published post")) { try approved.transition(to: .published) }
    }

    @Test func returningToDraftClearsApproval() throws {
        var item = ContentItem(title: "SAMPLE", body: "x", networks: [.instagram])
        try item.transition(to: .inReview)
        try item.transition(to: .approved)
        try item.transition(to: .draft)
        #expect(item.approvedAt == nil && item.approvedBy == nil)
    }
}
