import Foundation

// MARK: - What Money is built from
//
// Plain values the App collects from the models that already read them (WorkTrack customers, SafeBeauty in Operations,
// the obligations register). Nothing here makes a request, and nothing of it is saved on this device.

/// A read that may have failed. A failure is never "no value": it keeps its message and its time.
public enum MoneyRead<T: Sendable>: Sendable {
    case read(T, at: Date)
    case failed(String, at: Date, needsSignIn: Bool)

    public var value: T? {
        if case .read(let v, _) = self { v } else { nil }
    }

    public var at: Date {
        switch self {
        case .read(_, let at), .failed(_, let at, _): at
        }
    }

    public var failure: String? {
        if case .failed(let message, _, _) = self { message } else { nil }
    }

    public var needsSignIn: Bool {
        if case .failed(_, _, let needsSignIn) = self { needsSignIn } else { false }
    }
}

extension MoneyRead: Equatable where T: Equatable {}

/// WorkTrack as `WorkTrackModel` holds it: the company list the `.worktrack` job read (for the TEST and DUPLICATE marks
/// and the licences) and the money reading of the same refresh.
public struct MoneyWorkTrackInput: Sendable {
    public var isSignedIn: Bool
    /// The environment's raw value (production, demo, localEmulator).
    public var environment: String?
    public var companies: [WTCompany]
    /// When the company list was read; nil when it has not been.
    public var companiesReadAt: Date?
    /// The company list's last read failed (the model then clears everything it read before).
    public var loadError: String?
    /// Nil until the money parts have been read.
    public var money: WorkTrackMoneyRead?

    public init(isSignedIn: Bool, environment: String?, companies: [WTCompany] = [], companiesReadAt: Date? = nil,
                loadError: String? = nil, money: WorkTrackMoneyRead? = nil) {
        self.isSignedIn = isSignedIn
        self.environment = environment
        self.companies = companies
        self.companiesReadAt = companiesReadAt
        self.loadError = loadError
        self.money = money
    }

    /// The company list was read and is current, so TEST and DUPLICATE marks can be applied.
    public var companiesKnown: Bool { isSignedIn && loadError == nil && companiesReadAt != nil }
}

public struct MoneySafeBeautyInput: Sendable {
    public var isSignedIn: Bool
    public var environment: String?
    /// Nil until the balances have been read; `.failed` when the last read failed (nothing older is kept).
    public var balances: MoneyRead<SafeBeautyBalanceTotals>?

    public init(isSignedIn: Bool, environment: String?, balances: MoneyRead<SafeBeautyBalanceTotals>? = nil) {
        self.isSignedIn = isSignedIn
        self.environment = environment
        self.balances = balances
    }
}

/// The obligations register's accounts, built on this device.
public struct MoneyCostsInput: Sendable {
    public var accounts: [VendorAccount]
    public var builtAt: Date
    /// obligations.json exists but could not be read: the register is then built from the seed alone, whose accounts
    /// carry no cost, so the owner's costs are unknown rather than absent. The store's reason only ("bad JSON"), not a
    /// sentence: `MoneyUnknownReason.obligationsUnreadable` puts it in one.
    public var loadError: String?

    public init(accounts: [VendorAccount], builtAt: Date, loadError: String? = nil) {
        self.accounts = accounts
        self.builtAt = builtAt
        self.loadError = loadError
    }
}

public struct MoneyInput: Sendable {
    public var worktrack: MoneyWorkTrackInput
    public var safeBeauty: MoneySafeBeautyInput
    /// Nil when the obligations register is not available.
    public var costs: MoneyCostsInput?

    public init(worktrack: MoneyWorkTrackInput, safeBeauty: MoneySafeBeautyInput, costs: MoneyCostsInput?) {
        self.worktrack = worktrack
        self.safeBeauty = safeBeauty
        self.costs = costs
    }
}
