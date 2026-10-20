import Foundation

// MARK: - Agents in the Daily Brief (and so on the Desk)
//
// Two kinds of line, each filed under the agent's product: pull requests waiting for review (one line per agent, the
// numbers in the detail), and an agent with no pull request for more than `quietAfterDays` days (its cadence is two). A
// repository that was not read, or a quiet state that can't be known, is a gap. Line ids carry the agent's slug only.

extension DailyBriefBuilder {
    static func agents(_ input: BriefInput) -> BriefSection {
        AgentsBrief.section(input.agents)
    }
}

public enum AgentsBrief {
    public static var source: String { L("Agents: pull requests on GitHub by title [agent:<slug>] or branch agent/<slug>/ (read-only)") }

    public static func section(_ report: AgentsReport?) -> BriefSection {
        guard let report, !report.nothingRead else {
            return BriefSection(kind: .agents, state: .neverRead(L("The agents' pull requests have not been read from GitHub yet.")),
                                readAt: nil, source: source)
        }
        var lines: [BriefLine] = []
        var gaps: [BriefGap] = []
        for status in report.statuses {
            let agent = status.agent
            let name = "\(agent.label) (\(agent.slug))"
            let waiting = status.waiting
            if !waiting.isEmpty {
                lines.append(BriefLine(id: "agents.waiting.\(agent.slug)", kind: .agents, severity: .normal,
                                       text: LF("%1$@: pull requests waiting for review: %2$ld", name, waiting.count),
                                       detail: waiting.map { "#\($0.number) \($0.title) (\($0.repo))" }.joined(separator: L("; ")),
                                       source: LF("GitHub pull requests of %@", Set(waiting.map(\.repo)).sorted().joined(separator: L(", "))),
                                       readAt: status.readAt, destination: .agents(agent.slug), product: agent.deskProduct,
                                       factKey: waiting.map(\.id).sorted().joined(separator: ",")))
            }
            switch status.quiet {
            case .yes(let days, let since, let last, _):
                let detail = last.map { LF("Last pull request: #%1$ld %2$@ (%3$@), opened %4$@.", $0.number, $0.title, $0.repo, ProductDay.text($0.createdAt)) }
                    ?? LF("No pull request of this agent since %@.", ProductDay.text(since))
                lines.append(BriefLine(id: "agents.quiet.\(agent.slug)", kind: .agents, severity: .normal,
                                       text: LF("%1$@: no pull request for %2$ld days", name, days),
                                       detail: detail + " " + LF("It runs %1$@ at %2$@ UTC.", L(agent.cadence), agent.utcTime),
                                       source: LF("GitHub pull requests of %@", agent.repositories.joined(separator: L(", "))),
                                       readAt: status.readAt, destination: .agents(agent.slug), product: agent.deskProduct,
                                       factKey: ProductDay.text(since)))
            case .unknown(let why):
                // A repository not read is said once, below; this is for a page that does not reach back far enough.
                if status.notRead.isEmpty {
                    gaps.append(BriefGap(key: "quiet.\(agent.slug)", text: LF("%1$@: whether it opened a pull request in the last %2$ld days is unknown: %3$@",
                                                                               name, report.registry.rules.quietAfterDays, why),
                                         product: agent.deskProduct))
                }
            case .no:
                break
            }
        }
        for repo in report.notRead {
            gaps.append(BriefGap(key: "repo.\(repo.lowercased())", text: LF("%@: pull requests not read yet.", repo), product: repo))
        }
        for (repo, error) in report.failures.sorted(by: { $0.key < $1.key }) {
            gaps.append(BriefGap(key: "repo.\(repo.lowercased())", text: LF("%1$@: the last read failed (%2$@); the reading before it is used.", repo, error),
                                 product: repo, isCaveat: true))
        }
        return DailyBriefBuilder.finish(.agents, lines: lines, readAt: report.readAt, source: source, gaps: gaps)
    }
}
