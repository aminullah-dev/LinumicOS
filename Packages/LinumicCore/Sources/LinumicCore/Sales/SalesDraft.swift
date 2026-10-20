import Foundation

// MARK: - Reminder drafts (Dari and Pashto), copied only
//
// A draft states only facts the app read: the company's or account's name, a contact the owner fetched and picked, and
// the licence's last day from the company list. It never uses the owner's note, the stage, a price, a phone number, a
// claim about an earlier call, a promise or a discount. The words are the ones WorkTrack's own customers see
// («لایسنس», «آزمایشی», «ورک‌ترک», «لینومیک»; Pashto «جواز», «ازمایښتي», «ورک‌ټرک», «لینومیک»: WorkTrack
// `web/src/i18n/strings.ts:437, 439, 452, 639` and `:1533, 1535, 1548, 1735`). Dates are Solar Hijri. The texts are
// written here, not in the catalog: the app has no Pashto catalog, and the drafts are in both languages whatever the
// app's language. The App copies a draft to a concealed, local-only clipboard and never sends it.
//
// A name (the company's, the account's, the contact's) is set apart for the bidi algorithm (`isolated`): a Latin name
// right before a Persian day would otherwise take the day's digits into its own left-to-right run, and the reader would
// see the day on the far side of the name from its month. The name's own bidi controls are taken out first, so it can
// neither close its isolate early nor reverse the text after it. The Dari ended forms also keep a Persian word («تا»)
// between the name and the day, so the date stays whole even where the isolates are dropped.

public enum SalesDraftKind: String, CaseIterable, Sendable, Identifiable {
    case followUp, renewalEnding, renewalEnded, trialEnding, trialEnded, welcome

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followUp: L("Ask for a call")
        case .renewalEnding: L("Licence ending")
        case .renewalEnded: L("Licence ended")
        case .trialEnding: L("Trial ending")
        case .trialEnded: L("Trial ended")
        case .welcome: L("Welcome")
        }
    }

    /// Whether the text states the licence's last day.
    public var isDated: Bool { [.renewalEnding, .renewalEnded, .trialEnding, .trialEnded].contains(self) }

    /// Whether the text states the company's or account's name: every kind but the request for a call.
    public var usesName: Bool { self != .followUp }
}

public enum SalesDraftLanguage: String, CaseIterable, Sendable, Identifiable {
    case dari, pashto

    public var id: String { rawValue }
    /// The language's own name, as its speakers write it.
    public var title: String { self == .dari ? "دری" : "پښتو" }
    public var locale: Locale { Locale(identifier: self == .dari ? "fa_AF" : "ps_AF") }
}

/// What a draft may say, each read from a source.
public struct SalesDraftFacts: Equatable, Sendable {
    /// The WorkTrack company's or the CRM account's name.
    public var name: String
    /// A contact the owner read (`GET /v1/vendor/crm/contacts`) and picked; nil for none.
    public var contact: String?
    /// The company's licence as the company list read it, for the dated kinds.
    public var license: WTLicense?
    /// Kabul's date when the draft is built, `YYYY-MM-DD`.
    public var today: String

    public init(name: String, contact: String? = nil, license: WTLicense? = nil, today: String) {
        self.name = name
        self.contact = contact
        self.license = license
        self.today = today
    }
}

public enum SalesDraft {
    /// The dated kind a licence allows on `today`, its days counted again from `expiresAt` and Kabul's today (not the
    /// server's count, which can be hours old): ending only while ACTIVE and 0 to 30 days away; ended only once the last
    /// day is past and the licence is not SUSPENDED. A suspended licence (whatever its last day), one ending later, a
    /// perpetual one or a day that is not real: none.
    public static func datedKind(for license: WTLicense, today: String) -> SalesDraftKind? {
        guard let last = license.expiresAt, let days = WorkTrackDates.daysBetween(today, last) else { return nil }
        let trial = license.plan == .trial
        if days < 0 { return license.status == .suspended ? nil : trial ? .trialEnded : .renewalEnded }
        if license.status == .active, days <= SalesBuilder.renewalWindow { return trial ? .trialEnding : .renewalEnding }
        return nil
    }

    /// The kinds a follow-up offers: a request for a call, and the dated kind when its company is listed, not marked
    /// TEST or DUPLICATE, and its licence allows one today.
    public static func kinds(followUp company: WTCompany?, today: String) -> [SalesDraftKind] {
        guard let company, !company.isFlagged, let dated = datedKind(for: company.license, today: today) else { return [.followUp] }
        return [.followUp, dated]
    }

    /// The kinds a renewal or trial row offers: its dated kind (when the licence allows one today) and a call.
    public static func kinds(renewal company: WTCompany, today: String) -> [SalesDraftKind] {
        (datedKind(for: company.license, today: today).map { [$0] } ?? []) + [.followUp]
    }

    /// A day, Solar Hijri, in the language's own month names and digits ("۲۸ میزان ۱۴۰۵", "۲۸ تله ۱۴۰۵"). Nil for a
    /// day that is not real.
    public static func day(_ text: String, language: SalesDraftLanguage) -> String? {
        guard let date = WorkTrackDates.displayDate(text) else { return nil }
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .persian)
        calendar.timeZone = utc
        calendar.locale = language.locale
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = language.locale
        f.timeZone = utc
        f.dateFormat = "d MMMM y"
        return f.string(from: date)
    }

    /// A name set apart for the bidi algorithm (FIRST STRONG ISOLATE … POP DIRECTIONAL ISOLATE, U+2068 … U+2069): it keeps
    /// its own direction and takes nothing around it into its run. Its own bidi controls are taken out first
    /// (`withoutBidiControls`). Empty, or nothing left, stays empty.
    public static func isolated(_ text: String) -> String {
        let name = withoutBidiControls(text)
        return name.isEmpty ? name : "\u{2068}\(name)\u{2069}"
    }

    /// The text without bidi embeddings, overrides and isolates (U+202A … U+202E, U+2066 … U+2069). In a name, a POP
    /// DIRECTIONAL ISOLATE would close the isolate around it early and an override would reverse what follows it.
    static func withoutBidiControls(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) })
        return String(scalars)
    }

    /// The draft, or nil when a fact it needs is missing or no longer holds (no name, no last day, a licence that does
    /// not allow that kind today).
    public static func text(_ kind: SalesDraftKind, language: SalesDraftLanguage, facts: SalesDraftFacts) -> String? {
        // A name or contact that is only bidi controls and spaces is none.
        let trimmed = withoutBidiControls(facts.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = isolated(trimmed)
        let contact = facts.contact.map(withoutBidiControls)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map(isolated)
        var date = ""
        if kind.isDated {
            guard let license = facts.license, datedKind(for: license, today: facts.today) == kind,
                  let last = license.expiresAt, let d = day(last, language: language) else { return nil }
            date = d
        }
        if kind.usesName, trimmed.isEmpty { return nil }
        let dari = language == .dari
        // «سلام» is the same word in both languages. A company's name is never a greeting.
        let greeting = "سلام" + (contact.map { " " + $0 } ?? "") + "،"
        let closing = dari ? "با احترام،\nلینومیک" : "په درنښت،\nلینومیک"
        let body: String = switch (kind, dari) {
        case (.followUp, true):
            "از لینومیک، دربارهٔ ورک‌ترک به شما پیام می‌دهم. اگر وقت دارید، می‌خواهم امروز چند دقیقه با شما صحبت کنم. لطفاً بگویید چه وقتی برایتان مناسب است."
        case (.followUp, false):
            "زه د لینومیک له خوا د ورک‌ټرک په اړه درته پیغام لیکم. که وخت لرئ، غواړم نن له تاسو سره څو دقیقې خبرې وکړم. مهرباني وکړئ راته ووایئ چې کوم وخت درته مناسب دی."
        case (.renewalEnding, true):
            "لایسنس ورک‌ترک \(name) تا \(date) اعتبار دارد. برای تمدید لایسنس، لطفاً با ما تماس بگیرید یا به همین پیام جواب دهید."
        case (.renewalEnding, false):
            "د \(name) د ورک‌ټرک جواز تر \(date) پورې اعتبار لري. د جواز د نوي کولو لپاره مهرباني وکړئ زموږ سره اړیکه ونیسئ یا همدې پیغام ته ځواب راکړئ."
        case (.renewalEnded, true):
            "لایسنس ورک‌ترک \(name) تا \(date) اعتبار داشت. برای تمدید لایسنس، لطفاً با ما تماس بگیرید یا به همین پیام جواب دهید."
        case (.renewalEnded, false):
            "د \(name) د ورک‌ټرک د جواز وروستۍ ورځ \(date) وه. د جواز د نوي کولو لپاره مهرباني وکړئ زموږ سره اړیکه ونیسئ یا همدې پیغام ته ځواب راکړئ."
        case (.trialEnding, true):
            "دورهٔ آزمایشی ورک‌ترک \(name) تا \(date) ادامه دارد. اگر سؤالی دارید یا برای انتخاب پلان کمک می‌خواهید، به همین پیام جواب دهید."
        case (.trialEnding, false):
            "د \(name) د ورک‌ټرک ازمایښتي موده تر \(date) پورې ده. که پوښتنه لرئ یا د پلان په ټاکلو کې مرسته غواړئ، همدې پیغام ته ځواب راکړئ."
        case (.trialEnded, true):
            "دورهٔ آزمایشی ورک‌ترک \(name) تا \(date) ادامه داشت. اگر سؤالی دارید یا برای انتخاب پلان کمک می‌خواهید، به همین پیام جواب دهید."
        case (.trialEnded, false):
            "د \(name) د ورک‌ټرک د ازمایښتي مودې وروستۍ ورځ \(date) وه. که پوښتنه لرئ یا د پلان په ټاکلو کې مرسته غواړئ، همدې پیغام ته ځواب راکړئ."
        case (.welcome, true):
            "از لینومیک، سازندهٔ ورک‌ترک، به شما پیام می‌دهم. اگر برای راه‌اندازی ورک‌ترک در \(name) کمک می‌خواهید، به همین پیام جواب دهید."
        case (.welcome, false):
            "زه د لینومیک له خوا، چې ورک‌ټرک جوړوي، درته پیغام لیکم. که په \(name) کې د ورک‌ټرک د پیلولو لپاره مرسته غواړئ، همدې پیغام ته ځواب راکړئ."
        }
        return [greeting, body, closing].joined(separator: "\n")
    }
}
