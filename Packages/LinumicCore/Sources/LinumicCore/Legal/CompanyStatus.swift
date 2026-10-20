import Foundation

// MARK: - The company's status (registration, the seller of record per store, DSA)
//
// Three facts, each with its source and the day it was recorded or read, or Unknown with the reason. Nothing is
// inferred: the seller is what the store listing says (the public App Store lookup the app already runs sets it for the
// App Store; the inventory's record from the Play Console for Google Play, which the app does not read), registration
// is what the roadmap and the accounts record, and the EU Digital Services Act trader status stays Unknown until a
// source for it is recorded here.

/// A fact about the company, or Unknown.
public struct CompanyFact: Hashable, Sendable {
    /// The value as the source says it; nil is Unknown.
    public var value: String?
    /// Where it comes from; nil only when it is Unknown.
    public var source: String?
    /// The day it was recorded in that source.
    public var recordedOn: KeyDay?
    /// Why it is Unknown, when it is.
    public var unknownReason: String?

    public init(value: String?, source: String?, recordedOn: KeyDay?, unknownReason: String? = nil) {
        self.value = value
        self.source = source
        self.recordedOn = recordedOn
        self.unknownReason = unknownReason
    }

    public var isKnown: Bool { value != nil && source != nil }
}

/// Who a store says sells the apps, from the store listings in the inventory.
public struct StoreSellerFact: Hashable, Sendable, Identifiable {
    public var store: AppStore
    /// The seller names the listings carry, as written (distinct, in order of first appearance). Empty: Unknown.
    public var sellers: [String]
    /// Listings of this store, and how many of them carry no seller.
    public var listings: Int
    public var withoutSeller: Int
    /// Where the names come from.
    public var source: String
    /// The newest time a listing's seller was read from the store itself (the App Store lookup); nil when the app does
    /// not read it (Google Play), then `recordedOn` says when it was recorded.
    public var readAt: Date?
    public var recordedOn: KeyDay?
    /// Whether the names were read by the app (the lookup), not only recorded.
    public var isRead: Bool { readAt != nil }

    public var id: String { store.rawValue }

    public init(store: AppStore, sellers: [String], listings: Int, withoutSeller: Int, source: String, readAt: Date?, recordedOn: KeyDay?) {
        self.store = store
        self.sellers = sellers
        self.listings = listings
        self.withoutSeller = withoutSeller
        self.source = source
        self.readAt = readAt
        self.recordedOn = recordedOn
    }

    public var isKnown: Bool { !sellers.isEmpty }
}

public struct CompanyStatus: Hashable, Sendable {
    /// Whether the company is registered.
    public var registration: CompanyFact
    public var sellers: [StoreSellerFact]
    /// The EU Digital Services Act trader status declared in the stores.
    public var dsa: CompanyFact

    public init(registration: CompanyFact, sellers: [StoreSellerFact], dsa: CompanyFact) {
        self.registration = registration
        self.sellers = sellers
        self.dsa = dsa
    }

    public func seller(_ store: AppStore) -> StoreSellerFact? { sellers.first { $0.store == store } }
}

/// The facts recorded with a source (like `ObligationSeed`). Shown as written; the value is English and localized when
/// shown.
public enum CompanyStatusSeed {
    static let repo = "~/Projects/Multiplatform/Linumic/LinumicCommandCenter"
    static let memory = "~/.claude/projects/-Users-aminullahhashemi/memory"

    /// Not registered: the roadmap lists registering the company as the owner's decision, still to be made with a
    /// lawyer, and every store account is in the owner's own name.
    public static let registration = CompanyFact(
        value: "Not registered. The apps are sold under the owner's individual developer accounts.",
        source: "\(repo)/docs/company-os-roadmap.md §2 module 7 («ثبت‌نشدن شرکت») and §6 decision 2 («زمان ثبت شرکت … با وکیل»), recorded 2026-10-19; \(memory)/linumic-command-center.md:21 (Apple team 27RXPRW77S, Individual) and :40 (Google Play developer account, personal), recorded 2026-09-23; ObligationSeed accounts apple-developer and google-play (holder: personal)",
        recordedOn: KeyDay("2026-10-19"))

    /// No source records the trader status: Unknown, never "not a trader".
    public static let dsa = CompanyFact(
        value: nil, source: nil, recordedOn: nil,
        unknownReason: "No source records the trader status declared in App Store Connect or the Play Console, and the app reads neither for it.")
}

public enum CompanyStatusBuilder {
    /// The public lookup's reference prefix (`AppStoreLookupClient.lookupURL`): the source that sets `seller` live.
    static let lookupPrefix = "https://itunes.apple.com/lookup"

    public static func build(products: [Product], registration: CompanyFact = CompanyStatusSeed.registration,
                             dsa: CompanyFact = CompanyStatusSeed.dsa, calendar: Calendar = KeyDay.calendar) -> CompanyStatus {
        CompanyStatus(registration: registration,
                      sellers: [seller(.appStore, products: products, calendar: calendar), seller(.googlePlay, products: products, calendar: calendar)],
                      dsa: dsa)
    }

    static func seller(_ store: AppStore, products: [Product], calendar: Calendar) -> StoreSellerFact {
        let listings = products.flatMap(\.storeListings).filter { $0.store == store }
        var names: [String] = []
        var readAt: Date?
        var recorded: Date?
        var withoutSeller = 0
        for l in listings {
            guard let seller = l.seller?.trimmingCharacters(in: .whitespacesAndNewlines), !seller.isEmpty else {
                withoutSeller += 1
                continue
            }
            if !names.contains(seller) { names.append(seller) }
            let sources = l.verification.sources.filter { $0.kind == (store == .appStore ? .appStore : .googlePlay) }
            if store == .appStore, let lookup = sources.filter({ $0.reference.hasPrefix(lookupPrefix) }).map(\.observedAt).max() {
                readAt = max(readAt ?? lookup, lookup)
            }
            // When it was first recorded: the listing's earliest source of this store.
            if let first = sources.map(\.observedAt).min() { recorded = min(recorded ?? first, first) }
        }
        let source: String = switch store {
        case .appStore:
            readAt != nil
                ? L("Public App Store lookup (itunes.apple.com/lookup, sellerName), run by the Store listings job; the store listings in the inventory")
                : L("The store listings in the inventory (the public lookup has not set them on this device)")
        case .googlePlay:
            L("The store listings in the inventory, recorded from the Play Console; Linumic OS does not read the seller from Google Play")
        }
        return StoreSellerFact(store: store, sellers: names, listings: listings.count, withoutSeller: withoutSeller, source: source,
                               readAt: readAt, recordedOn: recorded.map { KeyDay($0, calendar: calendar) })
    }
}
