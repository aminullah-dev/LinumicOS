import Foundation
import Testing
@testable import LinumicCore

// The agents' registry, which pull request belongs to which agent, "no pull request for more than 4 days", and their
// Brief lines and Desk items. Pages are recorded GitHub answers (Fixtures/products-pulls-*.json, trimmed to the fields
// read; LinumicOS is public).

private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let registry = AgentRegistry.bundled
private let slugs = Set(registry.agents.map(\.slug))

private func window(_ repo: String, _ name: String, readAt: Date) throws -> RepoPullWindow {
    try ProductsParser.pullWindow(fixture(name), repo: repo, slugs: slugs, readAt: readAt)
}

/// Every registry repository read at `readAt`, with no pull request on a complete page, except the recorded ones.
private func windows(readAt: Date, recorded: [RepoPullWindow]) -> [RepoPullWindow] {
    registry.repositories.map { repo in
        recorded.first { $0.id == repo.lowercased() }
            ?? RepoPullWindow(repo: repo, pulls: [], pageCount: 12, oldestCreatedAt: at("2026-08-01T00:00:00Z"), isComplete: true, readAt: readAt)
    }
}

@Suite("Agents: registry, matching and quiet agents")
struct AgentsTests {
    @Test func theRegistryHoldsTheTwentyAgents() throws {
        #expect(registry.problems == [])
        #expect(registry.agents.map(\.number) == Array(1...20))
        #expect(registry.agents.allSatisfy { $0.cadence == "every 2 days" && !$0.repositories.isEmpty })
        #expect(registry.agents.map(\.slug).prefix(4) == ["worktrack-backend", "worktrack-web", "worktrack-android", "worktrack-ios"])
        #expect(registry.agent("linumic-os")?.utcTime == "12:23" && registry.agent("linumic-os")?.days == .even)
        #expect(registry.agent("worktrack-backend")?.cron == "7 1 */2 * *")
        #expect(registry.agent("security")?.repositories.count == 5 && registry.agent("security")?.deskProduct == nil)
        #expect(registry.repositories.count == 10)
        #expect(registry.rules.quietAfterDays == 4)
        // Every product an agent works on is one the Desk knows by name.
        for agent in registry.agents { for p in agent.products { #expect(!DeskDomain.named(p).key.hasPrefix("other:"), "\(p)") } }
        // A public repository: no routine id, environment, prompt, address or token.
        let text = String(decoding: try Data(contentsOf: try #require(AgentRegistry.bundledFileURL)), as: UTF8.self)
        for never in ["trig_", "env_", "cse_", "@", "http", "token", "You are"] { #expect(!text.contains(never), "\(never)") }
    }

    @Test func aBrokenRegistryIsCaught() throws {
        var bad = registry
        bad.agents[1].slug = bad.agents[0].slug
        bad.agents[2].utcTime = "05:42"
        bad.agents[3].cron = "53 7 1-31/2 * *"
        #expect(bad.problems.count == 3)
    }

    @Test func matchingByTitleOrBranch() {
        let cases: [(title: String, head: String, slug: String?)] = [
            ("[agent:linumic-os] Tests for the public App Store lookup and StoreSync", "agent/linumic-os/2026-10-20-app-store-lookup-tests", "linumic-os"),
            ("[agent:talar-web] Unit tests for lib/jalali", "feature/x", "talar-web"),
            ("Unit tests for lib/jalali", "agent/talar-web/2026-10-20-jalali-tests", "talar-web"),
            ("  [Agent:Talar-Android] Unit tests", "main", "talar-android"),
            // "talar" is not an agent; "talar-web" without a topic is no agent branch.
            ("[agent:talar] tests", "agent/talar-web", nil),
            ("[agent:security] Bump express to 5.1.1", "agent/security/2026-10-22-express", "security"),
            ("Company OS phase 5: Sales, WorkTrack first (read-only)", "feat/sales", nil),
            ("Bump actions/checkout from 4 to 7", "dependabot/github_actions/actions/checkout-7", nil),
            ("Re: [agent:dukanpro] follow-up", "fix/x", nil),
        ]
        for c in cases { #expect(AgentMatcher.slug(title: c.title, head: c.head, slugs: slugs) == c.slug, "\(c.title) / \(c.head)") }
    }

    @Test func recordedPagesKeepOnlyTheAgentsPullRequests() throws {
        let readAt = at("2026-10-20T15:00:00Z")
        let os = try window("aminullah-dev/LinumicOS", "products-pulls-linumicos", readAt: readAt)
        #expect(os.pageCount == 30 && os.isComplete && os.coveredSince == nil)
        #expect(os.pulls.map(\.number) == [30])
        let pr = try #require(os.pulls.first)
        #expect(pr.slug == "linumic-os" && pr.state == .open && pr.isWaitingForReview && pr.createdAt == at("2026-10-20T14:31:42Z"))
        #expect(pr.url.absoluteString == "https://github.com/aminullah-dev/LinumicOS/pull/30")

        let talar = try window("aminullah-dev/talar", "products-pulls-talar", readAt: readAt)
        #expect(talar.pulls.map(\.slug) == ["talar-web", "talar-android"])
        #expect(talar.pulls.allSatisfy { $0.state == .merged && $0.mergedAt != nil })
        #expect(talar.oldestCreatedAt == at("2026-07-25T01:05:20Z"))
    }

    @Test func quietAfterFourDaysOnly() throws {
        let os = try window("aminullah-dev/LinumicOS", "products-pulls-linumicos", readAt: at("2026-10-25T06:00:00Z"))
        let talar = try window("aminullah-dev/talar", "products-pulls-talar", readAt: at("2026-10-25T06:00:00Z"))
        let report = AgentActivity.report(registry: registry, windows: windows(readAt: at("2026-10-25T06:00:00Z"), recorded: [os, talar]),
                                          now: at("2026-10-25T06:00:00Z"))
        // linumic-os: its last pull request was opened 10-20 14:31, 4 days 15 hours before the reading.
        let mine = try #require(report.status("linumic-os"))
        guard case .yes(let days, let since, let last, _) = mine.quiet else {
            Issue.record("linumic-os should be quiet: \(mine.quiet)")
            return
        }
        #expect(days == 4 && since == at("2026-10-20T14:31:42Z") && last?.number == 30)
        #expect(mine.waiting.map(\.number) == [30], "still open, still waiting")
        // khayatyar-ios: no pull request at all on a complete page, since the agents were created (10-20 05:13).
        guard case .yes(5, let from, nil, _) = report.status("khayatyar-ios")?.quiet else {
            Issue.record("khayatyar-ios should be quiet for 5 days")
            return
        }
        #expect(from == registry.createdAt)
        // talar-web merged on 10-20: quiet too by 10-25, with its merged pull request as the last one.
        #expect(report.status("talar-web")?.recent.first?.number == 7)

        // Three days after: nobody is quiet yet.
        let early = AgentActivity.report(registry: registry, windows: windows(readAt: at("2026-10-23T06:00:00Z"), recorded: []),
                                         now: at("2026-10-23T06:00:00Z"))
        #expect(early.quiet.isEmpty && early.statuses.allSatisfy { $0.quiet == .no })
    }

    @Test func quietIsCountedToTheReadingNotToNow() throws {
        // Read on 10-23, looked at on 10-26: a pull request may have been opened since the reading, so the days without
        // one are counted to the reading (2 days 15 hours), not to now.
        let os = try window("aminullah-dev/LinumicOS", "products-pulls-linumicos", readAt: at("2026-10-23T06:00:00Z"))
        let report = AgentActivity.report(registry: registry, windows: windows(readAt: at("2026-10-23T06:00:00Z"), recorded: [os]),
                                          now: at("2026-10-26T06:00:00Z"))
        #expect(report.status("linumic-os")?.quiet == .no)
        #expect(report.status("linumic-os")?.readAt == at("2026-10-23T06:00:00Z"))
    }

    @Test func whatWasNotReadIsUnknown() {
        // Only LinumicOS read: every other agent's state is unknown, never "quiet" and never "fine".
        let report = AgentActivity.report(registry: registry, windows: [
            RepoPullWindow(repo: "aminullah-dev/LinumicOS", pulls: [], pageCount: 3, oldestCreatedAt: at("2026-10-01T00:00:00Z"), isComplete: true,
                           readAt: at("2026-10-30T00:00:00Z")),
        ], now: at("2026-10-30T00:00:00Z"))
        #expect(report.status("linumic-os")?.isQuiet == true)
        guard case .unknown(let why) = report.status("dukanpro")?.quiet else {
            Issue.record("dukanpro was not read")
            return
        }
        #expect(why == "Pull requests of aminullah-dev/DukanPro have not been read yet.")
        #expect(report.notRead.count == 9)

        // A full page that reaches back only two days: no claim about the days before it.
        let busy = RepoPullWindow(repo: "aminullah-dev/WorkTrack", pulls: [], pageCount: 50, oldestCreatedAt: at("2026-10-22T00:00:00Z"),
                                  isComplete: false, readAt: at("2026-10-24T00:00:00Z"))
        let partial = AgentActivity.report(registry: registry, windows: windows(readAt: at("2026-10-24T00:00:00Z"), recorded: [busy]),
                                           now: at("2026-10-24T00:00:00Z"))
        guard case .unknown(let short) = partial.status("worktrack-ios")?.quiet else {
            Issue.record("a short page says nothing about the days before it")
            return
        }
        #expect(short == "Only the pull requests since 2026-10-22 were read, and none of them is this agent's.")
    }

    @Test func briefLinesAndDeskItems() throws {
        let readAt = at("2026-10-25T06:00:00Z")
        let os = try window("aminullah-dev/LinumicOS", "products-pulls-linumicos", readAt: readAt)
        let report = AgentActivity.report(registry: registry, windows: windows(readAt: readAt, recorded: [os]), now: readAt)
        let section = AgentsBrief.section(report)
        let waiting = try #require(section.lines.first { $0.id == "agents.waiting.linumic-os" })
        #expect(waiting.text == "Agent 16 (linumic-os): pull requests waiting for review: 1")
        #expect(waiting.detail == "#30 [agent:linumic-os] Tests for the public App Store lookup and StoreSync (aminullah-dev/LinumicOS)")
        #expect(waiting.product == "Linumic OS" && waiting.destination == .agents("linumic-os") && waiting.factKey == "aminullah-dev/LinumicOS#30")
        let quiet = try #require(section.lines.first { $0.id == "agents.quiet.khayatyar-ios" })
        #expect(quiet.text == "Agent 13 (khayatyar-ios): no pull request for 5 days")
        #expect(quiet.detail == "No pull request of this agent since 2026-10-20. It runs every 2 days at 05:41 UTC.")
        #expect(section.lines.filter { $0.id.hasPrefix("agents.quiet.") }.count == 20, "every agent: none opened a pull request in five days here")
        #expect(section.gaps.isEmpty)

        var brief = BriefInput(now: readAt, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                               licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                               operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []))
        brief.agents = report
        let desk = DeskBuilder.build(brief: DailyBriefBuilder.build(brief, changes: []), ledgers: .unsupported, state: DeskState(), now: readAt)
        let item = try #require(desk.open.first { $0.id == "brief.agents|agents.quiet.khayatyar-ios|fact" })
        #expect(item.item.domain == .khayatYar && item.item.destination == .screen(.agents("khayatyar-ios")))
        #expect(desk.open.contains { $0.id == "brief.agents|agents.waiting.linumic-os|fact" && $0.item.domain == .linumicOS })
        // The agent covering several products is filed under all products.
        #expect(desk.open.first { $0.id == "brief.agents|agents.quiet.security|fact" }?.item.domain == .shared)

        // Not read at all: one "not read yet" item, no zero.
        guard case .neverRead = AgentsBrief.section(nil).state else {
            Issue.record("never read")
            return
        }
        let unread = AgentsBrief.section(AgentActivity.report(registry: registry, windows: [os], now: readAt))
        #expect(unread.gaps.map(\.key).sorted().first == "repo.aminullah-dev/-namazia")
        #expect(unread.gaps.count == 9)
    }
}
