import Foundation

/// A change noticed between two oversight sweeps of the same repository, e.g. a new security alert
/// or CI that started failing. Compared per repository by slug. The first sweep (no prior data) is
/// silent, so populating the register doesn't raise a flood of "new" alerts.
public struct OversightChange: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Open security alerts increased. `from`/`to` hold the counts.
        case newSecurityAlerts
        /// CI on the default branch started failing.
        case ciBroke
        /// CI on the default branch recovered.
        case ciFixed
        /// The default branch lost its protection rule.
        case branchUnprotected
        /// Tracked files now have uncommitted changes locally. `to` holds the count.
        case uncommittedAppeared
        /// The local branch diverged from origin (unpushed/unfetched work).
        case divergedFromOrigin
        /// A repository appeared that wasn't in the register before.
        case newRepository
    }

    public var id: UUID
    public var kind: Kind
    public var slug: String
    public var from: String?
    public var to: String?
    public var detectedAt: Date

    public init(id: UUID = UUID(), kind: Kind, slug: String, from: String? = nil, to: String? = nil, detectedAt: Date) {
        self.id = id
        self.kind = kind
        self.slug = slug
        self.from = from
        self.to = to
        self.detectedAt = detectedAt
    }

    public var repoName: String { slug.split(separator: "/").last.map(String.init) ?? slug }

    public var message: String {
        switch kind {
        case .newSecurityAlerts: LF("%@: %@ open security alerts (was %@).", repoName, to ?? "?", from ?? "0")
        case .ciBroke: LF("%@: CI is now failing on the default branch.", repoName)
        case .ciFixed: LF("%@: CI is passing again.", repoName)
        case .branchUnprotected: LF("%@: the default branch is no longer protected.", repoName)
        case .uncommittedAppeared: LF("%@: %@ tracked files have uncommitted changes.", repoName, to ?? "?")
        case .divergedFromOrigin: LF("%@: the local branch has diverged from origin.", repoName)
        case .newRepository: LF("%@: new repository under oversight.", repoName)
        }
    }

    /// Worth an interruption: a new security alert or broken CI.
    public var isImportant: Bool {
        switch kind {
        case .newSecurityAlerts, .ciBroke: true
        default: false
        }
    }
}

public enum OversightChangeDetector {
    /// Compares two oversight registers and returns what changed. When `before` is empty (the very
    /// first sweep) nothing is reported, so the initial population is silent.
    public static func changes(before: [OversightRepo], after: [OversightRepo], at now: Date = .now) -> [OversightChange] {
        guard !before.isEmpty else { return [] }
        let old = Dictionary(before.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [OversightChange] = []

        for repo in after {
            func change(_ kind: OversightChange.Kind, _ from: String? = nil, _ to: String? = nil) -> OversightChange {
                OversightChange(kind: kind, slug: repo.slug, from: from, to: to, detectedAt: now)
            }
            guard let previous = old[repo.slug] else {
                result.append(change(.newRepository))
                continue
            }

            // GitHub-derived signals: only compare when both sweeps read a snapshot.
            if let newSnap = repo.snapshot, let oldSnap = previous.snapshot {
                if let newTotal = newSnap.security?.openAlertTotal, let oldTotal = oldSnap.security?.openAlertTotal, newTotal > oldTotal {
                    result.append(change(.newSecurityAlerts, String(oldTotal), String(newTotal)))
                }
                if newSnap.ciConclusion == .failure, oldSnap.ciConclusion != .failure {
                    result.append(change(.ciBroke))
                } else if newSnap.ciConclusion == .success, oldSnap.ciConclusion == .failure {
                    result.append(change(.ciFixed))
                }
                if newSnap.security?.defaultBranchProtected == false, oldSnap.security?.defaultBranchProtected == true {
                    result.append(change(.branchUnprotected))
                }
            }

            // Local-working-copy signals: only compare when both sweeps scanned locally.
            if let newLocal = repo.local, let oldLocal = previous.local {
                if (newLocal.modifiedTrackedFiles ?? 0) > 0, (oldLocal.modifiedTrackedFiles ?? 0) == 0 {
                    result.append(change(.uncommittedAppeared, nil, String(newLocal.modifiedTrackedFiles ?? 0)))
                }
                if newLocal.syncState == .diverged, oldLocal.syncState != .diverged {
                    result.append(change(.divergedFromOrigin))
                }
            }
        }
        return result
    }
}
