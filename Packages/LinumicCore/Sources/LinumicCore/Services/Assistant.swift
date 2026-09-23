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
        case .verified: L("Verified")
        case .derived: L("Derived")
        case .unknown: L("Unknown")
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

/// Answers questions about Linumic **only** from Linumic OS's records. It never uses
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
        let q = Self.normalize(question)
        func has(_ words: [String]) -> Bool { words.contains { q.contains(Self.normalize($0)) } }

        if let product = inventory.products.first(where: { p in
            ([p.name] + (p.alsoKnownAs.value ?? [])).contains { name in name.count > 2 && q.contains(Self.normalize(name)) }
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

    /// Makes matching robust to how Dari/Persian is typed: removes the zero-width non-joiner and
    /// joiner (Swift would otherwise merge them into the previous letter, so «برنامه‌ریزی» wouldn't
    /// contain «برنامه»), maps Arabic yeh/kaf to Persian ی/ک, and lowercases Latin text.
    static func normalize(_ text: String) -> String {
        var t = text.lowercased()
        for (from, to) in [("\u{200C}", ""), ("\u{200D}", ""), ("ي", "ی"), ("ى", "ی"), ("ك", "ک"), ("ة", "ه")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
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
            [AssistantStatement(LF("I can only answer from Linumic OS records. Try one of: %@, or name a product.", Self.suggestedQuestions.map(L).joined(separator: " · ")),
                                .unknown, basis: L("No matching question type"))]
        }
        return AssistantAnswer(question: question, intent: intent, statements: statements)
    }

    // MARK: Answers

    private var weekAgo: Date { now.addingTimeInterval(-7 * 24 * 3600) }

    func needsAttention() -> [AssistantStatement] {
        let rule = L("Rule: a product needs attention if it has conflicting facts, failing CI, a blocked release, an open critical issue, or an unknown development status.")
        var result: [AssistantStatement] = []
        for p in inventory.products where p.priority.value != .sidelined {
            var reasons: [String] = []
            let conflicts = p.needsConfirmation.filter { $0.verification.status == .conflicting }.map(\.label)
            if !conflicts.isEmpty { reasons.append(LF("conflicting: %@", conflicts.joined(separator: L(", ")))) }
            let failing = p.repositories.filter { $0.gitHub?.ciConclusion == .failure }.map(\.name)
            if !failing.isEmpty { reasons.append(LF("CI failing in %@", failing.joined(separator: L(", ")))) }
            if p.releases.contains(where: { $0.stage == .blocked }) { reasons.append(L("a blocked release")) }
            if !p.openCriticalIssues.isEmpty { reasons.append(LF("%ld open critical issue(s)", p.openCriticalIssues.count)) }
            if p.status.value == nil { reasons.append(L("development status unknown")) }
            if !reasons.isEmpty {
                result.append(AssistantStatement(LF("%@: %@.", p.name, reasons.joined(separator: L("; "))), .derived, productID: p.id, basis: rule))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement(L("No product meets any attention rule in the current records."), .derived, basis: rule))
        }
        let pending = inventory.products.map { $0.needsConfirmation.count }.reduce(0, +)
        result.append(AssistantStatement(LF("%ld facts across all products still await the owner's confirmation (see Verification).", pending), .derived,
                                         basis: L("Count of key facts, platforms and repository links not marked Verified")))
        return result
    }

    func blockedReleases() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for r in p.releases where r.stage == .blocked {
                result.append(AssistantStatement(LF("%@ %@ (%@) is blocked.", p.name, r.version, r.platform.title), .verified, productID: p.id,
                                                 basis: L("Release record in Linumic OS (manual entry)") + (r.notes.isEmpty ? "" : ": \(r.notes)")))
            }
            for l in p.storeListings where l.latestSubmittedVersion != nil && (l.reviewStatus ?? "").lowercased().contains("pending") {
                result.append(AssistantStatement(LF("%@ %@ is pending in App Store Connect. That's awaiting Apple, not recorded as blocked.", l.appName ?? p.name, l.latestSubmittedVersion!),
                                                 .verified, productID: p.id, basis: l.verification.sources.map(\.reference).first ?? L("Store listing record")))
            }
        }
        if !inventory.products.contains(where: { $0.releases.contains { $0.stage == .blocked } }) {
            result.insert(AssistantStatement(L("No release is recorded as blocked."), .verified, basis: L("All release records")), at: 0)
        }
        let withoutReleases = inventory.products.filter { $0.releases.isEmpty }.map(\.name)
        if !withoutReleases.isEmpty {
            result.append(AssistantStatement(LF("No release records exist for %ld products (%@), so their release state is unknown.", withoutReleases.count, withoutReleases.joined(separator: L(", "))),
                                             .unknown, basis: L("Releases are recorded manually. There's no release tracking outside Linumic OS yet.")))
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
                    result.append(AssistantStatement(LF("%@: new commit on %@/%@ %@: “%@”.", p.name, repo.name, g.defaultBranch, d.formatted(date: .abbreviated, time: .omitted), c.message),
                                                     .verified, productID: p.id, basis: LF("GitHub snapshot fetched %@", g.fetchedAt.formatted(date: .abbreviated, time: .shortened))))
                }
                if let r = g.latestRelease, let d = r.publishedAt, d >= weekAgo {
                    result.append(AssistantStatement(LF("%@: release %@ published on %@.", p.name, r.tag, repo.name), .verified, productID: p.id,
                                                     basis: LF("GitHub snapshot fetched %@", g.fetchedAt.formatted(date: .abbreviated, time: .shortened))))
                }
            }
        }
        let reverified = inventory.products.filter { p in p.allVerifications.contains { ($0.verifiedAt ?? .distantPast) >= weekAgo } }.count
        result.append(AssistantStatement(LF("Facts were recorded or re-verified this week for %ld products.", reverified), .derived,
                                         basis: L("Products with any verification dated in the last 7 days")))
        if result.count == 1 {
            result.insert(AssistantStatement(L("No commits or releases from the last 7 days appear in the GitHub snapshots."), .verified, basis: L("GitHub snapshots")), at: 0)
        }
        if let oldest = oldestSnapshot, oldest < now.addingTimeInterval(-24 * 3600) {
            result.append(AssistantStatement(LF("Some GitHub snapshots are older than a day (oldest %@). Refresh from Repositories for current data.", oldest.formatted(date: .abbreviated, time: .shortened)),
                                             .unknown, basis: L("Snapshot age")))
        }
        return result
    }

    func criticalIssues() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for i in p.openCriticalIssues {
                result.append(AssistantStatement(LF("%@: %@", p.name, i.title), .verified, productID: p.id, basis: L("Issue record (manual entry)") + (i.url.map { ", \($0.absoluteString)" } ?? "")))
            }
        }
        if result.isEmpty { result.append(AssistantStatement(L("No open critical issues are recorded."), .verified, basis: L("Issue records"))) }
        let ghOpen = inventory.products.flatMap { p in p.repositories.compactMap { r in (r.gitHub?.openIssues ?? 0) > 0 ? "\(p.name)/\(r.name) (\(r.gitHub!.openIssues!))" : nil } }
        if !ghOpen.isEmpty {
            result.append(AssistantStatement(LF("Open GitHub issues exist in %@, but their severity isn't known.", ghOpen.joined(separator: L(", "))), .unknown,
                                             basis: L("GitHub doesn't carry severity. Label or record them as issues to classify them.")))
        }
        return result
    }

    func readyForRelease() -> [AssistantStatement] {
        let rule = L("Rule: a release candidate in Internal Testing, Beta or Review that isn't blocked")
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for r in p.releases where r.isReleaseCandidate && [.internalTesting, .beta, .review].contains(r.stage) {
                result.append(AssistantStatement(LF("%@ %@ (%@, %@) is a release candidate.", p.name, r.version, r.platform.title, r.stage.title), .derived, productID: p.id, basis: rule))
            }
            for l in p.storeListings where l.latestSubmittedVersion != nil && (l.reviewStatus ?? "").lowercased().contains("pending") {
                result.append(AssistantStatement(LF("%@ %@ has been submitted and is pending in App Store Connect.", l.appName ?? p.name, l.latestSubmittedVersion!), .verified, productID: p.id,
                                                 basis: l.verification.sources.map(\.reference).first ?? L("Store listing record")))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement(L("No release candidates are recorded, so readiness is unknown."), .unknown, basis: L("Mark a release as a release candidate to track it")))
        }
        return result
    }

    func plannedFeatures() -> [AssistantStatement] {
        var result: [AssistantStatement] = []
        for p in inventory.products {
            for item in p.roadmap where item.status == .planned || item.status == .inProgress {
                result.append(AssistantStatement(item.targetVersion.map { LF("%@: %@ (%@, target %@)", p.name, item.title, item.status.title, $0) } ?? LF("%@: %@ (%@)", p.name, item.title, item.status.title), .verified, productID: p.id,
                                                 basis: L("Roadmap record (manual entry)")))
            }
        }
        if result.isEmpty {
            result.append(AssistantStatement(L("No planned features are recorded in any product roadmap."), .unknown,
                                             basis: L("Roadmaps in the product repositories (e.g. ROADMAP.md files) aren't imported. Add items on each product's Roadmap tab.")))
        }
        return result
    }

    func marketNeeds() -> [AssistantStatement] {
        let m = inventory.market
        var result: [AssistantStatement] = []
        for f in m.findings where f.review == .reviewed {
            let cites = m.evidence(for: f).map { "\(m.source(for: $0)?.name ?? "?") (\($0.collectedAt.formatted(date: .abbreviated, time: .omitted)))" }
            result.append(AssistantStatement(f.statement, f.kind == .verified ? .verified : .derived,
                                             basis: (f.kind == .derived ? LF("Method: %@. ", f.method) : "") + LF("Evidence: %@", cites.joined(separator: L("; ")))))
        }
        let drafts = m.findings.filter { $0.review == .draft }.count
        if drafts > 0 {
            result.append(AssistantStatement(LF("%ld draft finding(s) haven't been reviewed and aren't reported.", drafts), .unknown, basis: L("Only reviewed findings are answered")))
        }
        if result.isEmpty || m.findings.isEmpty {
            result.insert(AssistantStatement(L("No sourced market evidence has been recorded, so emerging needs in Afghanistan are unknown. I don't answer this from general knowledge."),
                                             .unknown, basis: LF("Market Intelligence has %ld sources, %ld evidence items and %ld findings", m.sources.count, m.evidence.count, m.findings.count)), at: 0)
        }
        return result
    }

    func productStatus(_ id: String) -> [AssistantStatement] {
        guard let p = inventory.products.first(where: { $0.id == id }) else { return [] }
        var result = [AssistantStatement(LF("%@: overall %@. %ld item(s) await confirmation.", p.name, p.overallVerification.title.lowercased(), p.needsConfirmation.count),
                                         .derived, productID: p.id, basis: L("Roll-up of all fact, platform, repository and listing verifications"))]
        for s in p.fieldStates where s.field.isKey || s.displayValue != nil {
            let v = s.verification
            switch v.status {
            case .verified:
                result.append(AssistantStatement(LF("%@: %@", s.field.title, s.displayValue ?? ""), .verified, productID: p.id, basis: v.sources.map { "\($0.kind.title): \($0.reference)" }.joined(separator: L("; "))))
            case .partiallyVerified:
                result.append(AssistantStatement(LF("%@: %@ (partially verified)", s.field.title, s.displayValue ?? ""), .derived, productID: p.id,
                                                 basis: v.notes.isEmpty ? v.sources.map(\.reference).joined(separator: "; ") : v.notes))
            case .unknown:
                result.append(AssistantStatement(LF("%@: unknown", s.field.title), .unknown, productID: p.id, basis: v.notes.isEmpty ? L("No evidence recorded") : v.notes))
            case .conflicting:
                result.append(AssistantStatement(LF("%@: sources conflict", s.field.title), .unknown, productID: p.id, basis: v.notes))
            }
        }
        let platforms = p.evidencedPlatforms.map(\.title)
        if !platforms.isEmpty {
            result.append(AssistantStatement(LF("Platforms with evidence: %@", platforms.joined(separator: L(", "))), .verified, productID: p.id, basis: L("Platform records")))
        }
        for l in p.storeListings {
            result.append(AssistantStatement(LF("%@: %@ live %@", l.store.title, l.appName ?? L("app"), l.productionVersion ?? L("unknown")) + (l.latestSubmittedVersion.map { LF(", submitted %@", $0) } ?? ""),
                                             l.verification.status == .verified ? .verified : .unknown, productID: p.id,
                                             basis: l.verification.sources.map(\.reference).joined(separator: "; ")))
        }
        return result
    }
}
