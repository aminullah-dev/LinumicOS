import Foundation

// MARK: - Money figures
//
// Money answers four questions (who paid, what is on the way, what we owe salons, what we pay) with ten figures, each
// read from one source. A figure is either known, with its source and the time it was read, or Unknown with the
// reason; never 0 for something that was not read.

/// The question a figure answers. Figures of different questions are never added to or subtracted from each other.
public enum MoneyQuestion: String, CaseIterable, Sendable, Identifiable {
    case received, onTheWay, owedToSalons, wePay, storeProceeds

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .received: L("Received")
        case .onTheWay: L("On the way")
        case .owedToSalons: L("Owed to salons")
        case .wePay: L("What we pay")
        case .storeProceeds: L("Store proceeds")
        }
    }
}

public enum MoneyFigureID: String, CaseIterable, Sendable, Identifiable {
    /// WorkTrack `GET /vendor/revenue` → `earned`: what HesabPay settled.
    case worktrackHesabPayReceived
    /// WorkTrack CRM invoices with status PAID: typed by hand, kept apart from HesabPay.
    case worktrackInvoicesPaid
    /// WorkTrack `GET /vendor/revenue` → `expected`: renewals falling due, a forecast.
    case worktrackRenewalsExpected
    /// WorkTrack CRM invoices with status SENT.
    case worktrackInvoicesOutstanding
    /// The SENT invoices whose due day is before today in Kabul (a part of the one above).
    case worktrackInvoicesOverdue
    /// SafeBeauty `provider_balances` above zero: the platform owes the salon.
    case safeBeautyOwedToSalons
    /// SafeBeauty `provider_balances` below zero: the salon owes the platform. Never netted with the one above.
    case safeBeautyOwedBySalons
    /// The obligations register's accounts with a cost recorded from a bill.
    case accountCosts
    case appStoreProceeds
    case googlePlayProceeds

    public var id: String { rawValue }

    public var question: MoneyQuestion {
        switch self {
        case .worktrackHesabPayReceived, .worktrackInvoicesPaid: .received
        case .worktrackRenewalsExpected, .worktrackInvoicesOutstanding, .worktrackInvoicesOverdue: .onTheWay
        case .safeBeautyOwedToSalons, .safeBeautyOwedBySalons: .owedToSalons
        case .accountCosts: .wePay
        case .appStoreProceeds, .googlePlayProceeds: .storeProceeds
        }
    }

    public var title: String {
        switch self {
        case .worktrackHesabPayReceived: L("HesabPay payments (WorkTrack)")
        case .worktrackInvoicesPaid: L("Invoices paid by hand (WorkTrack CRM)")
        case .worktrackRenewalsExpected: L("Expected renewals (WorkTrack forecast)")
        case .worktrackInvoicesOutstanding: L("Invoices sent, not paid")
        case .worktrackInvoicesOverdue: L("Invoices past due")
        case .safeBeautyOwedToSalons: L("Salons the platform owes")
        case .safeBeautyOwedBySalons: L("Salons that owe the platform")
        case .accountCosts: L("Account costs, as each bill says")
        case .appStoreProceeds: L("App Store")
        case .googlePlayProceeds: L("Google Play")
        }
    }

    /// The product the figure is read from, as the Desk names it.
    public var product: String? {
        switch self {
        case .worktrackHesabPayReceived, .worktrackInvoicesPaid, .worktrackRenewalsExpected, .worktrackInvoicesOutstanding,
             .worktrackInvoicesOverdue: "WorkTrack"
        case .safeBeautyOwedToSalons, .safeBeautyOwedBySalons: "SafeBeauty"
        case .accountCosts, .appStoreProceeds, .googlePlayProceeds: nil
        }
    }
}

/// Where a figure was read and when. Like `Source`, plus the environment, which decides the severity of its Desk lines
/// and the "not production" note.
public struct MoneySource: Hashable, Sendable {
    /// The system of record: "WorkTrack", "SafeBeauty", "obligations.json", "App Store Connect".
    public var system: String
    /// What exactly was read: "GET /v1/vendor/revenue (earned)", "Firestore provider_balances: sum(owedAmount) where …".
    public var reference: String
    /// The environment's raw value (production, demo, staging, localEmulator); nil for a file on this device.
    public var environment: String?
    /// When it was read; the server's own read time when it sends one. Nil only when it was never read.
    public var readAt: Date?

    public init(system: String, reference: String, environment: String? = nil, readAt: Date? = nil) {
        self.system = system
        self.reference = reference
        self.environment = environment
        self.readAt = readAt
    }

    public var isProduction: Bool { environment == nil || environment == "production" }
}

/// How much a known figure can be trusted to be the whole of it.
public enum MoneyCompleteness: Hashable, Sendable {
    case complete
    /// The source stopped at its own limit: the true figure is this or more.
    case atLeast(String)
    /// Part of it could not be counted, or the source's limit can move it either way: known for what was counted only.
    case partial(String)

    public var isComplete: Bool { self == .complete }

    public var caveat: String? {
        switch self {
        case .complete: nil
        case .atLeast(let why), .partial(let why): why
        }
    }

    /// Both caveats, the less certain kind winning: one that may be wrong either way is partial, not "at least".
    public func adding(_ other: MoneyCompleteness) -> MoneyCompleteness {
        switch (self, other) {
        case (.complete, _): return other
        case (_, .complete): return self
        case (.atLeast(let a), .atLeast(let b)): return .atLeast(a + " " + b)
        case (.partial(let a), .partial(let b)), (.partial(let a), .atLeast(let b)), (.atLeast(let a), .partial(let b)):
            return .partial(a + " " + b)
        }
    }
}

/// Why a figure is Unknown. Each is shown in place of the number and is one Desk item.
public enum MoneyUnknownReason: Hashable, Sendable {
    case notSignedIn(product: String)
    case notReadYet(product: String)
    /// The read failed; `part` names what was being read ("WorkTrack revenue").
    case readFailed(part: String, message: String)
    /// Read, but something it depends on was not, so it can't be counted honestly (the full sentence).
    case dependencyFailed(String)
    /// The server named a currency that is not a three-letter code.
    case unexpectedCurrency(String)
    case noFinanceKey(store: String)
    /// No account has a cost recorded from a bill.
    case noCostRecorded(accounts: Int)
    /// The obligations register was not available to Money.
    case registerNotBuilt
    /// obligations.json exists but could not be read: the owner's recorded costs are unknown, not absent.
    case obligationsUnreadable(String)

    public var text: String {
        switch self {
        case .notSignedIn(let product): LF("Not signed in to %@.", product)
        case .notReadYet(let product): LF("Signed in to %@, not read yet.", product)
        case .readFailed(let part, let message): LF("%1$@ could not be read: %2$@", part, message)
        case .dependencyFailed(let sentence): sentence
        case .unexpectedCurrency(let code): LF("WorkTrack named the currency %@, which is not a currency code.", code)
        case .noFinanceKey(let store): LF("No finance key for %@ on this device; new finance keys are out of scope (roadmap §5).", store)
        case .noCostRecorded: L("No account has a recorded cost.")
        case .registerNotBuilt: L("The obligations register is not available, so what we pay is unknown.")
        case .obligationsUnreadable(let message): LF("obligations.json could not be read (%@), so the costs you recorded are unknown.", message)
        }
    }
}

public struct MoneyFigure: Hashable, Sendable, Identifiable {
    public enum Value: Hashable, Sendable {
        case known(MoneyTotals)
        /// What we pay, per billing cycle and per currency, as the bills say. Never one total: monthly, yearly and
        /// one-off costs are not added together and never turned into a yearly figure.
        case knownByCycle([BillingCycle: MoneyTotals])
        case unknown(MoneyUnknownReason)
    }

    public var id: MoneyFigureID
    public var value: Value
    public var source: MoneySource
    public var completeness: MoneyCompleteness
    /// Expected renewals only: a forecast at today's prices, never money received.
    public var isForecast: Bool

    public init(id: MoneyFigureID, value: Value, source: MoneySource, completeness: MoneyCompleteness = .complete, isForecast: Bool = false) {
        self.id = id
        self.value = value
        self.source = source
        self.completeness = completeness
        self.isForecast = isForecast
    }

    /// The single per-currency total of a figure that has one (every figure but what we pay).
    public var totals: MoneyTotals? {
        if case .known(let t) = value { t } else { nil }
    }

    public var unknownReason: MoneyUnknownReason? {
        if case .unknown(let r) = value { r } else { nil }
    }

    public var isKnown: Bool { unknownReason == nil }
}
