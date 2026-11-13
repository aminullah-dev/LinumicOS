#if DEBUG && os(macOS)
import AppKit

/// Debug-only screenshot aid for the Mac, without Screen Recording: the app draws its own main window into a PNG and
/// quits. `tools/design/mac-preview.sh` runs it in a preview build under its own bundle identifier, so it has its own
/// container and Keychain items and never sees the owner's data.
///
/// `-LCCSnapshot <file.png>` turns it on; `-LCCWindowSize 1280x860` sets the window's size first; `-LCCSnapshotDelay 6`
/// waits that many seconds for the page to settle; `-LCCAppearance dark` or `light` sets the appearance. Never in a
/// release build.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfAsked() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "LCCAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let path = defaults.string(forKey: "LCCSnapshot") else { return }
        let delay = defaults.object(forKey: "LCCSnapshotDelay") == nil ? 6 : defaults.double(forKey: "LCCSnapshotDelay")
        let size = defaults.string(forKey: "LCCWindowSize").flatMap(parse)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if let size, let window = mainWindow() {
                window.setFrame(NSRect(x: 40, y: 40, width: size.width, height: size.height), display: true)
            }
            try? await Task.sleep(for: .seconds(delay))
            // Again: a restored window frame can arrive after the first.
            if let size, let window = mainWindow() {
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                window.setFrame(NSRect(x: 40, y: 40, width: size.width, height: size.height), display: true)
            }
            // The sidebar's translucent material samples what is behind the window, which a view's own drawing can't
            // capture (it comes out empty): drawn solid for the picture.
            if let root = mainWindow()?.contentView?.superview { solidify(root) }
            try? await Task.sleep(for: .seconds(1))
            if let window = mainWindow(), let view = window.contentView?.superview ?? window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                if defaults.bool(forKey: "LCCSnapshotTree") { dump(view, depth: 0) }
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try compose(rep, root: view, appearance: window.effectiveAppearance)
                        .representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                } catch {
                    print("LCCSnapshot: not written: \(error.localizedDescription)")
                }
            } else {
                print("LCCSnapshot: no window among \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })")
            }
            NSApp.terminate(nil)
        }
    }

    /// The window's picture over a solid window background, with each table (the sidebar's list) drawn on its own on
    /// top: inside the sidebar's glass the window-wide drawing leaves the list out.
    @MainActor
    private static func compose(_ window: NSBitmapImageRep, root: NSView, appearance: NSAppearance) -> NSBitmapImageRep {
        guard let out = root.bitmapImageRepForCachingDisplay(in: root.bounds), let context = NSGraphicsContext(bitmapImageRep: out) else { return window }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            root.bounds.fill()
            window.draw(in: root.bounds)
            // The sidebar's glass comes out blank: a solid sidebar colour under its list instead.
            for glass in glassViews(in: root) {
                NSColor.underPageBackgroundColor.setFill()
                glass.convert(glass.bounds, to: root).fill()
            }
            for table in tables(in: root) {
                let rect = table.visibleRect
                guard rect.width > 0, rect.height > 0, let rep = table.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                table.cacheDisplay(in: rect, to: rep)
                rep.draw(in: table.convert(rect, to: root), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    @MainActor
    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    @MainActor
    private static func glassViews(in view: NSView) -> [NSView] {
        String(describing: type(of: view)) == "NSGlassEffectView" ? [view] : view.subviews.flatMap(glassViews)
    }

    @MainActor
    private static func dump(_ view: NSView, depth: Int) {
        FileHandle.standardError.write(Data((String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)\n").utf8))
        view.subviews.forEach { dump($0, depth: depth + 1) }
    }

    @MainActor
    private static func solidify(_ view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.blendingMode = .withinWindow
            effect.state = .inactive
        }
        // The selected row's emphasis is drawn by the glass too, and its label would come out white on white.
        (view as? NSTableView)?.selectionHighlightStyle = .none
        view.subviews.forEach(solidify)
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    private static func parse(_ text: String) -> NSSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }
}
#endif
