import LinumicCore
import SwiftUI

// MARK: - Text size on the Mac
//
// On the Mac, SwiftUI's text styles have fixed sizes and ignore Dynamic Type (body 13 points, caption 10), so the app
// sets its own (`TextSizeSetting`, LinumicCore: Standard, Large by default, Larger; Settings → Account, and ⌘+ ⌘− ⌘0).
// The styles below take the place of SwiftUI's own on the Mac: inside this app `.font(.caption)` is the app's caption at
// the chosen size, so every page grows in one step without each screen being changed. iPhone and iPad keep SwiftUI's
// styles, which follow Dynamic Type.

#if os(macOS)
/// The size the type scale is drawn at. Set by `TextSizeRoot` on the main thread before the window's views are drawn;
/// the root is rebuilt when it changes, so every font is read again.
enum AppTextSize {
    nonisolated(unsafe) static var current = TextSizeSetting(stored: UserDefaults.standard.string(forKey: TextSizeSetting.defaultsKey))

    static func points(_ style: TextStyleName) -> CGFloat { CGFloat(style.points(current)) }

    /// For spacing and the fixed sizes that go with text: grows less than the text.
    static var spacing: CGFloat { CGFloat(current.spacingScale) }
}

extension Font {
    static var largeTitle: Font { appStyle(.largeTitle) }
    static var title: Font { appStyle(.title) }
    static var title2: Font { appStyle(.title2) }
    static var title3: Font { appStyle(.title3) }
    static var headline: Font { appStyle(.headline) }
    static var body: Font { appStyle(.body) }
    static var callout: Font { appStyle(.callout) }
    static var subheadline: Font { appStyle(.subheadline) }
    static var footnote: Font { appStyle(.footnote) }
    static var caption: Font { appStyle(.caption) }
    static var caption2: Font { appStyle(.caption2) }

    private static func appStyle(_ style: TextStyleName) -> Font {
        .system(size: AppTextSize.points(style), weight: style.isBold ? .bold : .regular)
    }
}
#endif

/// The window's root: the chosen text size on the Mac (the default font of every control and label, and controls one
/// size up from Standard). On iPhone and iPad it changes nothing.
struct TextSizeRoot: ViewModifier {
    @AppStorage(TextSizeSetting.defaultsKey) private var stored = TextSizeSetting.default.rawValue

    func body(content: Content) -> some View {
        #if os(macOS)
        let size = TextSizeSetting(stored: stored)
        // Read by the type scale while the views below are drawn, so it is set first; `.id` redraws them all on a change.
        AppTextSize.current = size
        return content
            .font(.body)
            .controlSize(size == .standard ? .regular : .large)
            .id(size)
        #else
        return content
        #endif
    }
}

#if os(macOS)
/// ⌘+, ⌘− and ⌘0 in the View menu.
struct TextSizeCommands: Commands {
    @AppStorage(TextSizeSetting.defaultsKey) private var stored = TextSizeSetting.default.rawValue

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            let size = TextSizeSetting(stored: stored)
            Divider()
            Button("Larger Text") { if let next = size.larger { stored = next.rawValue } }
                .keyboardShortcut("+")
                .disabled(size.larger == nil)
            Button("Smaller Text") { if let next = size.smaller { stored = next.rawValue } }
                .keyboardShortcut("-")
                .disabled(size.smaller == nil)
            Button("Default Text Size") { stored = TextSizeSetting.default.rawValue }
                .keyboardShortcut("0")
                .disabled(size == .default)
        }
    }
}
#endif

/// The text-size control in Settings → Account (Mac only).
struct TextSizeSection: View {
    @AppStorage(TextSizeSetting.defaultsKey) private var stored = TextSizeSetting.default.rawValue

    var body: some View {
        Section {
            Picker("Text size", selection: $stored) {
                ForEach(TextSizeSetting.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Text size")
        } footer: {
            Text("For this Mac only. Large is one step above the Mac's own size. ⌘+ and ⌘− in the View menu change it too, and ⌘0 goes back to Large.")
        }
    }
}
