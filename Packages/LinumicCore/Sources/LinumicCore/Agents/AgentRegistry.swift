import Foundation

// MARK: - Agents (ایجنت‌ها): the registry
//
// The owner's scheduled cloud agents, one per product platform, each opening pull requests titled "[agent:<slug>] …" on
// branches agent/<slug>/<date>-<topic>. The registry is a file in this repository (`Resources/agents.json`): slug, area,
// repositories, cadence and UTC time, with where it was recorded. It holds no routine id, prompt or secret, and nothing
// here talks to the service that runs the agents: what each agent did is read from GitHub only (`AgentActivity`).

/// One agent as recorded in `agents.json`.
public struct AgentEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Days: String, Codable, Sendable {
        /// Day-of-month `*/2`: the 1st, 3rd, 5th, … (so the 31st and the 1st in a row).
        case odd
        /// Day-of-month `2-30/2`: the 2nd, 4th, … 30th.
        case even
    }

    /// 1 to 20, as the routines are named ("Agent 01").
    public var number: Int
    /// What its pull requests and branches carry: `[agent:<slug>]`, `agent/<slug>/`.
    public var slug: String
    /// The area, as recorded (English, a name of record).
    public var title: String
    /// Product names of record ("WorkTrack", "KhayatYar"); several for the agents that cover more than one.
    public var products: [String]
    /// `Platform` raw values; empty for an agent that works across platforms (security and dependencies).
    public var platforms: [String]
    /// `owner/name` of every repository it works in.
    public var repositories: [String]
    /// As recorded: "every 2 days".
    public var cadence: String
    /// The routine's 5-field cron, in UTC.
    public var cron: String
    /// "HH:MM", UTC.
    public var utcTime: String
    public var days: Days

    public var id: String { slug }

    /// "Agent 01", as the routines are named.
    public var label: String { LF("Agent %02ld", number) }

    /// `[agent:<slug>]`.
    public var titlePrefix: String { "[agent:\(slug)]" }
    /// `agent/<slug>/`.
    public var branchPrefix: String { "agent/\(slug)/" }

    /// The platforms it covers, as the app's own type (unknown raw values are left out, never guessed).
    public var platformKinds: [Platform] { platforms.compactMap(Platform.init(rawValue:)) }

    /// The product the Desk files it under: its only product, or "All products" for one that covers several.
    public var deskProduct: String? { products.count == 1 ? products[0] : nil }

    public init(number: Int, slug: String, title: String, products: [String], platforms: [String], repositories: [String],
                cadence: String, cron: String, utcTime: String, days: Days) {
        self.number = number
        self.slug = slug
        self.title = title
        self.products = products
        self.platforms = platforms
        self.repositories = repositories
        self.cadence = cadence
        self.cron = cron
        self.utcTime = utcTime
        self.days = days
    }
}

/// `agents.json`.
public struct AgentRegistry: Codable, Hashable, Sendable {
    public struct Rules: Codable, Hashable, Sendable {
        public var titlePrefix: String
        public var branchPrefix: String
        public var pullRequestsOnly: Bool
        /// The cadence is 2 days and a calendar month can put 3 days between two runs (an even-day agent from the 30th to
        /// the 2nd); more than this many days without a pull request is a Desk item.
        public var quietAfterDays: Int
    }

    public var schemaVersion: Int
    /// Where the registry was recorded, as a sentence.
    public var source: String
    /// The day it was recorded ("2026-10-20").
    public var recordedOn: String
    /// When the routines existed by (the last one was created just before): the quiet rule counts from here for an
    /// agent with no pull request yet.
    public var createdAt: Date
    public var rules: Rules
    public var agents: [AgentEntry]

    /// The registry bundled with the app. A file that is missing or can't be decoded is a programming error, caught by
    /// the tests, so this never returns an invented list.
    /// `agents.json` in this package's resources.
    public static var bundledFileURL: URL? { Bundle.module.url(forResource: "agents", withExtension: "json") }

    public static let bundled: AgentRegistry = {
        guard let url = bundledFileURL,
              let data = try? Data(contentsOf: url),
              let registry = try? decode(data) else {
            preconditionFailure("Resources/agents.json is missing or invalid")
        }
        return registry
    }()

    public static func decode(_ data: Data) throws -> AgentRegistry {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(AgentRegistry.self, from: data)
    }

    /// Every repository any agent works in, in first-seen order (what the app reads pull requests from).
    public var repositories: [String] {
        var seen = Set<String>()
        return agents.flatMap(\.repositories).filter { seen.insert($0.lowercased()).inserted }
    }

    public func agent(_ slug: String) -> AgentEntry? { agents.first { $0.slug == slug } }

    /// Problems that make the registry unusable: duplicate numbers or slugs, a slug that is not lower-case letters,
    /// digits and dashes, a cron whose time disagrees with `utcTime` or whose day field is neither `*/2` nor `2-30/2`.
    public var problems: [String] {
        var out: [String] = []
        var slugs = Set<String>(), numbers = Set<Int>()
        for a in agents {
            if !slugs.insert(a.slug).inserted { out.append("duplicate slug \(a.slug)") }
            if !numbers.insert(a.number).inserted { out.append("duplicate number \(a.number)") }
            if a.slug.isEmpty || a.slug.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) == nil { out.append("bad slug \(a.slug)") }
            if a.repositories.isEmpty { out.append("\(a.slug): no repository") }
            let fields = a.cron.split(separator: " ").map(String.init)
            guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]) else {
                out.append("\(a.slug): cron \(a.cron)")
                continue
            }
            if String(format: "%02d:%02d", hour, minute) != a.utcTime { out.append("\(a.slug): utcTime \(a.utcTime) is not the cron's") }
            let expected = a.days == .odd ? "*/2" : "2-30/2"
            if fields[2] != expected || fields[3] != "*" || fields[4] != "*" { out.append("\(a.slug): cron days \(a.cron)") }
        }
        return out
    }
}
