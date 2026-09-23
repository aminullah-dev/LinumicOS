import Foundation

/// How a statement in an answer is supported.
public enum AnswerKind: String, Sendable, CaseIterable {
    /// Read directly from a record that has a source (or a manual record, and says so).
    case verified
    /// Computed from records by a stated rule.
    case derived
    /// The records don't contain the answer.
    case unknown

    public var title: String {
        switch self {
        case .verified: "Verified"
        case .derived: "Derived"
        case .unknown: "Unknown"
        }
    }
}

public struct AssistantStatement: Hashable, Sendable, Identifiable {
    public let id = UUID()
    public var text: String
    public var kind: AnswerKind
    public var productID: String?
    /// Where it comes from (verified), the rule used (derived), or why it's missing (unknown).
    public var basis: String

    public init(_ text: String, _ kind: AnswerKind, productID: String? = nil, basis: String) {
        self.text = text
        self.kind = kind
        self.productID = productID
        self.basis = basis
    }
}

public enum AssistantIntent: Equatable, Sendable {
    case needsAttention, blockedReleases, changesThisWeek, criticalIssues, readyForRelease, plannedFeatures, marketNeeds
    case productStatus(String)
    case unrecognized
}

public struct AssistantAnswer: Sendable {
    public var question: String
    public var intent: AssistantIntent
    public var statements: [AssistantStatement]
}

/// Answers questions about Linumic **only** from the Command Center's records. It never uses
/// general knowledge, never guesses, and labels every statement Verified, Derived or Unknown.
/// It's a deterministic engine: no language model is involved.
public struct Assistant: Sendable {
    public static let suggestedQuestions = [
        "Which products need attention?",
        "Which releases are blocked?",
        "What changed this week?",
        "Which projects have unresolved critical issues?",
        "Which products are ready for release?",
        "What features are currently planned?",
        "What market needs are emerging in Afghanistan?",
    ]

    let inventory: Inventory
    let now: Date

    public init(inventory: Inventory, now: Date = .now) {
        self.inventory = inventory
        self.now = now
    }

    // MARK: Intent

    /// Keyword matching in English and Persian (Dari). A product name or alias takes priority.
    public func intent(of question: String) -> AssistantIntent {
        let q = question.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        if let product = inventory.products.first(where: { p in
            ([p.name] + (p.alsoKnownAs.value ?? [])).contains { name in name.count > 2 && q.contains(name.lowercased()) }
        }) {
            return .productStatus(product.id)
        }
        if has(["market", "demand", "afghanistan", "بازار", "تقاضا", "افغانستان"]) { return .marketNeeds }
        if has(["blocked", "block", "stuck", "مسدود", "متوقف", "گیر"]) { return .blockedReleases }
        if has(["critical", "بحرانی", "جدی"]) { return .criticalIssues }
        if has(["changed", "this week", "recent", "new", "تغییر", "این هفته", "جدید"]) { return .changesThisWeek }
        if has(["ready", "release candidate", "آماده", "انتشار"]) { return .readyForRelease }
        if has(["planned", "roadmap", "feature", "plan", "برنامه", "ویژگی", "نقشه راه"]) { return .plannedFeatures }
        if has(["attention", "problem", "risk", "need", "توجه", "مشکل", "خطر", "نیاز"]) { return .needsAttention }
        return .unrecognized
    }

    public func answer(_ question: String) -> AssistantAnswer {
        let intent = intent(of: question)
        let statements: [AssistantStatement] = switch intent {
        case .needsAttention: needsAttention()
        case .blockedReleases: blockedReleases()
        case .changesThisWeek: changesThisWeek()
        case .criticalIssues: criticalIssues()
        case .readyForRelease: readyForRelease()
        case .plannedFeatures: plannedFeatures()
        case .marketNeeds: marketNeeds()
        case .productStatus(let id): productStatus(id)
        case .unrecognized:
            [AssistantStatement("I can only answer from Command Center records. Try one of: " + Self.suggestedQuestions.joined(separator: " · ") + ", or name a product.",
                                .unknown, basis: "No matching question type")]
        }
        return AssistantAnswer(question: question, intent: intent, statements: statements)
    }

    // MARK: Answers

    private var weekAgo: Date { now.addingTimeInterval(-7 * 24 * 3600) }

    func needsAttention() -> [AssistantStatement] {
        let rule = "Rule: a product needs attention if it has conflicting facts, failing CI, a blocked release, an open critical issue, or an unknown development status."
        var result: [AssistantStatement] = []
        for p in inventory.products {
            var reasons: [String] = []
            let conflicts = p.needsConfirmation.filter { $0.verification.status == .conflicting }.map(\.label)
            if !conflicts.isEmpty { reasons.append("conflicting: \(conflicts.joined(separator: ", "))") }
            let failing = p.repositories.filter { $0.gitHub?.ciConclusion == .failure }.map(\.name)
            if !failing.isEmpty { reasons.append("CI failing in \(failing.joined(separator: ", "))") }
            if p.releases.contains(where: { $0.stage == .blocked }) { reasons.append("a blocked release") }
            if !p.openCriticalIssues.isEmpty { reasons.append("\(p.openCriticalIssues.count) open critical issue(s)") }
            if p.status.value == nil { reasons.append("development status unknown") }
            if !reasons.isEmpty {
                result.append(AssistantStatement("\(p.name): \(reasons.joined(separator: "; ")).", .derived, productID: p.id, basis: rule))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement("No product meets any attention rule in the current records.", .derived, basis: rule))
        }
        let pending = inventory.products.map { $0.needsConfirmation.count }.reduce(0, +)
        result.append(AssistantStatement("\(pending) facts across all products still await the owner's confirmation (see Verification).", .derived,
                                         basis: "Count of key facts, platforms and repository links not marked Verified"))
        return result
    }

    func blockedReleases() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for r in p.releases where r.stage == .blocked {
                result.append(AssistantStatement("\(p.name) \(r.version) (\(r.platform.title)) is blocked.", .verified, productID: p.id,
                                                 basis: "Release record in the Command Center (manual entry)" + (r.notes.isEmpty ? "" : ": \(r.notes)")))
            }
            for l in p.storeListings where l.latestSubmittedVersion != nil && (l.reviewStatus ?? "").lowercased().contains("pending") {
                result.append(AssistantStatement("\(l.appName ?? p.name) \(l.latestSubmittedVersion!) is pending in App Store Connect. That's awaiting Apple, not recorded as blocked.",
                                                 .verified, productID: p.id, basis: l.verification.sources.map(\.reference).first ?? "Store listing record"))
            }
        }
        if !result.contains(where: { $0.text.contains("is blocked") }) {
            result.insert(AssistantStatement("No release is recorded as blocked.", .verified, basis: "All release records"), at: 0)
        }
        let withoutReleases = inventory.products.filter { $0.releases.isEmpty }.map(\.name)
        if !withoutReleases.isEmpty {
            result.append(AssistantStatement("No release records exist for \(withoutReleases.count) products (\(withoutReleases.joined(separator: ", "))), so their release state is unknown.",
                                             .unknown, basis: "Releases are recorded manually. There's no release tracking outside the Command Center yet."))
        }
        return result
    }

    func changesThisWeek() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        var oldestSnapshot: Date?
        for p in inventory.products {
            for repo in p.repositories {
                guard let g = repo.gitHub else { continue }
                oldestSnapshot = min(oldestSnapshot ?? g.fetchedAt, g.fetchedAt)
                if let c = g.latestCommit, let d = c.date, d >= weekAgo {
                    result.append(AssistantStatement("\(p.name): new commit on \(repo.name)/\(g.defaultBranch) \(d.formatted(date: .abbreviated, time: .omitted)): “\(c.message)”.",
                                                     .verified, productID: p.id, basis: "GitHub snapshot fetched \(g.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                }
                if let r = g.latestRelease, let d = r.publishedAt, d >= weekAgo {
                    result.append(AssistantStatement("\(p.name): release \(r.tag) published on \(repo.name).", .verified, productID: p.id,
                                                     basis: "GitHub snapshot fetched \(g.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                }
            }
        }
        let reverified = inventory.products.filter { p in p.allVerifications.contains { ($0.verifiedAt ?? .distantPast) >= weekAgo } }.count
        result.append(AssistantStatement("Facts were recorded or re-verified this week for \(reverified) products.", .derived,
                                         basis: "Products with any verification dated in the last 7 days"))
        if result.count == 1 {
            result.insert(AssistantStatement("No commits or releases from the last 7 days appear in the GitHub snapshots.", .verified, basis: "GitHub snapshots"), at: 0)
        }
        if let oldest = oldestSnapshot, oldest < now.addingTimeInterval(-24 * 3600) {
            result.append(AssistantStatement("Some GitHub snapshots are older than a day (oldest \(oldest.formatted(date: .abbreviated, time: .shortened))). Refresh from Repositories for current data.",
                                             .unknown, basis: "Snapshot age"))
        }
        return result
    }

    func criticalIssues() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for i in p.openCriticalIssues {
                result.append(AssistantStatement("\(p.name): \(i.title)", .verified, productID: p.id, basis: "Issue record (manual entry)" + (i.url.map { ", \($0.absoluteString)" } ?? "")))
            }
        }
        if result.isEmpty { result.append(AssistantStatement("No open critical issues are recorded.", .verified, basis: "Issue records")) }
        let ghOpen = inventory.products.flatMap { p in p.repositories.compactMap { r in (r.gitHub?.openIssues ?? 0) > 0 ? "\(p.name)/\(r.name) (\(r.gitHub!.openIssues!))" : nil } }
        if !ghOpen.isEmpty {
            result.append(AssistantStatement("Open GitHub issues exist in \(ghOpen.joined(separator: ", ")), but their severity isn't known.", .unknown,
                                             basis: "GitHub doesn't carry severity. Label or record them as issues to classify them."))
        }
        return result
    }

    func readyForRelease() -> [AssistantStatement] {
        let rule = "Rule: a release candidate in Internal Testing, Beta or Review that isn't blocked"
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for r in p.releases where r.isReleaseCandidate && [.internalTesting, .beta, .review].contains(r.stage) {
                result.append(AssistantStatement("\(p.name) \(r.version) (\(r.platform.title), \(r.stage.title)) is a release candidate.", .derived, productID: p.id, basis: rule))
            }
            for l in p.storeListings where l.latestSubmittedVersion != nil && (l.reviewStatus ?? "").lowercased().contains("pending") {
                result.append(AssistantStatement("\(l.appName ?? p.name) \(l.latestSubmittedVersion!) has been submitted and is pending in App Store Connect.", .verified, productID: p.id,
                                                 basis: l.verification.sources.map(\.reference).first ?? "Store listing record"))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement("No release candidates are recorded, so readiness is unknown.", .unknown, basis: "Mark a release as a release candidate to track it"))
        }
        return result
    }

    func plannedFeatures() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for item in p.roadmap where item.status == .planned || item.status == .inProgress {
                result.append(AssistantStatement("\(p.name): \(item.title) (\(item.status.title)\(item.targetVersion.map { ", target \($0)" } ?? ""))", .verified, productID: p.id,
                                                 basis: "Roadmap record (manual entry)"))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement("No planned features are recorded in any product roadmap.", .unknown,
                                             basis: "Roadmaps in the product repositories (e.g. ROADMAP.md files) aren't imported. Add items on each product's Roadmap tab."))
        }
        return result
    }

    func marketNeeds() -> [AssistantStatement] {
        let m = inventory.market
        var result: [AssistantStatement] = []
        for f in m.findings where f.review == .reviewed {
            let cites = m.evidence(for: f).map { "\(m.source(for: $0)?.name ?? "?") (\($0.collectedAt.formatted(date: .abbreviated, time: .omitted)))" }
            result.append(AssistantStatement(f.statement, f.kind == .verified ? .verified : .derived,
                                             basis: (f.kind == .derived ? "Method: \(f.method). " : "") + "Evidence: " + cites.joined(separator: "; ")))
        }
        let drafts = m.findings.filter { $0.review == .draft }.count
        if drafts > 0 {
            result.append(AssistantStatement("\(drafts) draft finding(s) haven't been reviewed and aren't reported.", .unknown, basis: "Only reviewed findings are answered"))
        }
        if result.isEmpty || m.findings.isEmpty {
            result.insert(AssistantStatement("No sourced market evidence has been recorded, so emerging needs in Afghanistan are unknown. I don't answer this from general knowledge.",
                                             .unknown, basis: "Market Intelligence has \(m.sources.count) sources, \(m.evidence.count) evidence items and \(m.findings.count) findings"), at: 0)
        }
        return result
    }

    func productStatus(_ id: String) -> [AssistantStatement] {
        guard let p = inventory.products.first(where: { $0.id == id }) else { return [] }
        var result = [AssistantStatement("\(p.name): overall \(p.overallVerification.title.lowercased()). \(p.needsConfirmation.count) item(s) await confirmation.",
                                         .derived, productID: p.id, basis: "Roll-up of all fact, platform, repository and listing verifications")]
        for s in p.fieldStates where s.field.isKey || s.displayValue != nil {
            let v = s.verification
            switch v.status {
            case .verified:
                result.append(AssistantStatement("\(s.field.title): \(s.displayValue ?? "")", .verified, productID: p.id, basis: v.sources.map { "\($0.kind.title): \($0.reference)" }.joined(separator: "; ")))
            case .partiallyVerified:
                result.append(AssistantStatement("\(s.field.title): \(s.displayValue ?? "") (partially verified)", .derived, productID: p.id,
                                                 basis: v.notes.isEmpty ? v.sources.map(\.reference).joined(separator: "; ") : v.notes))
            case .unknown:
                result.append(AssistantStatement("\(s.field.title): unknown", .unknown, productID: p.id, basis: v.notes.isEmpty ? "No evidence recorded" : v.notes))
            case .conflicting:
                result.append(AssistantStatement("\(s.field.title): sources conflict", .unknown, productID: p.id, basis: v.notes))
            }
        }
        let platforms = p.evidencedPlatforms.map(\.title)
        if !platforms.isEmpty {
            result.append(AssistantStatement("Platforms with evidence: \(platforms.joined(separator: ", "))", .verified, productID: p.id, basis: "Platform records"))
        }
        for l in p.storeListings {
            result.append(AssistantStatement("\(l.store.title): \(l.appName ?? "app") live \(l.productionVersion ?? "unknown")" + (l.latestSubmittedVersion.map { ", submitted \($0)" } ?? ""),
                                             l.verification.status == .verified ? .verified : .unknown, productID: p.id,
                                             basis: l.verification.sources.map(\.reference).joined(separator: "; ")))
        }
        return result
    }
}
