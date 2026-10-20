import Foundation
import Testing
@testable import LinumicCore
#if canImport(CoreText)
import CoreText
#endif

// Reminder drafts: only facts that were read, Solar Hijri dates, and no dated draft a licence does not allow today.
// Names are made up (SAMPLE). The month names were checked with Foundation on macOS (Calendar(identifier: .persian),
// fa_AF and ps_AF); docs/sales.md notes that another ICU could name them differently.

private let today = "2026-10-20"

private func license(_ plan: WTPlan = .silver, _ status: WTLicenseStatus = .active, _ expiresAt: String?) -> WTLicense {
    WTLicense(plan: plan, deviceLimit: 20, status: status, expiresAt: expiresAt, enforceDevices: false, enforcePlan: false,
              employeeLimit: nil, extraFeatures: [], source: "VENDOR")
}

private func company(_ l: WTLicense, daysUntilExpiry: Int? = nil, flagged: Bool = false) -> WTCompany {
    WTCompany(companyId: "c_1", name: "Kabul Tailors (SAMPLE)", status: "ACTIVE", license: l, devicesInUse: 0, employeeCount: 0,
              employeesCounted: 0, employeeCap: 20, daysUntilExpiry: daysUntilExpiry, createdAt: nil, lastActivityAt: nil, deletion: nil,
              flags: flagged ? WTFlags(kind: "TEST", duplicateOf: nil, note: nil, at: nil, by: nil) : nil, duplicates: [], attention: [])
}

private func facts(_ l: WTLicense? = nil, contact: String? = nil, name: String = "Kabul Tailors (SAMPLE)") -> SalesDraftFacts {
    SalesDraftFacts(name: name, contact: contact, license: l, today: today)
}

@Suite("Sales: reminder drafts")
struct SalesDraftTests {
    @Test func solarHijriDays() {
        let dari = ["2026-10-19": "۲۷ میزان ۱۴۰۵", "2026-10-20": "۲۸ میزان ۱۴۰۵", "2026-11-04": "۱۳ عقرب ۱۴۰۵",
                    "2026-12-31": "۱۰ جدی ۱۴۰۵", "2027-03-20": "۲۹ حوت ۱۴۰۵", "2027-03-21": "۱ حمل ۱۴۰۶"]
        let pashto = ["2026-10-19": "۲۷ تله ۱۴۰۵", "2026-10-20": "۲۸ تله ۱۴۰۵", "2026-11-04": "۱۳ لړم ۱۴۰۵",
                      "2026-12-31": "۱۰ مرغومی ۱۴۰۵", "2027-03-20": "۲۹ کب ۱۴۰۵", "2027-03-21": "۱ وری ۱۴۰۶"]
        for (day, text) in dari { #expect(SalesDraft.day(day, language: .dari) == text, "\(day)") }
        for (day, text) in pashto { #expect(SalesDraft.day(day, language: .pashto) == text, "\(day)") }
        #expect(SalesDraft.day("2026-02-31", language: .dari) == nil)
    }

    @Test func goldenTexts() throws {
        let ending = license(.silver, .active, "2026-11-04")
        #expect(SalesDraft.text(.renewalEnding, language: .dari, facts: facts(ending)) == """
            سلام،
            لایسنس ورک‌ترک \u{2068}Kabul Tailors (SAMPLE)\u{2069} تا ۱۳ عقرب ۱۴۰۵ اعتبار دارد. برای تمدید لایسنس، لطفاً با ما تماس بگیرید یا به همین پیام جواب دهید.
            با احترام،
            لینومیک
            """)
        #expect(SalesDraft.text(.renewalEnding, language: .pashto, facts: facts(ending, contact: "Ahmad")) == """
            سلام \u{2068}Ahmad\u{2069}،
            د \u{2068}Kabul Tailors (SAMPLE)\u{2069} د ورک‌ټرک جواز تر ۱۳ لړم ۱۴۰۵ پورې اعتبار لري. د جواز د نوي کولو لپاره مهرباني وکړئ زموږ سره اړیکه ونیسئ یا همدې پیغام ته ځواب راکړئ.
            په درنښت،
            لینومیک
            """)
        let ended = license(.trial, .active, "2026-10-19")
        #expect(SalesDraft.text(.trialEnded, language: .dari, facts: facts(ended)) == """
            سلام،
            دورهٔ آزمایشی ورک‌ترک \u{2068}Kabul Tailors (SAMPLE)\u{2069} تا ۲۷ میزان ۱۴۰۵ ادامه داشت. اگر سؤالی دارید یا برای انتخاب پلان کمک می‌خواهید، به همین پیام جواب دهید.
            با احترام،
            لینومیک
            """)
        #expect(SalesDraft.text(.welcome, language: .pashto, facts: facts()) == """
            سلام،
            زه د لینومیک له خوا، چې ورک‌ټرک جوړوي، درته پیغام لیکم. که په \u{2068}Kabul Tailors (SAMPLE)\u{2069} کې د ورک‌ټرک د پیلولو لپاره مرسته غواړئ، همدې پیغام ته ځواب راکړئ.
            په درنښت،
            لینومیک
            """)
        #expect(SalesDraft.text(.followUp, language: .dari, facts: facts(contact: "  ")) == """
            سلام،
            از لینومیک، دربارهٔ ورک‌ترک به شما پیام می‌دهم. اگر وقت دارید، می‌خواهم امروز چند دقیقه با شما صحبت کنم. لطفاً بگویید چه وقتی برایتان مناسب است.
            با احترام،
            لینومیک
            """, "a blank contact is no contact; a company name is never a greeting")
        let licenceEnded = license(.gold, .expired, "2026-10-01")
        #expect(SalesDraft.text(.renewalEnded, language: .dari, facts: facts(licenceEnded))?.contains(
            "لایسنس ورک‌ترک \u{2068}Kabul Tailors (SAMPLE)\u{2069} تا ۹ میزان ۱۴۰۵ اعتبار داشت.") == true)
    }

    /// The bug this guards against: a Latin name right before a Persian day took the day's digits into its own
    /// left-to-right run («ورک‌ترک ۲۷ Kabul Tailors (SAMPLE) میزان ۱۴۰۵»). Every name is set apart, and every date is drawn
    /// in one piece and in reading order, whatever the name.
    @Test(arguments: ["Kabul Tailors (SAMPLE)", "خیاطی Kabul", "Tailors 2026", "خیاطی کابل (نمونه)"])
    func namesNeverSplitADate(name: String) throws {
        let licences: [SalesDraftKind: WTLicense] = [
            .renewalEnding: license(.gold, .active, "2026-11-19"), .renewalEnded: license(.gold, .expired, "2026-10-01"),
            .trialEnding: license(.trial, .active, "2026-10-20"), .trialEnded: license(.trial, .expired, "2026-10-10"),
        ]
        for kind in SalesDraftKind.allCases {
            for language in SalesDraftLanguage.allCases {
                let l = licences[kind]
                let text = try #require(SalesDraft.text(kind, language: language, facts: facts(l, contact: "Ahmad", name: name)), "\(kind) \(language)")
                #expect(text.hasPrefix("سلام \u{2068}Ahmad\u{2069}،"), "the contact is set apart")
                if kind.usesName { #expect(text.contains("\u{2068}\(name)\u{2069}"), "\(kind) \(language): the name is set apart") }
                #if canImport(CoreText)
                let body = text.components(separatedBy: "\n")[1]
                if kind.usesName { #expect(BidiCheck.isWhole(name, in: body), "\(kind) \(language): \(name)") }
                if let last = l?.expiresAt, let date = SalesDraft.day(last, language: language) {
                    #expect(BidiCheck.isWhole(date, in: body), "\(kind) \(language): the date is split by \(name)")
                    #expect(BidiCheck.readsRightToLeft(date, in: body), "\(kind) \(language): the day is right of its month")
                }
                #endif
            }
        }
    }

    #if canImport(CoreText)
    /// The check can fail: the text as it was before names were set apart.
    @Test func theBidiCheckSeesASplitDate() {
        let before = "آخرین روز دورهٔ آزمایشی ورک‌ترک Kabul Tailors (SAMPLE) ۲۷ میزان ۱۴۰۵ بود."
        #expect(!BidiCheck.isWhole("۲۷ میزان ۱۴۰۵", in: before))
        #expect(BidiCheck.isWhole("۲۷ میزان ۱۴۰۵", in: "آخرین روز دورهٔ آزمایشی ورک‌ترک \u{2068}Kabul Tailors (SAMPLE)\u{2069} ۲۷ میزان ۱۴۰۵ بود."))
    }
    #endif

    @Test func everyKindAndLanguageSaysOnlyWhatWasRead() throws {
        let cases: [(SalesDraftKind, WTLicense?)] = [
            (.followUp, nil), (.welcome, nil), (.renewalEnding, license(.gold, .active, "2026-11-19")),
            (.renewalEnded, license(.gold, .expired, "2026-10-01")), (.trialEnding, license(.trial, .active, "2026-10-20")),
            (.trialEnded, license(.trial, .expired, "2026-10-10")),
        ]
        for (kind, l) in cases {
            for language in SalesDraftLanguage.allCases {
                let text = try #require(SalesDraft.text(kind, language: language, facts: facts(l)), "\(kind) \(language)")
                #expect(!text.contains("{") && !text.contains("}") && !text.contains("\\("))
                for never in ["SENTINEL", "+93", "SILVER", "GOLD", "TRIAL", "AFN", "Lead", "LEAD", "تخفیف", "رایگان"] {
                    #expect(!text.contains(never), "\(kind) \(language): \(never)")
                }
                // The only digits are the date's.
                var rest = text
                if let last = l?.expiresAt, let day = SalesDraft.day(last, language: language) { rest = rest.replacingOccurrences(of: day, with: "") }
                #expect(!rest.contains { $0.isNumber }, "\(kind) \(language)")
                #expect(text.hasPrefix("سلام،") && text.hasSuffix("لینومیک"))
            }
        }
    }

    @Test func datedKindsFollowTheLicenceToday() {
        // Counted again from the last day and Kabul's today, never from the server's daysUntilExpiry.
        #expect(SalesDraft.datedKind(for: license(.silver, .active, "2026-11-19"), today: today) == .renewalEnding, "30 days")
        #expect(SalesDraft.datedKind(for: license(.silver, .active, "2026-11-20"), today: today) == nil, "31 days")
        #expect(SalesDraft.datedKind(for: license(.silver, .active, "2026-10-20"), today: today) == .renewalEnding, "the last day is today")
        #expect(SalesDraft.datedKind(for: license(.silver, .active, "2026-10-19"), today: today) == .renewalEnded)
        #expect(SalesDraft.datedKind(for: license(.trial, .active, "2026-10-25"), today: today) == .trialEnding)
        #expect(SalesDraft.datedKind(for: license(.trial, .active, "2026-10-01"), today: today) == .trialEnded)
        #expect(SalesDraft.datedKind(for: license(.silver, .active, nil), today: today) == nil, "perpetual")
        #expect(SalesDraft.datedKind(for: license(.silver, .active, "2026-02-31"), today: today) == nil, "not a day")
        // SUSPENDED: never "valid until".
        #expect(SalesDraft.datedKind(for: license(.silver, .suspended, "2026-10-25"), today: today) == nil)
        #expect(SalesDraft.text(.renewalEnding, language: .dari, facts: facts(license(.silver, .suspended, "2026-10-25"))) == nil)
        // EXPIRED with a last day still ahead: never "the last day was".
        #expect(SalesDraft.datedKind(for: license(.silver, .expired, "2026-11-15"), today: today) == nil)
        #expect(SalesDraft.text(.renewalEnded, language: .pashto, facts: facts(license(.silver, .expired, "2026-11-15"))) == nil)
        // SUSPENDED with its last day past: no "ended" either, only a call.
        #expect(SalesDraft.datedKind(for: license(.silver, .suspended, "2026-10-10"), today: today) == nil)
        #expect(SalesDraft.datedKind(for: license(.trial, .suspended, "2026-10-10"), today: today) == nil)
        #expect(SalesDraft.text(.renewalEnded, language: .dari, facts: facts(license(.silver, .suspended, "2026-10-10"))) == nil)
        #expect(SalesDraft.text(.trialEnded, language: .pashto, facts: facts(license(.trial, .suspended, "2026-10-10"))) == nil)
        #expect(SalesDraft.kinds(renewal: company(license(.trial, .suspended, "2026-10-10")), today: today) == [.followUp])
        // EXPIRED with its last day past did end.
        #expect(SalesDraft.datedKind(for: license(.silver, .expired, "2026-10-10"), today: today) == .renewalEnded)
    }

    @Test func kindsOffered() {
        let ending = license(.trial, .active, "2026-10-25")
        // The server said 6 hours ago it ends in 1 day; by Kabul's today it ended yesterday.
        let stale = company(license(.silver, .active, "2026-10-19"), daysUntilExpiry: 1)
        #expect(SalesDraft.kinds(followUp: company(ending), today: today) == [.followUp, .trialEnding])
        #expect(SalesDraft.kinds(followUp: nil, today: today) == [.followUp])
        #expect(SalesDraft.kinds(followUp: company(ending, flagged: true), today: today) == [.followUp])
        #expect(SalesDraft.kinds(renewal: stale, today: today) == [.renewalEnded, .followUp])
        #expect(SalesDraft.kinds(renewal: company(license(.silver, .expired, "2026-11-15")), today: today) == [.followUp])
        #expect(SalesDraft.text(.renewalEnding, language: .dari, facts: facts(stale.license)) == nil)
    }

    @Test func onlyTheCallNamesNoOne() {
        #expect(SalesDraftKind.allCases.filter { !$0.usesName } == [.followUp])
        let call = SalesDraft.text(.followUp, language: .dari, facts: facts()) ?? ""
        #expect(!call.contains("Kabul"), "Facts used lists the name only for the kinds that state it")
    }

    /// A name cannot close its isolate early or reverse the text after it: its bidi embeddings, overrides and isolates
    /// (U+202A … U+202E, U+2066 … U+2069) are taken out before it is set apart.
    @Test func bidiControlsInANameAreTakenOut() throws {
        let name = "Kabul\u{2069} Tailors\u{202E} (SAMPLE)"
        #expect(SalesDraft.isolated(name) == "\u{2068}Kabul Tailors (SAMPLE)\u{2069}")
        #expect(SalesDraft.isolated("\u{202E}\u{2069}") == "", "nothing left stays empty")
        let ending = license(.silver, .active, "2026-11-04")
        for language in SalesDraftLanguage.allCases {
            let text = try #require(SalesDraft.text(.renewalEnding, language: language,
                                                    facts: facts(ending, contact: "Ahmad\u{202E}\u{2069}", name: name)), "\(language)")
            let controls = text.unicodeScalars.filter { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
            #expect(controls.map(\.value) == [0x2068, 0x2069, 0x2068, 0x2069], "\(language): only the draft's own isolates")
            #expect(text.hasPrefix("سلام \u{2068}Ahmad\u{2069}،"))
            #expect(text.contains("\u{2068}Kabul Tailors (SAMPLE)\u{2069}"))
            #if canImport(CoreText)
            let body = text.components(separatedBy: "\n")[1]
            let date = try #require(SalesDraft.day("2026-11-04", language: language))
            #expect(BidiCheck.isWhole(date, in: body), "\(language)")
            #expect(BidiCheck.readsRightToLeft(date, in: body), "\(language)")
            #endif
        }
        // Only controls and spaces: no name, no contact.
        #expect(SalesDraft.text(.welcome, language: .dari, facts: facts(name: " \u{202E}\u{2069} ")) == nil)
        #expect(SalesDraft.text(.followUp, language: .dari, facts: facts(contact: "\u{2069}\u{202E}"))?.hasPrefix("سلام،\n") == true)
    }

    @Test func aMissingFactMeansNoDraft() {
        #expect(SalesDraft.text(.welcome, language: .dari, facts: facts(name: " ")) == nil)
        #expect(SalesDraft.text(.renewalEnding, language: .dari, facts: facts(nil)) == nil, "no licence read")
        #expect(SalesDraft.text(.followUp, language: .pashto, facts: facts(name: "")) != nil, "a call needs no name")
    }
}

#if canImport(CoreText)
/// How CoreText draws one line of a Dari or Pashto draft, right to left.
enum BidiCheck {
    /// The line's runs in visual order (left to right), each as its range in the text.
    static func visualRuns(_ line: String) -> [NSRange] {
        var direction = CTWritingDirection.rightToLeft
        let style = withUnsafeBytes(of: &direction) { raw in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        ]
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
        return (CTLineGetGlyphRuns(ct) as? [CTRun] ?? []).map {
            let r = CTRunGetStringRange($0)
            return NSRange(location: r.location, length: r.length)
        }
    }

    /// The runs that draw `part`, leftmost first, and whether nothing else is drawn between them.
    private static func span(_ part: String, in line: String) -> (runs: [NSRange], target: NSRange, whole: Bool)? {
        let target = (line as NSString).range(of: part)
        guard target.location != NSNotFound else { return nil }
        let runs = visualRuns(line)
        let touching = runs.indices.filter { NSIntersectionRange(runs[$0], target).length > 0 }
        guard let first = touching.first, let last = touching.last else { return nil }
        let inner = first + 1 < last ? Array(runs[(first + 1)..<last]) : []
        let whole = inner.allSatisfy { NSIntersectionRange($0, target).length == $0.length }
        return (Array(runs[first...last]), target, whole)
    }

    /// `part` is drawn in one piece: no run from outside it is drawn between its runs.
    static func isWhole(_ part: String, in line: String) -> Bool { span(part, in: line)?.whole ?? false }

    /// `part` (a date: day, month, year) reads right to left: its first character is drawn rightmost, its last leftmost.
    static func readsRightToLeft(_ part: String, in line: String) -> Bool {
        guard let s = span(part, in: line), let left = s.runs.first, let right = s.runs.last else { return false }
        return NSLocationInRange(s.target.location, right) && NSLocationInRange(NSMaxRange(s.target) - 1, left)
    }
}
#endif
