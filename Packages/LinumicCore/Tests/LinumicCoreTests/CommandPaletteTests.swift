import Foundation
import Testing
@testable import LinumicCore

private func c(_ id: String, _ title: String, subtitle: String? = nil, keywords: [String] = [], group: PaletteCandidate.Group = .navigation) -> PaletteCandidate {
    PaletteCandidate(id: id, title: title, subtitle: subtitle, keywords: keywords, group: group, symbol: "circle")
}

@Suite("Command palette: normalisation")
struct PaletteTextTests {
    @Test func arabicAndPersianLetterFormsFoldTogether() {
        #expect(PaletteText.normalize("كتاب") == PaletteText.normalize("کتاب"))
        #expect(PaletteText.normalize("علي") == PaletteText.normalize("علی"))
        #expect(PaletteText.normalize("مصطفى") == PaletteText.normalize("مصطفی"))
        #expect(PaletteText.normalize("مدرسة") == PaletteText.normalize("مدرسه"))
        #expect(PaletteText.normalize("خانۀ") == PaletteText.normalize("خانه"))
        #expect(PaletteText.normalize("أحمد") == PaletteText.normalize("احمد"))
        #expect(PaletteText.normalize("آب") == PaletteText.normalize("اب"))
        #expect(PaletteText.normalize("مسؤول") == PaletteText.normalize("مسوول"))
    }

    @Test func marksJoinersAndTatweelAreIgnored() {
        #expect(PaletteText.normalize("گزارش\u{200C}روز") == PaletteText.normalize("گزارشروز"))
        #expect(PaletteText.normalize("مُحَمَّد") == PaletteText.normalize("محمد"))
        #expect(PaletteText.normalize("پایـــش") == "پایش")
        // Bidi isolates around an LTR id inside Dari text.
        #expect(PaletteText.normalize("لایسنس \u{2066}MF-2026-0003\u{2069}") == "لایسنس mf-2026-0003")
    }

    @Test func digitsCaseAccentsAndSpaces() {
        #expect(PaletteText.normalize("۲۰۲۶") == "2026")
        #expect(PaletteText.normalize("٢٠٢٦") == "2026")
        #expect(PaletteText.normalize("  Café   WorkTrack ") == "cafe worktrack")
        #expect(PaletteText.normalize("ＡＢＣ") == "abc")
    }
}

@Suite("Command palette: matching and ranking")
struct PaletteRankerTests {
    @Test func fuzzyTiers() {
        let exact = FuzzyMatch.score("monitor", in: "monitor")!
        let prefix = FuzzyMatch.score("mon", in: "monitor")!
        let word = FuzzyMatch.score("cust", in: "worktrack customers")!
        let sub = FuzzyMatch.score("nit", in: "monitor")!
        let subseq = FuzzyMatch.score("mntr", in: "monitor")!
        #expect(exact > prefix && prefix > word && word > sub && sub > subseq && subseq > 0)
        #expect(FuzzyMatch.score("xyz", in: "monitor") == nil)
        #expect(FuzzyMatch.score("rotinom", in: "monitor") == nil)   // order matters
        #expect(FuzzyMatch.score("", in: "monitor") == 0)
    }

    @Test func subsequenceRewardsWordStarts() {
        let starts = FuzzyMatch.score("wc", in: "worktrack customers")!
        let middle = FuzzyMatch.score("rc", in: "worktrack customers")!
        #expect(starts > middle)
    }

    @Test func dariQueriesMatchAcrossLetterForms() {
        let items = [c("nav.brief", "گزارش روز", keywords: ["Brief"]), c("nav.monitor", "پایش", keywords: ["Monitor"]),
                     c("nav.licences", "لایسنس‌ها", keywords: ["Licences"])]
        #expect(PaletteRanker.rank("گزارش", items).first?.id == "nav.brief")
        // Arabic kaf/yeh typed on an Arabic keyboard still finds the Persian title.
        #expect(PaletteRanker.rank("لايسنس", items).first?.id == "nav.licences")
        // The English keyword works in a Dari UI.
        #expect(PaletteRanker.rank("monitor", items).first?.id == "nav.monitor")
        #expect(PaletteRanker.rank("zzz", items).isEmpty)
    }

    @Test func titleBeatsKeywordAndEveryWordMustMatch() {
        let items = [c("a", "Releases", keywords: ["store"]), c("b", "App Store", group: .entity),
                     c("c", "Check now", subtitle: "Monitor", group: .action)]
        #expect(PaletteRanker.rank("store", items).map(\.id) == ["b", "a"])
        #expect(PaletteRanker.rank("check monitor", items).map(\.id) == ["c"])
        #expect(PaletteRanker.rank("check releases", items).isEmpty)
    }

    @Test func emptyQueryShowsRecentsFirstThenGroups() {
        let items = [c("e1", "Licence MF-1", group: .entity), c("n1", "Monitor"), c("a1", "Lock vault", group: .action), c("n2", "Brief")]
        let ranked = PaletteRanker.rank("", items, recents: ["e1", "gone", "a1"])
        #expect(ranked.map(\.id) == ["e1", "a1", "n1", "n2"])
        #expect(PaletteRanker.rank("  ", items, limit: 2).count == 2)
    }

    @Test func recentBonusBreaksCloseScores() {
        let items = [c("x", "WorkTrack customers"), c("y", "WorkTrack companies")]
        #expect(PaletteRanker.rank("worktrack", items).first?.id == "x")
        #expect(PaletteRanker.rank("worktrack", items, recents: ["y"]).first?.id == "y")
    }

    @Test func recentsList() {
        var r = PaletteRecents()
        for id in ["a", "b", "c", "a"] { r.record(id) }
        #expect(r.ids == ["a", "c", "b"])
        for i in 0..<20 { r.record("x\(i)") }
        #expect(r.ids.count == PaletteRecents.capacity)
        #expect(r.ids.first == "x19")
        r.keep(only: ["x19", "x18"])
        #expect(r.ids == ["x19", "x18"])
        let data = try! JSONEncoder().encode(r)
        #expect(try! JSONDecoder().decode(PaletteRecents.self, from: data) == r)
    }
}
