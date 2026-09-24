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
        }
    }

    /// Worth an interruption: something went live or was rejected.
    public var isImportant: Bool {
        kind == .nowLive || (kind == .phaseChanged && (to == ReviewPhase.rejected.rawValue || to == ReviewPhase.live.rawValue))
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
                if new.productionVersion != previous.productionVersion, let live = new.productionVersion {
                    result.append(change(.nowLive, previous.productionVersion, live))
                } else if new.reviewPhase != previous.reviewPhase {
                    result.append(change(.phaseChanged, previous.reviewPhase.rawValue, new.reviewPhase.rawValue))
                } else if new.latestSubmittedVersion != previous.latestSubmittedVersion, let pending = new.latestSubmittedVersion {
                    result.append(change(.newPending, previous.latestSubmittedVersion, pending))
                }
            }
        }
        return result
    }
}
