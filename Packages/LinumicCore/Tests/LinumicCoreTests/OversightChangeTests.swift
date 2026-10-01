import Foundation
import Testing
@testable import LinumicCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func snap(ci: RepositorySnapshot.CIConclusion? = nil, alerts: Int? = nil, protected: Bool? = nil) -> RepositorySnapshot {
    RepositorySnapshot(slug: "o/r", defaultBranch: "main", ciConclusion: ci,
                       security: .init(dependabotAlerts: alerts, defaultBranchProtected: protected, observedAt: now), fetchedAt: now)
}

private func local(modified: Int?, diverged: Bool) -> LocalGitStatus {
    LocalGitStatus(path: "/p", branch: "main", localTip: "a",
                   remoteTip: diverged ? "b" : "a", modifiedTrackedFiles: modified, scannedAt: now)
}

@Suite("Oversight change detection")
struct OversightChangeTests {

    @Test func firstSweepIsSilent() {
        let after = [OversightRepo(slug: "o/r", snapshot: snap(alerts: 3))]
        #expect(OversightChangeDetector.changes(before: [], after: after).isEmpty, "populating the register must not alarm")
    }

    @Test func reportsNewSecurityAlertsOnlyWhenIncreased() {
        let before = [OversightRepo(slug: "o/r", snapshot: snap(alerts: 1))]
        let up = [OversightRepo(slug: "o/r", snapshot: snap(alerts: 4))]
        let down = [OversightRepo(slug: "o/r", snapshot: snap(alerts: 0))]
        let kindsUp = OversightChangeDetector.changes(before: before, after: up).map(\.kind)
        #expect(kindsUp == [.newSecurityAlerts])
        #expect(OversightChangeDetector.changes(before: before, after: down).contains { $0.kind == .newSecurityAlerts } == false)
    }

    @Test func detectsCiBreakAndRecovery() {
        let passing = [OversightRepo(slug: "o/r", snapshot: snap(ci: .success))]
        let failing = [OversightRepo(slug: "o/r", snapshot: snap(ci: .failure))]
        #expect(OversightChangeDetector.changes(before: passing, after: failing).map(\.kind) == [.ciBroke])
        #expect(OversightChangeDetector.changes(before: failing, after: passing).map(\.kind) == [.ciFixed])
    }

    @Test func detectsBranchLosingProtection() {
        let before = [OversightRepo(slug: "o/r", snapshot: snap(protected: true))]
        let after = [OversightRepo(slug: "o/r", snapshot: snap(protected: false))]
        #expect(OversightChangeDetector.changes(before: before, after: after).map(\.kind) == [.branchUnprotected])
    }

    @Test func detectsLocalUncommittedAndDivergence() {
        let clean = [OversightRepo(slug: "o/r", local: local(modified: 0, diverged: false))]
        let dirty = [OversightRepo(slug: "o/r", local: local(modified: 2, diverged: true))]
        let kinds = Set(OversightChangeDetector.changes(before: clean, after: dirty).map(\.kind))
        #expect(kinds == [.uncommittedAppeared, .divergedFromOrigin])
    }

    @Test func detectsNewRepositoryOnlyAfterFirstSweep() {
        let before = [OversightRepo(slug: "o/a", snapshot: snap())]
        let after = [OversightRepo(slug: "o/a", snapshot: snap()), OversightRepo(slug: "o/b", snapshot: snap())]
        let changes = OversightChangeDetector.changes(before: before, after: after)
        #expect(changes.map(\.kind) == [.newRepository])
        #expect(changes.first?.slug == "o/b")
    }

    @Test func securityChangeIsImportantLocalIsNot() {
        #expect(OversightChange(kind: .newSecurityAlerts, slug: "o/r", detectedAt: now).isImportant)
        #expect(OversightChange(kind: .ciBroke, slug: "o/r", detectedAt: now).isImportant)
        #expect(OversightChange(kind: .uncommittedAppeared, slug: "o/r", detectedAt: now).isImportant == false)
    }
}
