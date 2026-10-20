import Foundation

// MARK: - "Platforms not level"
//
// The owner: "nothing may be left behind; every platform must move equally". Within each track (an app's platforms, e.g.
// VELRO Ride on Android and iOS), comparing only the platforms people install (`ProductSlot.compared`):
//
//   1. Built versions differ: the platforms' newest builds are different version numbers.
//   2. Live versions differ: the versions live in the stores are different version numbers.
//   3. A platform has no build while another has one ("macOS: no build published; Windows 0.2.0").
//   4. A platform is behind the default branch: its newest build (or, without one, its live version) is a lower version
//      than the version file on main, or main has commits dated after the build and its newest commit is at least
//      `behindDays` days later. "Android 1.9.0 (2026-10-13) behind main 1.9.1".
//
// Only real version numbers are compared (a tag like "android-app" never is), and a live version that is only the
// inventory's record (the console was not read) is shown but not compared. A value that was not read makes the
// product's level Unknown, with the reason, unless a rule already found it not level: Unknown is never "level".

public enum LevelFindingKind: String, Hashable, Sendable, CaseIterable {
    case buildsDiffer, liveDiffer, missingBuild, behindMain
}

/// One fact that makes a product's platforms not level, worded with both sides.
public struct LevelFinding: Hashable, Sendable, Identifiable {
    public var kind: LevelFindingKind
    /// The track's title ("VELRO Ride").
    public var track: String
    /// The sentence, e.g. "Android 1.9.0 (2026-10-13) behind main 1.9.1".
    public var text: String
    /// What the fact is, without the parts that move every day (commit counts, days): for the Desk's "dismiss until it
    /// changes".
    public var key: String

    public var id: String { key }
}

public enum ProductLevelState: Hashable, Sendable {
    /// Every compared platform was read and none of the rules found anything.
    case level
    case notLevel([LevelFinding])
    /// Nothing found, but these parts were not read, so whether the platforms are level is not known.
    case unknown([String])
    /// No compared platform has a build or a live version (a product in development).
    case nothingShipped

    public var findings: [LevelFinding] { if case .notLevel(let f) = self { f } else { [] } }
    public var unknowns: [String] { if case .unknown(let u) = self { u } else { [] } }

    public var title: String {
        switch self {
        case .level: L("Platforms level")
        case .notLevel: L("Platforms not level")
        case .unknown: L("Level unknown")
        case .nothingShipped: L("Nothing shipped yet")
        }
    }
}

public enum ProductLevelRule {
    /// Main may be ahead of a build by commits for this many days before the build counts as behind (a build made today
    /// is not behind because a pull request was merged an hour later).
    public static let behindDays = 7

    public static func evaluate(_ tracks: [TrackReading]) -> ProductLevelState {
        var findings: [LevelFinding] = []
        var unknowns: [String] = []
        var anythingShipped = false
        var anyCompared = false
        for track in tracks {
            let compared = track.slots.filter(\.slot.compared)
            guard !compared.isEmpty else { continue }
            anyCompared = true
            let (f, u) = evaluate(track.track.title, compared)
            findings += f
            unknowns += u
            if compared.contains(where: { $0.build.isKnown || $0.live.isKnown }) { anythingShipped = true }
        }
        if !findings.isEmpty { return .notLevel(findings) }
        if !unknowns.isEmpty { return .unknown(unknowns) }
        if anyCompared, !anythingShipped { return .nothingShipped }
        return .level
    }

    /// The findings and the unread parts of one track's compared platforms.
    static func evaluate(_ track: String, _ slots: [SlotReading]) -> (findings: [LevelFinding], unknowns: [String]) {
        var findings: [LevelFinding] = []
        var unknowns: [String] = []
        func name(_ s: SlotReading) -> String { s.slot.platform.title }
        /// A value read from its source; the inventory's record of a live version is not one.
        func read(_ v: Sourced<VersionStamp>) -> VersionStamp? { v.value.flatMap { $0.unreadReason == nil ? $0 : nil } }

        // 1 and 2: different version numbers across platforms.
        for (kind, pick) in [(LevelFindingKind.buildsDiffer, { (s: SlotReading) in s.build }), (.liveDiffer, { (s: SlotReading) in s.live })] {
            let known = slots.compactMap { s in read(pick(s)).flatMap { v in v.semantic.map { (s, v, $0) } } }
            guard Set(known.map(\.2)).count > 1 else { continue }
            let list = known.map { "\(name($0.0)) \($0.1.labelWithDay)" }.joined(separator: L(", "))
            let key = "\(kind.rawValue):\(track):" + known.map { "\($0.0.slot.platform.rawValue)=\($0.2)" }.sorted().joined(separator: ",")
            findings.append(LevelFinding(kind: kind, track: track,
                                         text: kind == .buildsDiffer ? LF("Built versions differ: %@", list) : LF("Live versions differ: %@", list),
                                         key: key))
        }

        // 3: a platform with no build while another has one.
        let built = slots.filter { $0.build.isKnown }
        if !built.isEmpty {
            for s in slots {
                guard case .none(let why, _, _) = s.build else { continue }
                let others = built.map { "\(name($0)) \($0.build.value!.labelWithDay)" }.joined(separator: L(", "))
                findings.append(LevelFinding(kind: .missingBuild, track: track,
                                             text: LF("%1$@ has no build (%2$@), while %3$@", name(s), why, others),
                                             key: "missingBuild:\(track):\(s.slot.platform.rawValue)"))
            }
        }

        // 4: behind the default branch.
        for s in slots {
            guard let have = s.build.value ?? read(s.live) else { continue }
            let main = s.main.value
            let byVersion: Bool = {
                guard let h = have.semantic, let m = main?.semantic else { return false }
                return h < m
            }()
            let byAge: BehindMain? = s.behind.value.flatMap { $0.commits > 0 && $0.days >= behindDays ? $0 : nil }
            guard byVersion || byAge != nil else { continue }
            let text: String
            switch (byVersion, byAge) {
            case (true, let age?):
                text = LF("%1$@ %2$@ behind main %3$@ by %4$@, %5$ld days", name(s), have.labelWithDay, main!.label, age.commitsText, age.days)
            case (true, nil):
                text = LF("%1$@ %2$@ behind main %3$@", name(s), have.labelWithDay, main!.label)
            case (false, let age?):
                text = LF("%1$@ %2$@ behind main by %3$@, %4$ld days", name(s), have.labelWithDay, age.commitsText, age.days)
            case (false, nil):
                continue
            }
            findings.append(LevelFinding(kind: .behindMain, track: track, text: text,
                                         key: "behindMain:\(track):\(s.slot.platform.rawValue):\(have.label):\(main?.label ?? "-"):\(byAge == nil ? "version" : "age")"))
        }

        // What was not read.
        for s in slots {
            if case .unknown(let why) = s.build { unknowns.append(LF("%1$@ build: %2$@", name(s), why)) }
            if case .unknown(let why) = s.live { unknowns.append(LF("%1$@ in the store: %2$@", name(s), why)) }
            if let why = s.live.value?.unreadReason { unknowns.append(LF("%1$@ in the store: %2$@", name(s), why)) }
            if case .unknown(let why) = s.main { unknowns.append(LF("%1$@ on main: %2$@", name(s), why)) }
            if case .unknown(let why) = s.behind, s.build.isKnown { unknowns.append(LF("%1$@ commits since the build: %2$@", name(s), why)) }
        }
        return (findings, unknowns)
    }
}
