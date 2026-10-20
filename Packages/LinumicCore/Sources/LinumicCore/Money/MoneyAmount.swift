import Foundation

// MARK: - Money (پول): amounts in their own currency
//
// Every amount carries its currency, and totals are kept per currency. Nothing here converts one currency into another
// or returns one number across currencies: a list of amounts is shown one per currency, side by side.

/// An ISO 4217 code: exactly three ASCII letters, upper-cased ("afn" is AFN; "US$" and "AF" are not codes). The same
/// rule as `AccountCost.checked`.
public struct CurrencyCode: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let code = rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        self.rawValue = code
    }

    public static let afn = CurrencyCode(rawValue: "AFN")!

    public var description: String { rawValue }

    /// AFN first, then alphabetical: the order every list of amounts uses.
    public static func < (a: Self, b: Self) -> Bool {
        if a == b { return false }
        if a == .afn { return true }
        if b == .afn { return false }
        return a.rawValue < b.rawValue
    }
}

/// One amount in one currency. `Decimal`, so nothing is rounded on the way.
public struct MoneyAmount: Hashable, Sendable {
    public var value: Decimal
    public var currency: CurrencyCode

    public init(_ value: Decimal, _ currency: CurrencyCode) {
        self.value = value
        self.currency = currency
    }

    /// A JSON number WorkTrack sends (decoded as `Double` in `WTRevenue`) as an exact decimal: a whole number converts
    /// exactly, anything else through its shortest decimal text ("1500.5", not 1500.49999…).
    public static func decimal(_ d: Double) -> Decimal {
        if d.isFinite, d.rounded() == d, abs(d) < 1e15 { return Decimal(Int64(d)) }
        return Decimal(string: "\(d)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(d)
    }
}

/// Sums kept per currency. There is deliberately no API that returns one number across currencies.
public struct MoneyTotals: Hashable, Sendable {
    public private(set) var byCurrency: [CurrencyCode: Decimal] = [:]
    /// How many items were added (orders, invoices, salons, accounts).
    public private(set) var count = 0

    public init() {}

    /// Nothing yet, in a currency that is known to be the only one (WorkTrack's CRM is in AFN): reads as "0 AFN", a
    /// known zero, never as an empty unknown.
    public init(zeroIn currency: CurrencyCode) {
        byCurrency[currency] = 0
    }

    /// A figure the server already summed, with its own count.
    public init(_ amount: MoneyAmount, count: Int) {
        byCurrency[amount.currency] = amount.value
        self.count = count
    }

    public mutating func add(_ amount: MoneyAmount) {
        byCurrency[amount.currency, default: 0] += amount.value
        count += 1
    }

    /// One amount per currency, AFN first.
    public var amounts: [MoneyAmount] { byCurrency.keys.sorted().map { MoneyAmount(byCurrency[$0]!, $0) } }

    public var currencies: [CurrencyCode] { byCurrency.keys.sorted() }
}

/// "8,500 AFN" in the given locale (the app passes `.current`, so Dari digits on the owner's Mac). Several currencies
/// are joined with " · ", never added.
public enum MoneyFormat {
    public static func text(_ a: MoneyAmount, locale: Locale = .current) -> String {
        "\(a.value.formatted(.number.locale(locale))) \(a.currency.rawValue)"
    }

    public static func text(_ t: MoneyTotals, locale: Locale = .current) -> String {
        t.amounts.map { text($0, locale: locale) }.joined(separator: " · ")
    }

    /// The amounts with what the source's limits allow to be said about them: "At least …" when the source stopped
    /// at its own limit, "… (incomplete)" when part of it could not be counted.
    public static func text(_ t: MoneyTotals, _ completeness: MoneyCompleteness, locale: Locale = .current) -> String {
        let plain = text(t, locale: locale)
        switch completeness {
        case .complete: return plain
        case .atLeast: return LF("At least %@", plain)
        case .partial: return LF("%@ (incomplete)", plain)
        }
    }

    /// What we pay, one line per currency, its billing cycles side by side: "99 USD per year · 25 USD once". An amount
    /// of one cycle is never added to another's, and nothing is turned into a yearly figure.
    public static func byCycle(_ cycles: [BillingCycle: MoneyTotals], locale: Locale = .current) -> [String] {
        let currencies = Set(cycles.values.flatMap(\.currencies)).sorted()
        return currencies.map { code in
            BillingCycle.allCases.compactMap { cycle in
                cycles[cycle]?.byCurrency[code].map { "\(text(MoneyAmount($0, code), locale: locale)) \(cycle.title)" }
            }.joined(separator: " · ")
        }
    }
}
