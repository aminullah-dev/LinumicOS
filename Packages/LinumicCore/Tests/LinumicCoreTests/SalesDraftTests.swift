import Foundation
import Testing
@testable import LinumicCore

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
            لایسنس ورک‌ترک Kabul Tailors (SAMPLE) تا ۱۳ عقرب ۱۴۰۵ اعتبار دارد. برای تمدید لایسنس، لطفاً با ما تماس بگیرید یا به همین پیام جواب دهید.
            با احترام،
            لینومیک
            """)
        #expect(SalesDraft.text(.renewalEnding, language: .pashto, facts: facts(ending, contact: "Ahmad")) == """
            سلام Ahmad،
            د Kabul Tailors (SAMPLE) د ورک‌ټرک جواز تر ۱۳ لړم ۱۴۰۵ پورې اعتبار لري. د جواز د نوي کولو لپاره مهرباني وکړئ زموږ سره اړیکه ونیسئ یا همدې پیغام ته ځواب راکړئ.
            په درنښت،
            لینومیک
            """)
        let ended = license(.trial, .active, "2026-10-19")
        #expect(SalesDraft.text(.trialEnded, language: .dari, facts: facts(ended)) == """
            سلام،
            آخرین روز دورهٔ آزمایشی ورک‌ترک Kabul Tailors (SAMPLE) ۲۷ میزان ۱۴۰۵ بود. اگر سؤالی دارید یا برای انتخاب پلان کمک می‌خواهید، به همین پیام جواب دهید.
            با احترام،
            لینومیک
            """)
        #expect(SalesDraft.text(.welcome, language: .pashto, facts: facts()) == """
            سلام،
            زه د لینومیک له خوا، چې ورک‌ټرک جوړوي، درته پیغام لیکم. که په Kabul Tailors (SAMPLE) کې د ورک‌ټرک د پیلولو لپاره مرسته غواړئ، همدې پیغام ته ځواب راکړئ.
            په درنښت،
            لینومیک
            """)
        #expect(SalesDraft.text(.followUp, language: .dari, facts: facts(contact: "  ")) == """
            سلام،
            از لینومیک، دربارهٔ ورک‌ترک به شما پیام می‌دهم. اگر وقت دارید، می‌خواهم امروز چند دقیقه با شما صحبت کنم. لطفاً بگویید چه وقتی برایتان مناسب است.
            با احترام،
            لینومیک
            """, "a blank contact is no contact; a company name is never a greeting")
    }

    @Test func everyKindAndLanguageSaysOnlyWhatWasRead() throws {
        let cases: [(SalesDraftKind, WTLicense?)] = [
            (.followUp, nil), (.welcome, nil), (.renewalEnding, license(.gold, .active, "2026-11-19")),
            (.renewalEnded, license(.gold, .expired, "2026-10-01")), (.trialEnding, license(.trial, .active, "2026-10-20")),
            (.trialEnded, license(.trial, .suspended, "2026-10-10")),
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
        // A suspended licence whose last day is past did end: that is true.
        #expect(SalesDraft.datedKind(for: license(.silver, .suspended, "2026-10-10"), today: today) == .renewalEnded)
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

    @Test func aMissingFactMeansNoDraft() {
        #expect(SalesDraft.text(.welcome, language: .dari, facts: facts(name: " ")) == nil)
        #expect(SalesDraft.text(.renewalEnding, language: .dari, facts: facts(nil)) == nil, "no licence read")
        #expect(SalesDraft.text(.followUp, language: .pashto, facts: facts(name: "")) != nil, "a call needs no name")
    }
}
