import Foundation

// MARK: - Operational readiness (آمادگی عملیاتی)
//
// One fixed list of checks, asked of every product, each answered only from what the app already read or recorded:
// is CI green, does a pull request wait, are the platforms level, is it monitored, is its signing key in a backup, was a
// restore tested, was its ledger reviewed, is an obligation due, is the copy on this Mac the release. Every answer
// carries its sentence, its source and its date, as a Fact does.
//
// The rule that matters more than coverage: a check that was not read is Unknown, with the reading that is missing.
// Unknown never counts as passed, is never shown green, and a product whose checks are mostly unknown reads as "not
// known", not as ready. Pure: nothing is fetched or stored here.

/// The checks, in the order they are shown. The list is the same for every product.
public enum ReadinessCheckID: String, CaseIterable, Sendable, Hashable, Identifiable {
    case ci, pullRequests, level, monitoring, signingKey, restoreTest, ledgerReview, obligations, installed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ci: L("CI on the default branch")
        case .pullRequests: L("Pull requests waiting")
        case .level: L("Platforms level")
        case .monitoring: L("Monitoring")
        case .signingKey: L("Signing key in a backup")
        case .restoreTest: L("Restore test")
        case .ledgerReview: L("Ledger reviewed")
        case .obligations: L("Obligations and deadlines")
        case .installed: L("Installed on this Mac")
        }
    }
}

public enum ReadinessState: String, CaseIterable, Sendable, Hashable {
    /// Read, and it is as it should be.
    case passed
    /// Read, and something is worth a look (old, differing, due soon), but nothing is broken.
    case needsAttention
    /// Read, and it is wrong or missing.
    case failed
    /// Not read, or no evidence: never passed, never green.
    case unknown
    /// The check has nothing to ask of this product (no repository, no server, no Mac app). Not counted.
    case notApplicable

    public var title: String {
        switch self {
        case .passed: L("Passed")
        case .needsAttention: L("Needs attention")
        case .failed: L("Failed")
        case .unknown: L("Unknown")
        case .notApplicable: L("Not applicable")
        }
    }
}

/// The date of the evidence: when a reading was made, or the day a fact was recorded.
public enum ReadinessDate: Hashable, Sendable {
    case read(Date)
    case day(KeyDay)
}

/// One check of one product, as a Fact: what was found, where and when.
public struct ReadinessResult: Hashable, Sendable, Identifiable {
    public var check: ReadinessCheckID
    public var state: ReadinessState
    /// The evidence in one sentence; for Unknown, which reading is missing.
    public var evidence: String
    /// Where it was read, or where it would be recorded. Never empty.
    public var source: String
    /// Nil when nothing was read.
    public var date: ReadinessDate?

    public var id: ReadinessCheckID { check }

    public init(_ check: ReadinessCheckID, _ state: ReadinessState, _ evidence: String, source: String, date: ReadinessDate? = nil) {
        self.check = check
        self.state = state
        self.evidence = evidence
        self.source = source
        self.date = date
    }
}

/// How a product stands over all its checks. Ordered weakest first: what is known to be wrong, then what is worth a
/// look, then what is not known, then what is known and fine.
public enum ReadinessStanding: Int, CaseIterable, Sendable, Hashable, Comparable {
    /// At least one check failed.
    case failing
    /// Nothing failed, at least one check needs attention.
    case attention
    /// Nothing known to be wrong, but more checks are unknown than known (or none is known): not known, not ready.
    case notKnown
    /// Nothing known to be wrong and most checks known, but some are unknown: not called ready.
    case partlyKnown
    /// Every applicable check was read and passed.
    case ready

    public static func < (a: ReadinessStanding, b: ReadinessStanding) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .failing: L("Failing")
        case .attention: L("Needs attention")
        case .notKnown: L("Not known")
        case .partlyKnown: L("Partly known")
        case .ready: L("Ready")
        }
    }
}

/// Counts per state. There is no score: a ratio would hide the unknowns, so they are counted on their own, and the
/// denominator is the checks that apply.
public struct ReadinessSummary: Hashable, Sendable {
    public var passed = 0
    public var needsAttention = 0
    public var failed = 0
    public var unknown = 0
    public var notApplicable = 0

    public init(_ results: [ReadinessResult]) {
        for r in results {
            switch r.state {
            case .passed: passed += 1
            case .needsAttention: needsAttention += 1
            case .failed: failed += 1
            case .unknown: unknown += 1
            case .notApplicable: notApplicable += 1
            }
        }
    }

    /// Checks that apply to the product: everything but "not applicable".
    public var applicable: Int { passed + needsAttention + failed + unknown }
    /// Checks that were read, whatever they found.
    public var known: Int { passed + needsAttention + failed }

    public var standing: ReadinessStanding {
        if failed > 0 { return .failing }
        if needsAttention > 0 { return .attention }
        if known == 0 || unknown > known { return .notKnown }
        if unknown > 0 { return .partlyKnown }
        return .ready
    }

    /// "5 of 8 known · 4 passed · 1 failed · 3 unknown". Unknown is always said when there is any.
    public var headline: String {
        guard applicable > 0 else { return L("No check applies") }
        var parts = [LF("%1$ld of %2$ld known", known, applicable)]
        if passed > 0 { parts.append(LF("%ld passed", passed)) }
        if failed > 0 { parts.append(LF("%ld failed", failed)) }
        if needsAttention > 0 { parts.append(LF("%ld need attention", needsAttention)) }
        if unknown > 0 { parts.append(LF("%ld unknown", unknown)) }
        return parts.joined(separator: " · ")
    }
}

/// One product's scorecard.
public struct ProductReadiness: Hashable, Sendable, Identifiable {
    public var productID: String
    /// The product's own name (never translated).
    public var title: String
    /// One result per check, in `ReadinessCheckID.allCases` order.
    public var results: [ReadinessResult]

    public var id: String { productID }
    public var summary: ReadinessSummary { ReadinessSummary(results) }
    public func result(_ check: ReadinessCheckID) -> ReadinessResult? { results.first { $0.check == check } }

    /// The checks to look at first: failed, then needing attention.
    public var concerns: [ReadinessResult] {
        results.filter { $0.state == .failed } + results.filter { $0.state == .needsAttention }
    }
}

/// Every product, weakest first. Archived projects are listed apart, so they never push an active one down.
public struct ReadinessPortfolio: Hashable, Sendable {
    /// In focus and maintenance.
    public var active: [ProductReadiness]
    public var archived: [ProductReadiness]

    public func count(_ standing: ReadinessStanding) -> Int { active.count { $0.summary.standing == standing } }
}

/// What the scorecard is built from, as the App holds it. Nil means "not read on this device", never "none".
public struct ReadinessInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// The Products page's cards: level, pull requests, CI and Monitor health, each with its source and read time.
    public var cards: [ProductCard]
    /// The ledgers as the Desk last read them.
    public var ledgers: [DeskSourceStatus]
    /// The Keys & Backups registry; nil when keys-registry.json could not be read.
    public var keys: KeysRegistry?
    /// The key files' dates on this Mac, when they were checked (empty on iPhone and iPad).
    public var keyResults: [String: KeyCheckResult]
    /// The obligations register; nil when obligations.json could not be read (the owner's dates and Done marks are missing).
    public var obligations: ObligationsRegister?
    /// The continuity export log; nil when it was not read here.
    public var continuity: ContinuityLog?
    /// The products' Mac apps against their newest release; nil where /Applications is not read (iPhone and iPad).
    public var installed: [InstalledAppStatus]?

    public init(now: Date, calendar: Calendar = KeyDay.calendar, cards: [ProductCard], ledgers: [DeskSourceStatus] = [],
                keys: KeysRegistry? = nil, keyResults: [String: KeyCheckResult] = [:], obligations: ObligationsRegister? = nil,
                continuity: ContinuityLog? = nil, installed: [InstalledAppStatus]? = nil) {
        self.now = now
        self.calendar = calendar
        self.cards = cards
        self.ledgers = ledgers
        self.keys = keys
        self.keyResults = keyResults
        self.obligations = obligations
        self.continuity = continuity
        self.installed = installed
    }
}

public enum ReadinessRules {
    /// A pull request that is not a draft and was opened more than this many days ago has waited long. No rule of the
    /// app set this before; 14 days is the default the scorecard was asked for (docs/readiness.md).
    public static let pullWaitingDays = 14
    /// The owner's weekly review (`CenterBuilder.reviewAfterDays`).
    public static var ledgerReviewDays: Int { CenterBuilder.reviewAfterDays }
    /// A restore test older than this is due again (`KeysRules.restoreTestMaxDays`).
    public static var restoreTestMaxDays: Int { KeysRules.restoreTestMaxDays }
    /// An obligation due within this many days needs attention: the register's own 14-day alert window.
    public static let obligationSoonDays = 14
    /// How long a GitHub reading (CI, pull requests) counts as current: the automation's own window for the Release Center.
    public static var releasesWindow: TimeInterval { DataFreshness.staleWindow(AutomationCatalog.spec(.releases)) }
    /// How long a Monitor reading counts as current: the automation's own window for the Monitor.
    public static var monitorWindow: TimeInterval { DataFreshness.staleWindow(AutomationCatalog.spec(.monitor)) }
    /// The platforms an app is installed on: a product with one of these has something to level and to sign.
    static let appPlatforms: Set<Platform> = [.android, .iOS, .macOS, .windows, .desktop, .watchOS]
    /// The parts that answer on a public address: a product with one of these has something to monitor.
    static let servedPlatforms: Set<Platform> = [.web, .backend]
}

public enum ReadinessBuilder {
    /// One scorecard per card, in the cards' order.
    public static func build(_ input: ReadinessInput) -> [ProductReadiness] {
        input.cards.map { card in
            ProductReadiness(productID: card.id, title: card.product.title, results: [
                ci(card, input), pullRequests(card, input), level(card), monitoring(card, input), signingKey(card, input),
                restoreTest(card, input), ledgerReview(card, input), obligations(card, input), installed(card, input),
            ])
        }
    }

    /// Weakest first among the active projects (failing, needing attention, not known, partly known, ready; then more
    /// failures, more attention, more unknowns; then focus before maintenance; then the given order). Archived apart.
    public static func portfolio(_ all: [ProductReadiness], tier: (String) -> CenterTier = CenterTier.default(forProduct:)) -> ReadinessPortfolio {
        func sorted(_ list: [(offset: Int, element: ProductReadiness)]) -> [ProductReadiness] {
            list.sorted { a, b in
                let (x, y) = (a.element.summary, b.element.summary)
                let ka = (x.standing.rawValue, -x.failed, -x.needsAttention, -x.unknown, tier(a.element.productID) == .focus ? 0 : 1, a.offset)
                let kb = (y.standing.rawValue, -y.failed, -y.needsAttention, -y.unknown, tier(b.element.productID) == .focus ? 0 : 1, b.offset)
                return ka < kb
            }
            .map(\.element)
        }
        let indexed = Array(all.enumerated())
        return ReadinessPortfolio(active: sorted(indexed.filter { tier($0.element.productID) != .archived }),
                                  archived: sorted(indexed.filter { tier($0.element.productID) == .archived }))
    }

    // MARK: Shared

    static var releaseCenter: String { L("Release Center") }
    static var notRecorded: String { L("Not recorded in Linumic OS") }

    /// A reading that passed but is older than its window is not counted as passed: what was true then may not be now.
    /// A reading that found something wrong stays as it is, however old: old bad news holds until a new reading clears it.
    static func current(_ result: ReadinessResult, window: TimeInterval, now: Date) -> ReadinessResult {
        guard result.state == .passed, case .read(let at)? = result.date, now.timeIntervalSince(at) > window else { return result }
        var out = result
        out.state = .unknown
        out.evidence = LF("%1$@ That was read more than %2$ld hours ago, so it is not counted as passed until it is read again.",
                          result.evidence, max(1, Int(now.timeIntervalSince(at) / 3600)))
        return out
    }

    static func list(_ names: [String]) -> String { names.joined(separator: L(", ")) }

    /// "first (and 2 more)".
    static func firstAndMore(_ texts: [String]) -> String {
        guard let first = texts.first else { return "" }
        return texts.count > 1 ? first + LF(" (and %ld more)", texts.count - 1) : first
    }

    static func hasAppPlatform(_ card: ProductCard) -> Bool {
        card.product.slots.contains { ReadinessRules.appPlatforms.contains($0.platform) }
    }

    // MARK: 1. CI on the default branch

    static func ci(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        switch card.ci {
        case .unknown(let why):
            return ReadinessResult(.ci, .unknown, why, source: releaseCenter)
        case .none(let why, _, _):
            return ReadinessResult(.ci, .notApplicable, why, source: releaseCenter)
        case .known(let ci, let source, let at):
            let date = at.map(ReadinessDate.read)
            if !ci.failing.isEmpty {
                return ReadinessResult(.ci, .failed, LF("CI is failing on the default branch of %@.", list(ci.failing)), source: source, date: date)
            }
            if !ci.running.isEmpty {
                return ReadinessResult(.ci, .unknown, LF("CI is still running on the default branch of %@; its result is not known yet.", list(ci.running)),
                                       source: source, date: date)
            }
            if ci.passing.isEmpty {
                return ReadinessResult(.ci, .needsAttention, LF("No CI run was found on the default branch of %@, so nothing checks it.", list(ci.noRuns)),
                                       source: source, date: date)
            }
            var text = LF("CI passed on the default branch of %@.", list(ci.passing))
            if !ci.noRuns.isEmpty { text += " " + LF("No CI run on %@.", list(ci.noRuns)) }
            return current(ReadinessResult(.ci, .passed, text, source: source, date: date), window: ReadinessRules.releasesWindow, now: input.now)
        }
    }

    // MARK: 2. Pull requests waiting

    static func pullRequests(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        switch card.pulls {
        case .unknown(let why):
            return ReadinessResult(.pullRequests, .unknown, why, source: releaseCenter)
        case .none(let why, _, _):
            return ReadinessResult(.pullRequests, .notApplicable, why, source: releaseCenter)
        case .known(let p, let source, let at):
            let date = at.map(ReadinessDate.read)
            func fresh(_ text: String) -> ReadinessResult {
                current(ReadinessResult(.pullRequests, .passed, text, source: source, date: date), window: ReadinessRules.releasesWindow, now: input.now)
            }
            guard p.open > 0 else { return fresh(L("No open pull request.")) }
            let today = KeyDay(input.now, calendar: input.calendar)
            let waiting = p.pulls.filter { !$0.pull.isDraft }
            let aged = waiting.compactMap { pull in pull.pull.createdAt.map { (pull, KeyDay($0, calendar: input.calendar)) } }
                .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            let old = aged.filter { $0.1.days(until: today) > ReadinessRules.pullWaitingDays }
            if let oldest = old.first {
                return ReadinessResult(.pullRequests, .needsAttention,
                                       LF("%1$ld of %2$ld open pull requests have waited more than %3$ld days. The oldest is %4$@, opened %5$@ (%6$ld days ago).",
                                          old.count, p.open, ReadinessRules.pullWaitingDays, oldest.0.id, oldest.1.description, oldest.1.days(until: today)),
                                       source: source, date: date)
            }
            // Only a count was read for some repository, or GitHub gave no opening day: how long they wait is not known.
            if p.pulls.count < p.open || aged.count < waiting.count {
                return ReadinessResult(.pullRequests, .unknown,
                                       LF("%ld open. When each was opened was not read (a count only), so how long they have waited is not known.", p.open),
                                       source: source, date: date)
            }
            guard let oldest = aged.first else { return fresh(LF("%ld open, all drafts: none waits for a merge.", p.open)) }
            return fresh(LF("%1$ld open, none waiting more than %2$ld days. The oldest is %3$@, opened %4$@.",
                            p.open, ReadinessRules.pullWaitingDays, oldest.0.id, oldest.1.description))
        }
    }

    // MARK: 3. Platforms level

    static func level(_ card: ProductCard) -> ReadinessResult {
        let source = L("Projects: the level rule over the compared platforms")
        // The oldest reading the rule stands on, so the date never flatters it.
        let times = card.slots.filter(\.slot.compared).flatMap { [$0.live.readAt, $0.build.readAt, $0.main.readAt] }.compactMap { $0 }
        let date = times.min().map(ReadinessDate.read)
        switch card.level {
        case .level:
            return ReadinessResult(.level, .passed, L("Every compared platform was read: the same versions, and no build is behind main."),
                                   source: source, date: date)
        case .notLevel(let findings):
            return ReadinessResult(.level, .needsAttention, firstAndMore(findings.map(\.text)), source: source, date: date)
        case .unknown(let parts):
            return ReadinessResult(.level, .unknown, LF("Not read, so not known: %@", firstAndMore(parts)), source: source, date: date)
        case .nothingShipped:
            return ReadinessResult(.level, .notApplicable, L("No compared platform has a build or a store version yet."), source: source, date: date)
        case .nothingCompared:
            // Never passed. With an app platform listed, nothing of it was read: unknown. With none listed, the page has
            // nothing to level (which says what is listed, not what the project is).
            return hasAppPlatform(card)
                ? ReadinessResult(.level, .unknown, L("No platform of this project is compared: no store listing, release or version file of it is read, so whether its platforms are level is not known."), source: source)
                : ReadinessResult(.level, .notApplicable, L("The Projects page lists no app platform for this project, so there is nothing to level."), source: source)
        }
    }

    // MARK: 4. Monitoring

    static func monitoring(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        let monitor = L("Monitor")
        switch card.health {
        case .unknown(let why):
            return ReadinessResult(.monitoring, .unknown, why, source: monitor)
        case .none(let why, _, _):
            // Nothing is monitored. That is a gap only when the product has a part that answers on a public address.
            let served = card.product.slots.contains { ReadinessRules.servedPlatforms.contains($0.platform) }
            return served
                ? ReadinessResult(.monitoring, .needsAttention, L("The Projects page lists a web or server part for this project, but no public address of it is monitored."), source: L("Monitor catalogue"))
                : ReadinessResult(.monitoring, .notApplicable, why, source: L("Monitor catalogue"))
        case .known(let h, let source, let at):
            let date = at.map(ReadinessDate.read)
            if h.down > 0 {
                return ReadinessResult(.monitoring, .failed, LF("%1$ld of %2$ld checks down.", h.down, h.total), source: source, date: date)
            }
            if h.degraded > 0 {
                return ReadinessResult(.monitoring, .needsAttention, LF("%1$ld of %2$ld checks slow, none down.", h.degraded, h.total), source: source, date: date)
            }
            if h.unchecked > 0 {
                return ReadinessResult(.monitoring, .unknown, LF("%1$ld of %2$ld addresses have not been checked yet.", h.unchecked, h.total), source: source, date: date)
            }
            return current(ReadinessResult(.monitoring, .passed, LF("All %ld checks up.", h.total), source: source, date: date),
                           window: ReadinessRules.monitorWindow, now: input.now)
        }
    }

    // MARK: 5. Signing key in a backup

    static func signingKey(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        let source = L("Keys & Backups registry (keys-registry.json)")
        guard let registry = input.keys else {
            return ReadinessResult(.signingKey, .unknown, L("The Keys & Backups registry could not be read on this device."), source: source)
        }
        let domain = card.product.deskDomain
        let keys = registry.keys.filter { $0.product != nil && !$0.isDeleted && $0.kind.needsBackup && DeskDomain.named($0.product) == domain }
        // No key on record says nothing either way (the Projects page may list no platform for a project that has an app,
        // as for SODER-HAKEM, whose key is recorded): unknown, never "nothing to sign".
        guard !keys.isEmpty else {
            return ReadinessResult(.signingKey, .unknown, L("The Keys & Backups registry records no key for this project, so whether it has a signing key, and whether that key is in a backup, is not known."), source: source)
        }
        let recorded = keys.map(\.recordedOn).max().map(ReadinessDate.day)
        let states = keys.map { ($0, KeysRules.backupState($0, registry: registry, result: input.keyResults[$0.id], calendar: input.calendar)) }
        let unbacked = states.filter { $0.1 == .notBackedUp }.map(\.0)
        if !unbacked.isEmpty {
            return ReadinessResult(.signingKey, .failed, LF("%1$ld of %2$ld keys are in no backup: %3$@.", unbacked.count, keys.count, list(unbacked.map { L($0.title) })),
                                   source: source, date: recorded)
        }
        if let missing = keys.first(where: { if case .missing? = input.keyResults[$0.id]?.status { true } else { false } }) {
            return ReadinessResult(.signingKey, .needsAttention, LF("%@ is in a backup, but it is not on this Mac where the registry says it is.", L(missing.title)),
                                   source: L("File check on this Mac (date and size only)"), date: recorded)
        }
        if let changed = states.first(where: { if case .changedAfterBackup = $0.1 { true } else { false } }) {
            return ReadinessResult(.signingKey, .needsAttention, LF("%@ changed after its newest backup, so that backup may be stale.", L(changed.0.title)),
                                   source: L("File check on this Mac (date and size only)"), date: recorded)
        }
        // Every key is in a backup. The weakest of them decides: for each key its newest restore test, then the oldest of those.
        let tests = keys.map { key in key.backupIDs.compactMap(registry.backup).compactMap(\.lastRestoreTest).map(\.on).max() }
        guard let weakest = tests.compactMap({ $0 }).min(), !tests.contains(nil) else {
            return ReadinessResult(.signingKey, .needsAttention, LF("%ld keys recorded, each in a backup, but no restore test is recorded for a backup that holds them.", keys.count),
                                   source: source, date: recorded)
        }
        let age = weakest.days(until: KeyDay(input.now, calendar: input.calendar))
        if age > ReadinessRules.restoreTestMaxDays {
            return ReadinessResult(.signingKey, .needsAttention,
                                   LF("%1$ld keys recorded, each in a backup. The backup was last restore-tested on %2$@, more than %3$ld days ago.", keys.count, weakest.description, ReadinessRules.restoreTestMaxDays),
                                   source: source, date: .day(weakest))
        }
        return ReadinessResult(.signingKey, .passed, LF("%1$ld keys recorded, each in a backup that was restore-tested on %2$@.", keys.count, weakest.description),
                               source: source, date: .day(weakest))
    }

    // MARK: 6. Restore test (of the product's data)

    static func restoreTest(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        // Linumic OS's own data: the continuity export, opened outside this Mac, is its restore test.
        // For every other project nothing is recorded, so nothing is known: never passed, and never "nothing to restore".
        guard card.id == "linumicos" else {
            return ReadinessResult(.restoreTest, .unknown,
                                   LF("Linumic OS holds no record of a restore test of %@'s data. It records restore tests of the key backups and of its own export only.", card.product.title),
                                   source: notRecorded)
        }
        let source = "continuity.json"
        guard let log = input.continuity else {
            return ReadinessResult(.restoreTest, .unknown, ObligationLiveSource.continuity.notReadText, source: source)
        }
        let checks = log.exports.flatMap { export in export.outsideChecks.map { (export, $0) } }
        guard let (export, check) = checks.max(by: { ($0.1.on, $0.1.enteredAt) < ($1.1.on, $1.1.enteredAt) }) else {
            return ReadinessResult(.restoreTest, .failed, L("No export of Linumic OS's data has been opened outside this Mac, so no restore is proven."), source: source)
        }
        let age = check.on.days(until: KeyDay(input.now, calendar: input.calendar))
        if age > ReadinessRules.restoreTestMaxDays {
            return ReadinessResult(.restoreTest, .needsAttention,
                                   LF("The last export opened outside this Mac was %1$@ on %2$@, more than %3$ld days ago.", export.fileName, check.on.description, ReadinessRules.restoreTestMaxDays),
                                   source: source, date: .day(check.on))
        }
        return ReadinessResult(.restoreTest, .passed, LF("%1$@ was opened outside this Mac on %2$@.", export.fileName, check.on.description),
                               source: source, date: .day(check.on))
    }

    // MARK: 7. Ledger reviewed

    static func ledgerReview(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        let domain = card.product.deskDomain
        guard let ledger = input.ledgers.first(where: { $0.source.kind == .priorities && $0.source.domain == domain }) else {
            return ReadinessResult(.ledgerReview, .unknown, LF("The Desk reads no PRIORITIES.md for %@, so when its ledger was last reviewed is not known.", card.product.title),
                                   source: L("The Desk's list of ledgers"))
        }
        let read = ledger.readAt.map(ReadinessDate.read)
        switch ledger.state {
        case .read(let open, _, _, let reviewedOn?):
            // A review day after today (a typo in the ledger) is not "minus two days ago".
            let age = max(0, reviewedOn.days(until: KeyDay(input.now, calendar: input.calendar)))
            return ReadinessResult(.ledgerReview, age > ReadinessRules.ledgerReviewDays ? .needsAttention : .passed,
                                   LF("Last reviewed on %1$@, %2$ld days ago (a review is due every %3$ld days). %4$ld open items.",
                                      reviewedOn.description, age, ReadinessRules.ledgerReviewDays, open),
                                   source: ledger.displayPath, date: .day(reviewedOn))
        case .read(_, _, _, nil):
            return ReadinessResult(.ledgerReview, .unknown, L("The ledger was read, but it has no review day line, so when it was last reviewed is not known."),
                                   source: ledger.displayPath, date: read)
        case .unreadable(let why):
            return ReadinessResult(.ledgerReview, .unknown, LF("The ledger could not be read: %@", why), source: ledger.displayPath, date: read)
        case .unsupported, .notRead, .notGranted, .notFound, .report:
            return ReadinessResult(.ledgerReview, .unknown, L("The ledger was not read on this device, so when it was last reviewed is not known."),
                                   source: ledger.displayPath, date: read)
        }
    }

    // MARK: 8. Obligations and deadlines

    static func obligations(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        let register = L("Obligations register")
        guard let all = input.obligations else {
            return ReadinessResult(.obligations, .unknown, L("obligations.json could not be read, so the dates and Done marks entered in the app are missing."), source: register)
        }
        let domain = card.product.deskDomain
        // Nearest first: the register is sorted by due day, undated last.
        let open = all.obligations.filter { !$0.isClosed && $0.product != nil && DeskDomain.named($0.product) == domain }
        // A live source of this product that was not read leaves its rows out: unknown, not none.
        var unread: [ObligationLiveSource] = []
        if card.product.licence != nil, all.unread.contains(.licences) { unread.append(.licences) }
        if card.id == "linumicos", all.unread.contains(.continuity) { unread.append(.continuity) }
        let today = KeyDay(input.now, calendar: input.calendar)
        func result(_ state: ReadinessState, _ text: String, _ o: Obligation) -> ReadinessResult {
            ReadinessResult(.obligations, state, text, source: LF("Obligations register: %@", o.source), date: o.recordedOn.map(ReadinessDate.day))
        }
        let undated = open.filter { $0.due == nil }
        if let nearest = open.first(where: { $0.due != nil }), let due = nearest.due {
            let left = today.days(until: due)
            if left < 0 {
                return result(.failed, LF("%1$ld open. Overdue by %2$ld days: %3$@ (due %4$@).", open.count, -left, nearest.displayTitle, due.description), nearest)
            }
            if left <= ReadinessRules.obligationSoonDays {
                return result(.needsAttention, LF("%1$ld open. Due in %2$ld days: %3$@ (%4$@).", open.count, left, nearest.displayTitle, due.description), nearest)
            }
            if let first = undated.first {
                return result(.needsAttention, LF("%1$ld open, %2$ld of them with no date recorded. The first of those: %3$@.", open.count, undated.count, first.displayTitle), first)
            }
            if let source = unread.first { return ReadinessResult(.obligations, .unknown, source.notReadText, source: register) }
            return result(.passed, LF("%1$ld open, none due within %2$ld days. The nearest: %3$@ (%4$@).", open.count, ReadinessRules.obligationSoonDays, nearest.displayTitle, due.description), nearest)
        }
        if let first = undated.first {
            return result(.needsAttention, LF("%1$ld open, %2$ld of them with no date recorded. The first of those: %3$@.", open.count, undated.count, first.displayTitle), first)
        }
        if let source = unread.first { return ReadinessResult(.obligations, .unknown, source.notReadText, source: register) }
        // Nothing recorded is not proof that nothing is due, so it is not counted as passed.
        return ReadinessResult(.obligations, .notApplicable, LF("The register holds no open obligation for %@. That is what is recorded, not proof that nothing is due.", card.product.title),
                               source: register, date: .read(all.builtAt))
    }

    // MARK: 9. Installed on this Mac

    static func installed(_ card: ProductCard, _ input: ReadinessInput) -> ReadinessResult {
        let applications = L("/Applications on this Mac")
        guard InstalledAppCatalog.apps.contains(where: { $0.productID == card.id }) else {
            return ReadinessResult(.installed, .notApplicable, L("No Mac app of this project is compared with a release."), source: L("Installed apps catalogue"))
        }
        guard let statuses = input.installed?.filter({ $0.spec.productID == card.id }), !statuses.isEmpty else {
            return ReadinessResult(.installed, .unknown, L("/Applications is read on the Mac only, so what is installed is not known here."), source: applications)
        }
        func state(_ verdict: InstalledVerdict) -> ReadinessState {
            switch verdict {
            case .current: .passed
            case .behind, .testBuild: .needsAttention
            // Newer than every release: not a release. With no release at all there is nothing to compare with.
            case .unreleased(_, let release): release == nil ? .notApplicable : .needsAttention
            // The same version, built who knows how: grey on the Releases tab, unknown here.
            case .sameVersion, .unknown: .unknown
            case .notInstalled: .notApplicable
            }
        }
        // The weakest app decides (a product has one Mac app today).
        let order: [ReadinessState] = [.needsAttention, .unknown, .passed, .notApplicable]
        let worst = statuses.min { (order.firstIndex(of: state($0.verdict)) ?? 0) < (order.firstIndex(of: state($1.verdict)) ?? 0) }!
        return ReadinessResult(.installed, state(worst.verdict), worst.verdict.sentence, source: worst.installed.source ?? applications,
                               date: worst.installed.readAt.map(ReadinessDate.read))
    }
}
