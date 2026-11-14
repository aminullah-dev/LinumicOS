import Testing
@testable import LinumicCore

@Suite("Text size on the Mac")
struct TextSizeTests {
    @Test func storedValueFallsBackToLarge() {
        #expect(TextSizeSetting(stored: nil) == .large)
        #expect(TextSizeSetting(stored: "") == .large)
        #expect(TextSizeSetting(stored: "huge") == .large)
        #expect(TextSizeSetting(stored: "standard") == .standard)
        #expect(TextSizeSetting(stored: "larger") == .larger)
        #expect(TextSizeSetting.default == .large)
    }

    @Test func rawValuesRoundTrip() {
        for size in TextSizeSetting.allCases {
            #expect(TextSizeSetting(stored: size.rawValue) == size)
        }
    }

    @Test func stepsMoveOneAtATimeAndStopAtTheEnds() {
        #expect(TextSizeSetting.standard.smaller == nil)
        #expect(TextSizeSetting.standard.larger == .large)
        #expect(TextSizeSetting.large.smaller == .standard)
        #expect(TextSizeSetting.large.larger == .larger)
        #expect(TextSizeSetting.larger.larger == nil)
        #expect(TextSizeSetting.larger.smaller == .large)
    }

    @Test func spacingGrowsLessThanText() {
        #expect(TextSizeSetting.standard.spacingScale == 1)
        #expect(TextSizeSetting.large.spacingScale > 1)
        #expect(TextSizeSetting.larger.spacingScale > TextSizeSetting.large.spacingScale)
        for style in TextStyleName.allCases {
            let text = style.points(.larger) / style.points(.standard)
            #expect(TextSizeSetting.larger.spacingScale < text)
        }
    }

    @Test func everyStyleGrowsWithTheSizeInWholePoints() {
        for style in TextStyleName.allCases {
            let a = style.points(.standard), b = style.points(.large), c = style.points(.larger)
            #expect(a == style.standardPoints)
            #expect(a < b && b < c)
            #expect([a, b, c].allSatisfy { $0 == $0.rounded() })
        }
    }

    @Test func styleOrderIsKeptAtEverySize() {
        let order: [TextStyleName] = [.largeTitle, .title, .title2, .title3, .body, .callout, .subheadline, .caption]
        for size in TextSizeSetting.allCases {
            let pts = order.map { $0.points(size) }
            #expect(pts == pts.sorted(by: >))
        }
    }

    @Test func onlyTheHeadlineIsBold() {
        #expect(TextStyleName.allCases.filter(\.isBold) == [.headline])
    }
}
