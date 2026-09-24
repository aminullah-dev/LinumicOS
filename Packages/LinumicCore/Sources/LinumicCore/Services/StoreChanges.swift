import Foundation

/// A change noticed between two console refreshes of the same store listing, e.g. a version that
/// left review and went live. Only listings whose previous values also came from a console API are
/// compared, so the first refresh after seed data (screenshots, public pages) doesn't raise alarms.
public struct StoreChange: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A new version is live (the production version changed).
        case nowLive
        /// The review phase changed, e.g. pending → rejected.
        case phaseChanged
        /// A different version is waiting (submitted or being prepared).
        case newPending
        /// A customer review arrived. `to` holds the stars, `from` the title.
        case newReview
        /// A TestFlight build finished processing. `to` holds its label.
        case buildReady
        /// A TestFlight build expires within a week. `to` holds its label, `from` the days left.
        case buildExpiring
    }

    public var id: UUID
    public var kind: Kind
    public var productID: String
    public var appName: String
    public var store: AppStore
    /// Raw values, so the message can be shown in whatever language the app is in.
    public var from: String?
    public var to: String?
    public var detectedAt: Date

    public init(id: UUID = UUID(), kind: Kind, productID: String, appName: String, store: AppStore, from: String?, to: String?, detectedAt: Date) {
        self.id = id
        self.kind = kind
        self.productID = productID
        self.appName = appName
        self.store = store
        self.from = from
        self.to = to
        self.detectedAt = detectedAt
    }

    /// Phases are stored by raw value; this turns one back into its title.
    private func phaseTitle(_ raw: String?) -> String { raw.flatMap(ReviewPhase.init(rawValue:))?.title ?? L("Unknown") }

    public var message: String {
        switch kind {
        case .nowLive: LF("%@ %@ is now live on %@.", appName, to ?? "", store.title)
        case .phaseChanged: LF("%@ on %@: %@ → %@", appName, store.title, phaseTitle(from), phaseTitle(to))
        case .newPending: LF("%@ %@ is waiting on %@.", appName, to ?? "", store.title)
        case .newReview: LF("New %@★ review of %@: %@", to ?? "?", appName, from ?? "")
        case .buildReady: LF("TestFlight build %@ of %@ is ready to test.", to ?? "", appName)
        case .buildExpiring: LF("TestFlight build %@ of %@ expires in %@ days.", to ?? "", appName, from ?? "?")
        }
    }

    /// Worth an interruption: something went live or was rejected.
    public var isImportant: Bool {
        switch kind {
        case .nowLive, .buildExpiring: true
        case .phaseChanged: to == ReviewPhase.rejected.rawValue || to == ReviewPhase.live.rawValue
        case .newReview: (to.flatMap(Int.init) ?? 5) <= 2
        case .newPending, .buildReady: false
        }
    }
}

public enum StoreChangeDetector {
    private static func fromConsole(_ l: StoreListing) -> Bool {
        l.verification.sources.contains {
            $0.reference.hasPrefix(StoreConsoleSync.ascReferencePrefix) || $0.reference.hasPrefix(StoreConsoleSync.playReferencePrefix)
        }
    }

    public static func changes(before: [Product], after: [Product], at now: Date = .now) -> [StoreChange] {
        let old = Dictionary(before.flatMap(\.storeListings).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [StoreChange] = []
        for product in after {
            for new in product.storeListings {
                guard let previous = old[new.id], fromConsole(previous), fromConsole(new) else { continue }
                let name = new.appName ?? product.name
                func change(_ kind: StoreChange.Kind, _ from: String?, _ to: String?) -> StoreChange {
                    StoreChange(kind: kind, productID: product.id, appName: name, store: new.store, from: from, to: to, detectedAt: now)
                }
                result += insightChanges(previous.insights, new.insights, change: change, at: now)
                if versionKey(new.productionVersion) != versionKey(previous.productionVersion), let live = new.productionVersion {
                    result.append(change(.nowLive, previous.productionVersion, live))
                } else if new.reviewPhase != previous.reviewPhase {
                    result.append(change(.phaseChanged, previous.reviewPhase.rawValue, new.reviewPhase.rawValue))
                } else if versionKey(new.latestSubmittedVersion) != versionKey(previous.latestSubmittedVersion), let pending = new.latestSubmittedVersion {
                    result.append(change(.newPending, previous.latestSubmittedVersion, pending))
                }
            }
        }
        return result
    }

    /// The versions a label names, ignoring how it's written: "10 (1.0.10)", "1.0.10" and
    /// "iOS 1.0.10" are the same version. Dotted versions are used when present, else every number.
    static func versionKey(_ label: String?) -> Set<String>? {
        guard let label else { return nil }
        let tokens = label.split(whereSeparator: { !($0.isNumber || $0 == ".") }).map(String.init).filter { $0.contains(where: \.isNumber) }
        let dotted = tokens.filter { $0.contains(".") }
        return Set(dotted.isEmpty ? tokens : dotted)
    }

    /// Reviews and builds are compared only when both reads included them, so the first read is silent.
    static func insightChanges(_ old: StoreInsights?, _ new: StoreInsights?, change: (StoreChange.Kind, String?, String?) -> StoreChange,
                               at now: Date) -> [StoreChange] {
        guard let new else { return [] }
        var result: [StoreChange] = []
        if let old, old.reviewsObservedAt != nil, new.reviewsObservedAt != nil {
            let seen = Set(old.reviews.map(\.id))
            for review in new.reviews where !seen.contains(review.id) {
                result.append(change(.newReview, review.title ?? review.body.map { String($0.prefix(60)) }, String(review.rating)))
            }
        }
        if let old, let oldAt = old.testBuildsObservedAt, new.testBuildsObservedAt != nil {
            let before = Dictionary(old.testBuilds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for build in new.testBuilds {
                let previous = before[build.id]
                // New and ready, or finished processing since the last read.
                if build.isUsable, previous?.isUsable != true { result.append(change(.buildReady, nil, build.label)) }
                if let days = build.daysUntilExpiry(from: now), previous?.daysUntilExpiry(from: oldAt) == nil {
                    result.append(change(.buildExpiring, String(days), build.label))
                }
            }
        }
        return result
    }
}
