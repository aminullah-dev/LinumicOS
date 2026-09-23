import Foundation
import Testing
@testable import LinumicCore

// SAMPLE inventory for testing only.

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let src = Source(kind: .localRepository, reference: "~/Projects/Sample/README.md", observedAt: now)
private let ok = Verification(status: .verified, sources: [src], verifiedAt: now)

private func sampleInventory() -> Inventory {
    var blocked = Release(version: "2.0", platform: .android, stage: .blocked, notes: "Signing key missing")
    blocked.isReleaseCandidate = false
    let rc = Release(version: "1.1", platform: .iOS, stage: .review, isReleaseCandidate: true)
    let a = Product(id: "alpha", name: "Alpha", alsoKnownAs: Fact(["Alfa"], ok), status: Fact(.active, ok),
                    repositories: [RepositoryRecord(name: "alpha", url: URL(string: "https://github.com/o/alpha"), link: ok,
                                                    gitHub: RepositorySnapshot(slug: "o/alpha", defaultBranch: "main",
                                                                               latestCommit: .init(sha: "abc", message: "Fix login", date: now.addingTimeInterval(-3600)),
                                                                               openIssues: 4, ciConclusion: .failure, fetchedAt: now))],
                    roadmap: [RoadmapItem(title: "Offline mode", status: .inProgress, targetVersion: "2.0")],
                    issues: [IssueRecord(title: "Crash on launch", severity: .critical)],
                    releases: [blocked, rc])
    let b = Product(id: "beta", name: "Beta", website: Fact(nil, Verification(status: .conflicting, sources: [src, src], verifiedAt: now, notes: "Site says X, repo says Y")))
    return Inventory(products: [a, b])
}

@Suite("Assistant")
struct AssistantTests {
    let assistant = Assistant(inventory: sampleInventory(), now: now)

    @Test func classifiesEnglishAndPersianQuestions() {
        #expect(assistant.intent(of: "Which products need attention?") == .needsAttention)
        #expect(assistant.intent(of: "Which releases are blocked?") == .blockedReleases)
        #expect(assistant.intent(of: "What changed this week?") == .changesThisWeek)
        #expect(assistant.intent(of: "Which projects have unresolved critical issues?") == .criticalIssues)
        #expect(assistant.intent(of: "Which products are ready for release?") == .readyForRelease)
        #expect(assistant.intent(of: "What features are currently planned?") == .plannedFeatures)
        #expect(assistant.intent(of: "What market needs are emerging in Afghanistan?") == .marketNeeds)
        #expect(assistant.intent(of: "کدام محصولات نیاز به توجه دارند؟") == .needsAttention)
        #expect(assistant.intent(of: "نیازهای بازار افغانستان چیست؟") == .marketNeeds)
        #expect(assistant.intent(of: "What is the status of Alfa?") == .productStatus("alpha"))
        #expect(assistant.intent(of: "Tell me a joke") == .unrecognized)
    }

    /// The Dari translations of the suggested questions (App/Resources/Localizable.xcstrings)
    /// must reach the same answers as the English ones.
    @Test func dariSuggestedQuestionsRouteCorrectly() {
        let dari: [(String, AssistantIntent)] = [
            ("کدام محصولات به توجه نیاز دارند؟", .needsAttention),
            ("کدام انتشارها مسدود هستند؟", .blockedReleases),
            ("این هفته چه تغییر کرد؟", .changesThisWeek),
            ("کدام پروژه‌ها مشکلات بحرانی حل‌نشده دارند؟", .criticalIssues),
            ("کدام محصولات برای انتشار آماده‌اند؟", .readyForRelease),
            ("کدام ویژگی‌ها فعلاً برنامه‌ریزی شده‌اند؟", .plannedFeatures),
            ("چه نیازهای تازه‌ای در بازار افغانستان پیدا می‌شود؟", .marketNeeds),
        ]
        for (question, expected) in dari {
            #expect(assistant.intent(of: question) == expected, "\(question)")
        }
    }

    @Test func normalizationHandlesZWNJAndArabicLetters() {
        #expect(Assistant.normalize("برنامه‌ریزی").contains(Assistant.normalize("برنامه")))
        #expect(Assistant.normalize("كدام محصولات") == Assistant.normalize("کدام محصولات"))
        #expect(Assistant.normalize("ويژگي") == "ویژگی")
    }

    @Test func everyStatementHasABasis() {
        for q in Assistant.suggestedQuestions + ["Alpha", "Beta", "nonsense"] {
            for s in assistant.answer(q).statements {
                #expect(!s.basis.trimmingCharacters(in: .whitespaces).isEmpty, "\(q): \(s.text)")
            }
        }
    }

    @Test func attentionUsesTheStatedRule() {
        let s = assistant.answer("Which products need attention?").statements
        let alpha = s.first { $0.productID == "alpha" }
        #expect(alpha?.kind == .derived)
        #expect(alpha?.text.contains("CI failing") == true)
        #expect(alpha?.text.contains("blocked release") == true)
        #expect(s.first { $0.productID == "beta" }?.text.contains("conflicting") == true)
    }

    @Test func blockedAndReadyReleases() {
        let blocked = assistant.answer("Which releases are blocked?").statements
        #expect(blocked.contains { $0.kind == .verified && $0.text.contains("Alpha 2.0") && $0.basis.contains("Signing key missing") })
        #expect(blocked.contains { $0.kind == .unknown && $0.text.contains("Beta") })
        let ready = assistant.answer("Which products are ready for release?").statements
        #expect(ready.contains { $0.kind == .derived && $0.text.contains("1.1") })
    }

    @Test func criticalIssuesSeparateKnownFromUnknownSeverity() {
        let s = assistant.answer("critical issues").statements
        #expect(s.contains { $0.kind == .verified && $0.text.contains("Crash on launch") })
        #expect(s.contains { $0.kind == .unknown && $0.text.contains("severity") })
    }

    @Test func changesComeFromSnapshots() {
        let s = assistant.answer("What changed this week?").statements
        #expect(s.contains { $0.kind == .verified && $0.text.contains("Fix login") })
    }

    @Test func marketQuestionWithoutEvidenceIsUnknown() {
        let s = assistant.answer("What market needs are emerging in Afghanistan?").statements
        #expect(s.first?.kind == .unknown)
        #expect(s.allSatisfy { $0.kind == .unknown })
    }

    @Test func marketAnswersOnlyReviewedFindingsWithCitations() {
        var inv = sampleInventory()
        let source = MarketSource(name: "SAMPLE survey", kind: .survey)
        let e = MarketEvidence(sourceID: source.id, excerpt: "x", collectedAt: now)
        inv.market = MarketIntelligence(sources: [source], evidence: [e], findings: [
            MarketFinding(statement: "SAMPLE reviewed", kind: .derived, evidenceIDs: [e.id], method: "Counted", review: .reviewed),
            MarketFinding(statement: "SAMPLE draft", kind: .verified, evidenceIDs: [e.id]),
        ])
        let s = Assistant(inventory: inv, now: now).answer("market needs").statements
        #expect(s.contains { $0.text == "SAMPLE reviewed" && $0.kind == .derived && $0.basis.contains("SAMPLE survey") && $0.basis.contains("Counted") })
        #expect(!s.contains { $0.text == "SAMPLE draft" })
    }

    @Test func productStatusMirrorsVerification() {
        let s = assistant.answer("Beta").statements
        #expect(s.contains { $0.text.hasPrefix("Website: sources conflict") && $0.kind == .unknown })
        #expect(s.contains { $0.text.hasPrefix("Development status: unknown") && $0.kind == .unknown })
    }

    @Test func worksOnTheRealSeedWithoutInventingAnything() throws {
        let seed = try SeedInventory.load()
        let a = Assistant(inventory: seed, now: now)
        #expect(a.answer("What features are currently planned?").statements.allSatisfy { $0.kind == .unknown })
        #expect(a.answer("What market needs are emerging in Afghanistan?").statements.allSatisfy { $0.kind == .unknown })
        let tailoring = a.answer("Tailoring Workshop ERP").statements
        #expect(tailoring.contains { $0.text.hasPrefix("Website: unknown") }, "the owner resolved the conflict")
        // Sidelined products are left out of the attention list.
        #expect(!a.answer("Which products need attention?").statements.contains { $0.productID == "tailoring-workshop-erp" })
    }
}
