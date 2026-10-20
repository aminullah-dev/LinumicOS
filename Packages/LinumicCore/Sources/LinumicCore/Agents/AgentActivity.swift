import Foundation

// MARK: - What each agent did, from GitHub
//
// For every repository in the registry the app reads the newest pull requests (open, merged and closed, one page,
// `GET /repos/{r}/pulls?state=all&sort=created&direction=desc`), keeps only the ones that belong to an agent (by title
// prefix `[agent:<slug>]` or branch prefix `agent/<slug>/`), and remembers how far back the page reached: an agent with
// no pull request on the page has none since then, and nothing is said about the time before it.

/// A pull request opened by an agent.
public struct AgentPull: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case open, merged, closed

        public var title: String {
            switch self {
            case .open: L("Still open")
            case .merged: L("Merged")
            case .closed: L("Closed without merging")
            }
        }
    }

    /// The registry slug it belongs to.
    public var slug: String
    /// `owner/name`.
    public var repo: String
    public var number: Int
    public var title: String
    public var head: String
    public var state: State
    public var isDraft: Bool
    public var url: URL
    public var createdAt: Date
    public var updatedAt: Date?
    public var closedAt: Date?
    public var mergedAt: Date?

    public var id: String { "\(repo)#\(number)" }

    public init(slug: String, repo: String, number: Int, title: String, head: String, state: State, isDraft: Bool, url: URL,
                createdAt: Date, updatedAt: Date? = nil, closedAt: Date? = nil, mergedAt: Date? = nil) {
        self.slug = slug
        self.repo = repo
        self.number = number
        self.title = title
        self.head = head
        self.state = state
        self.isDraft = isDraft
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.mergedAt = mergedAt
    }

    /// The newest thing that happened to it.
    public var lastActivity: Date { [createdAt, updatedAt, closedAt, mergedAt].compactMap { $0 }.max() ?? createdAt }

    /// Open and not a draft: it waits for the coordinator's review and the owner's merge.
    public var isWaitingForReview: Bool { state == .open && !isDraft }
}

/// Which agent a pull request belongs to.
public enum AgentMatcher {
    /// The slug whose title prefix `[agent:<slug>]` the title starts with, else the slug whose branch prefix
    /// `agent/<slug>/` the head branch starts with; only slugs in `slugs`, case ignored, leading spaces ignored. Nil when
    /// it belongs to no agent ("[agent:talar]" is not "talar-web", and "agent/talar-web" without a topic is no branch of it).
    public static func slug(title: String, head: String, slugs: Set<String>) -> String? {
        let t = title.drop { $0.isWhitespace }.lowercased()
        if t.hasPrefix("[agent:"), let close = t.firstIndex(of: "]") {
            let slug = String(t[t.index(t.startIndex, offsetBy: 7)..<close]).trimmingCharacters(in: .whitespaces)
            if slugs.contains(slug) { return slug }
        }
        let h = head.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("agent/") {
            let rest = h.dropFirst(6)
            if let slash = rest.firstIndex(of: "/"), rest.index(after: slash) < rest.endIndex {
                let slug = String(rest[..<slash])
                if slugs.contains(slug) { return slug }
            }
        }
        return nil
    }
}

/// One repository's page of newest pull requests, as read.
public struct RepoPullWindow: Codable, Hashable, Sendable, Identifiable {
    public var repo: String
    /// The agents' pull requests on the page (the others are not kept).
    public var pulls: [AgentPull]
    /// How many pull requests the page held, the agents' and the others'.
    public var pageCount: Int
    /// The creation time of the oldest pull request on the page; nil when the page was empty.
    public var oldestCreatedAt: Date?
    /// The page held fewer than a full page: it reaches the repository's first pull request.
    public var isComplete: Bool
    public var readAt: Date
    /// The last refresh failed (the page above is the one before it, kept).
    public var error: String?

    public static let pageSize = 50

    public var id: String { repo.lowercased() }

    public init(repo: String, pulls: [AgentPull], pageCount: Int, oldestCreatedAt: Date?, isComplete: Bool, readAt: Date, error: String? = nil) {
        self.repo = repo
        self.pulls = pulls
        self.pageCount = pageCount
        self.oldestCreatedAt = oldestCreatedAt
        self.isComplete = isComplete
        self.readAt = readAt
        self.error = error
    }

    /// Everything created since this time is on the page; nil when the page reaches the first pull request.
    public var coveredSince: Date? { isComplete ? nil : oldestCreatedAt }
}

/// Where one agent stands.
public struct AgentStatus: Hashable, Sendable, Identifiable {
    public enum Quiet: Hashable, Sendable {
        /// It opened a pull request within the last `quietAfterDays`, or it was created more recently than that.
        case no
        /// No pull request for more than `quietAfterDays`: since when (its last pull request, or since the page or the
        /// registry starts) and how many whole days, as of `asOf` (the oldest reading of its repositories).
        case yes(days: Int, since: Date, lastPull: AgentPull?, asOf: Date)
        /// Not known, with why (a repository not read, or the page does not reach back far enough).
        case unknown(String)
    }

    public var agent: AgentEntry
    /// Open, newest first.
    public var open: [AgentPull]
    /// Merged or closed, newest first, at most `recentLimit`.
    public var recent: [AgentPull]
    public var lastActivity: Date?
    public var quiet: Quiet
    /// Its repositories that have not been read, or whose last refresh failed.
    public var notRead: [String]
    /// When its repositories were read (the oldest of them).
    public var readAt: Date?

    public static let recentLimit = 5

    public var id: String { agent.slug }
    public var waiting: [AgentPull] { open.filter(\.isWaitingForReview) }
    public var isQuiet: Bool { if case .yes = quiet { true } else { false } }
}

public struct AgentsReport: Hashable, Sendable {
    public var registry: AgentRegistry
    public var statuses: [AgentStatus]
    /// When the newest repository was read; nil when none has been.
    public var readAt: Date?
    /// Repositories that could not be read, with why.
    public var failures: [String: String]
    public var notRead: [String]

    public func status(_ slug: String) -> AgentStatus? { statuses.first { $0.agent.slug == slug } }
    public var waiting: [AgentPull] { statuses.flatMap(\.waiting) }
    public var quiet: [AgentStatus] { statuses.filter(\.isQuiet) }
    public var nothingRead: Bool { readAt == nil }
}

public enum AgentActivity {
    public static func report(registry: AgentRegistry, windows: [RepoPullWindow], now: Date) -> AgentsReport {
        let byRepo = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.readAt >= b.readAt ? a : b })
        let threshold = TimeInterval(registry.rules.quietAfterDays) * 86_400
        var failures: [String: String] = [:]
        for w in windows { if let e = w.error { failures[w.repo] = e } }
        let statuses = registry.agents.map { agent -> AgentStatus in
            let mine = agent.repositories.map { byRepo[$0.lowercased()] }
            let notRead = agent.repositories.enumerated().filter { mine[$0.offset] == nil || mine[$0.offset]?.error != nil }.map(\.element)
            // Every pull request of this agent seen anywhere (an agent's pull request in a repository not in its list is
            // still its own, and shown).
            let pulls = windows.flatMap(\.pulls).filter { $0.slug == agent.slug }
            let open = pulls.filter { $0.state == .open }.sorted { $0.createdAt > $1.createdAt }
            let recent = Array(pulls.filter { $0.state != .open }.sorted { $0.lastActivity > $1.lastActivity }.prefix(AgentStatus.recentLimit))
            let read = mine.compactMap { $0 }
            let asOf = read.count == mine.count ? read.map(\.readAt).min() : nil
            let quiet: AgentStatus.Quiet = {
                guard read.count == mine.count, let asOf else {
                    let missing = agent.repositories.filter { byRepo[$0.lowercased()] == nil }
                    return .unknown(LF("Pull requests of %@ have not been read yet.", missing.joined(separator: L(", "))))
                }
                // Every pull request created since `covered` is on all of its repositories' pages; before it, only some
                // pages reach.
                let covered = read.compactMap(\.coveredSince).max() ?? .distantPast
                let newest = pulls.max { $0.createdAt < $1.createdAt }
                if let newest, newest.createdAt >= covered {
                    let age = asOf.timeIntervalSince(newest.createdAt)
                    return age > threshold ? .yes(days: Int(age / 86_400), since: newest.createdAt, lastPull: newest, asOf: asOf) : .no
                }
                // None since the pages start (an older one on a page that reaches further may have been followed by one on a
                // page that does not reach back to it), or since the agents exist, if that is later.
                let from = max(registry.createdAt, covered)
                let age = asOf.timeIntervalSince(from)
                if age > threshold { return .yes(days: Int(age / 86_400), since: from, lastPull: nil, asOf: asOf) }
                if covered > registry.createdAt {
                    return .unknown(LF("Only the pull requests since %@ were read, and none of them is this agent's.", ProductDay.text(covered)))
                }
                return .no
            }()
            return AgentStatus(agent: agent, open: open, recent: recent, lastActivity: pulls.map(\.lastActivity).max(), quiet: quiet,
                               notRead: notRead, readAt: asOf)
        }
        let unread = registry.repositories.filter { byRepo[$0.lowercased()] == nil }
        return AgentsReport(registry: registry, statuses: statuses, readAt: windows.map(\.readAt).max(), failures: failures, notRead: unread)
    }
}
