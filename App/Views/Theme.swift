import LinumicCore
import SwiftUI

// MARK: - Colour tokens

/// The app's colours, in one place. The values live in the asset catalogue (`AccentColor` and the `Theme` folder), each
/// with light, dark and Increase Contrast variants, written and contrast-checked by `tools/design/make_colors.py`.
/// Screens use these, not raw system colours, so a status reads the same everywhere and its text stays legible.
extension Color {
    /// The Linumic slate blue (the hue of the Linumic ink). The app's root sets it as the tint, so buttons, toggles and
    /// highlights use it whatever accent the system is set to; it is also the asset catalogue's accent colour.
    static let brandAccent = Color(.accent)
    /// Up, passing, verified, done.
    static let statusGood = Color(.statusGood)
    /// Soon, slow, partial, needs a look.
    static let statusWarn = Color(.statusWarn)
    /// Down, failing, overdue, expired.
    static let statusBad = Color(.statusBad)
    /// Running, in review, a demo or test environment, for information.
    static let statusInfo = Color(.statusInfo)
    /// Unknown, not read, not checked: a neutral grey, never green. An unread source is never shown as fine.
    static let statusUnknown = Color(.statusUnknown)
}

extension ShapeStyle where Self == Color {
    static var brandAccent: Color { Color(.accent) }
    static var statusGood: Color { Color(.statusGood) }
    static var statusWarn: Color { Color(.statusWarn) }
    static var statusBad: Color { Color(.statusBad) }
    static var statusInfo: Color { Color(.statusInfo) }
    static var statusUnknown: Color { Color(.statusUnknown) }
}

/// The tint of an area: its sidebar tile, its page header and its number cards. Tile colours carry a white symbol at
/// 3:1 or more (4.5:1 with Increase Contrast).
enum AreaTint {
    case ink, blue, indigo, purple, pink, red, orange, amber, green, teal, brown, graphite

    var color: Color {
        switch self {
        case .ink: Color(.areaInk)
        case .blue: Color(.areaBlue)
        case .indigo: Color(.areaIndigo)
        case .purple: Color(.areaPurple)
        case .pink: Color(.areaPink)
        case .red: Color(.areaRed)
        case .orange: Color(.areaOrange)
        case .amber: Color(.areaAmber)
        case .green: Color(.areaGreen)
        case .teal: Color(.areaTeal)
        case .brown: Color(.areaBrown)
        case .graphite: Color(.areaGraphite)
        }
    }

    /// The colour of a page header's band: the area's tint, and for the brand's ink (the Desk) the Linumic slate blue,
    /// since ink at a header's strength is only grey.
    var bandColor: Color { self == .ink ? .brandAccent : color }
}

extension SidebarItem {
    /// Each page's tint, like the tiles of System Settings: neighbours differ, settings-like pages are graphite, and the
    /// main pages avoid the pure status red so a header never reads as an alarm.
    var tint: AreaTint {
        switch self {
        case .desk: .ink
        case .obligations: .orange
        case .money: .green
        case .sales: .teal
        case .legal: .brown
        case .dashboard: .blue
        case .brief: .amber
        case .monitor: .pink
        case .automation: .graphite
        case .releaseCenter: .blue
        case .platforms: .indigo
        case .productBoard: .purple
        case .agents: .teal
        case .oversight: .blue
        case .licences: .amber
        case .worktrackCustomers: .teal
        case .operations: .orange
        case .siteMessages: .blue
        case .vault: .graphite
        case .keys: .green
        case .continuity: .indigo
        case .allProducts: .purple
        case .verification: .green
        case .releases: .indigo
        case .roadmap: .teal
        case .issues: .orange
        case .repositories: .graphite
        case .builds: .brown
        case .deployments: .indigo
        case .appStore: .blue
        case .googlePlay: .green
        case .marketingQueue: .pink
        case .socialMedia: .purple
        case .contentCalendar: .red
        case .marketIntelligence: .indigo
        case .aiAssistant: .purple
        case .integrations: .graphite
        case .security: .blue
        case .account: .graphite
        }
    }
}

// MARK: - Shape and spacing tokens

enum Theme {
    /// Corner radii: rows and inner boxes, cards, and the large summary cards and page headers.
    enum Radius {
        static let small: CGFloat = 8
        static let card: CGFloat = 12
        static let large: CGFloat = 16
    }

    /// The spacing scale (a 4-point rhythm).
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// The pill's tint behind its text: the contrast of the status colours is checked against it.
    static let pillTint = 0.14
}

// MARK: - Icon tile

/// A rounded square in an area's tint with a white SF Symbol, as in System Settings. Decorative: the title beside it
/// carries the meaning.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
                    .imageScale(.medium)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A sidebar row's tile, sized to the sidebar (System Settings → Appearance → Sidebar icon size on the Mac). The
/// Archive's pages are muted to graphite.
struct SidebarTile: View {
    let item: SidebarItem
    var muted = false
    #if os(macOS)
    @Environment(\.sidebarRowSize) private var rowSize
    #endif

    var body: some View {
        IconTile(symbol: item.symbol, tint: (muted ? AreaTint.graphite : item.tint).color, size: size)
            .opacity(muted ? 0.8 : 1)
    }

    private var size: CGFloat {
        #if os(macOS)
        switch rowSize {
        case .small: 16
        case .large: 24
        default: 20
        }
        #else
        28
        #endif
    }
}

// MARK: - Page header

/// The top of a main page: a soft band in the area's tint, the page's tile and title, and the page's own summary below.
/// Solid with Reduce Transparency, outlined with Increase Contrast.
struct PageHeader<Content: View>: View {
    let item: SidebarItem
    var subtitle: Text?
    @ViewBuilder let content: Content

    init(_ item: SidebarItem, subtitle: Text? = nil, @ViewBuilder content: () -> Content) {
        self.item = item
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: item.symbol, tint: item.tint.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        subtitle.font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { HeaderBand(tint: item.tint.bandColor) }
        #if os(iOS)
        // The header carries the title, so the bar shows it small.
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

extension PageHeader where Content == EmptyView {
    init(_ item: SidebarItem, subtitle: Text? = nil) {
        self.init(item, subtitle: subtitle) { EmptyView() }
    }
}

/// The header's background: the tint fading down over the page.
private struct HeaderBand: View {
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(.background.secondary)
            } else {
                shape.fill(.background)
                shape.fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.20 : 0.13), tint.opacity(scheme == .dark ? 0.05 : 0.03)],
                                          startPoint: .top, endPoint: .bottom))
            }
            shape.strokeBorder(contrast == .increased ? tint.opacity(0.7) : tint.opacity(scheme == .dark ? 0.22 : 0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark || reduceTransparency ? 0 : 0.04), radius: 8, y: 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Cards

enum CardStyle {
    /// A card on the page: soft shadow, hairline edge.
    case standard
    /// A large summary card.
    case large
    /// A box inside a card: no shadow.
    case inner

    var radius: CGFloat {
        switch self {
        case .standard: Theme.Radius.card
        case .large: Theme.Radius.large
        case .inner: Theme.Radius.small
        }
    }
}

/// The card surface used across the app: the secondary background, a hairline edge, a soft shadow in light mode (never
/// on the content), an optional faint tint. Increase Contrast draws a clear edge instead.
struct CardSurface: ViewModifier {
    var style: CardStyle = .standard
    var tint: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.background.secondary)
                        .shadow(color: .black.opacity(style == .inner || scheme == .dark ? 0 : 0.06), radius: 6, y: 2)
                    if let tint { shape.fill(tint.opacity(scheme == .dark ? 0.12 : 0.06)) }
                    shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : Color.primary.opacity(scheme == .dark ? 0.09 : 0.05),
                                       lineWidth: 1)
                }
            }
    }
}

/// The frosted card of the summaries (Money, Sales): a material with a faint wash of the card's tint and a soft shadow
/// under it. Solid with Reduce Transparency, outlined with Increase Contrast.
struct FrostedCard: ViewModifier {
    var tint: Color?
    var radius: CGFloat = Theme.Radius.large
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if reduceTransparency { shape.fill(.background.secondary) } else { shape.fill(.regularMaterial) }
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.10 : 0.07), tint.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.07), radius: 12, y: 4)
            }
    }
}

extension View {
    func frostedCard(tint: Color? = nil, radius: CGFloat = Theme.Radius.large) -> some View {
        modifier(FrostedCard(tint: tint, radius: radius))
    }

    func cardSurface(_ style: CardStyle = .standard, tint: Color? = nil) -> some View {
        modifier(CardSurface(style: style, tint: tint))
    }

    /// A gentle highlight under the pointer, for rows that open or act. Instant with Reduce Motion; nothing on iPhone.
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.small) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    /// The tinted capsule of a status pill. Use with `PillTone` for the text colour.
    func pillBackground(_ color: Color, radius: CGFloat? = nil) -> some View {
        modifier(PillBackground(color: color, radius: radius))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            #if os(macOS)
            .onHover { inside in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hovering = inside }
            }
            #endif
    }
}

private struct PillBackground: ViewModifier {
    let color: Color
    let radius: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? 100, style: .continuous)
        content
            .background(color.opacity(Theme.pillTint), in: shape)
            // With Increase Contrast the pill gets a clear edge.
            .overlay { if contrast == .increased { shape.strokeBorder(color.opacity(0.75), lineWidth: 1) } }
    }
}

// MARK: - Pills

/// The text colour of a pill: its own colour when that colour keeps 4.5:1 on the tinted pill, otherwise the primary
/// text colour. The status tokens always pass (checked by make_colors.py); a system colour such as purple or teal is
/// often too light for text, and then only the icon and the tint carry it.
enum PillTone {
    static func text(_ color: Color, in environment: EnvironmentValues) -> Color {
        let fg = color.resolve(in: environment)
        let dark = environment.colorScheme == .dark
        let page: (Float, Float, Float) = dark ? (0.17, 0.17, 0.18) : (0.95, 0.95, 0.97)
        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a * t + b * (1 - t) }
        // The colour as drawn (its own opacity over the page), and the pill behind it.
        let alpha = fg.opacity
        let text = (mix(fg.red, page.0, alpha), mix(fg.green, page.1, alpha), mix(fg.blue, page.2, alpha))
        let tint = Float(Theme.pillTint)
        let pill = (mix(text.0, page.0, tint), mix(text.1, page.1, tint), mix(text.2, page.2, tint))
        return contrast(text, pill) >= 4.5 ? color : .primary
    }

    private static func luminance(_ c: (Float, Float, Float)) -> Float {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    private static func contrast(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Icon and text on a tinted capsule: the shape every status pill shares, so colour never carries meaning alone.
struct PillLabel: View {
    let text: Text
    var symbol: String?
    let color: Color
    var font: Font = .caption.weight(.semibold)
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            }
            text.foregroundStyle(PillTone.text(color, in: environment))
        }
        .font(font)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .pillBackground(color)
        .fixedSize()
    }
}

// MARK: - Number cards

/// A number with its label on a softly tinted card with an accent edge: the Monitor counts and similar summaries.
struct KPITile: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color
    /// Stretches to the width it is offered (a grid cell) instead of hugging its content.
    var fills = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(verbatim: label) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .frame(minWidth: 110, maxWidth: fills ? .infinity : nil, alignment: .leading)
        .cardSurface(tint: tint)
        .overlay(alignment: .leading) { AccentEdge(tint: tint, radius: Theme.Radius.card) }
        .accessibilityElement(children: .combine)
    }
}

/// A coloured edge on the leading side of a card (mirrors in Dari).
struct AccentEdge: View {
    let tint: Color
    var radius: CGFloat = Theme.Radius.card

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous)
            .fill(tint)
            .frame(width: 4)
            .accessibilityHidden(true)
    }
}
