import Foundation

// MARK: - Text size on the Mac (اندازهٔ متن)
//
// The owner, 2026-11-13: "Make the app a bit bigger, because it can't be read with the eye." On the Mac, SwiftUI's text
// styles have fixed sizes (body 13 points, caption 10; checked on this Mac with ImageRenderer: `.dynamicTypeSize` changes
// nothing there), so the app could not be made larger from System Settings. This is the app's own setting, kept on this
// device: three sizes, Large by default, about one step above the system's. iPhone and iPad keep Dynamic Type.

/// The text size chosen on this Mac.
public enum TextSizeSetting: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// The Mac's own sizes (body 13 points), as before 2026-11-13.
    case standard
    /// One step up (body 15 points): the default.
    case large
    /// Two steps up (body 17 points).
    case larger

    public static let defaultsKey = "LCCTextSize"
    public static let `default`: TextSizeSetting = .large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: L("Standard")
        case .large: L("Large")
        case .larger: L("Larger")
        }
    }

    /// The stored value, or the default when none (or an unknown one) is stored.
    public init(stored: String?) {
        self = stored.flatMap(TextSizeSetting.init(rawValue:)) ?? .default
    }

    /// One step larger (⌘+), nil at the largest.
    public var larger: TextSizeSetting? {
        switch self {
        case .standard: .large
        case .large: .larger
        case .larger: nil
        }
    }

    /// One step smaller (⌘−), nil at the smallest.
    public var smaller: TextSizeSetting? {
        switch self {
        case .standard: nil
        case .large: .standard
        case .larger: .large
        }
    }

    /// How much the spacing and the fixed sizes that go with text (icon tiles, a pill's padding) grow: less than the
    /// text, so a larger size reads larger without spreading the page.
    public var spacingScale: Double {
        switch self {
        case .standard: 1
        case .large: 1.1
        case .larger: 1.2
        }
    }
}

/// The text styles the app uses, with the Mac's own sizes.
public enum TextStyleName: String, CaseIterable, Sendable, Hashable {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2

    /// The size macOS gives the style (`NSFont.preferredFont(forTextStyle:)` on macOS 27, read 2026-11-13).
    public var standardPoints: Double {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline: 13
        case .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote: 10
        case .caption: 10
        case .caption2: 10
        }
    }

    /// Whole points at each size, so text stays crisp. Large is one step up: body 13 → 15 (+15%), callout 12 → 14
    /// (+17%), caption 10 → 12 (+20%), the smallest growing most because they were the hardest to read. Larger is two.
    public func points(_ size: TextSizeSetting) -> Double {
        switch size {
        case .standard:
            return standardPoints
        case .large:
            switch self {
            case .largeTitle: return 30
            case .title: return 26
            case .title2: return 20
            case .title3: return 18
            case .headline, .body: return 15
            case .callout: return 14
            case .subheadline: return 13
            case .footnote, .caption: return 12
            case .caption2: return 11
            }
        case .larger:
            switch self {
            case .largeTitle: return 34
            case .title: return 29
            case .title2: return 23
            case .title3: return 20
            case .headline, .body: return 17
            case .callout: return 16
            case .subheadline: return 15
            case .footnote, .caption: return 14
            case .caption2: return 13
            }
        }
    }

    /// The weight macOS gives the style: only the headline is bold.
    public var isBold: Bool { self == .headline }
}
