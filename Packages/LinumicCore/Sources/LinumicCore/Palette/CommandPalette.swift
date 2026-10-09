import Foundation

// MARK: - Command palette (Cmd+K): text normalisation, fuzzy matching, ranking, recents
//
// Pure logic. The App builds the candidates from the state it already has (sidebar destinations, products,
// WorkTrack companies, licences, vault entry TITLES, monitor targets, release apps, open PRs, existing actions) and
// maps the chosen id back to navigation. Nothing here knows about secrets or performs anything.

public enum PaletteText {
    /// Folds text so English and Dari/Persian queries match regardless of case, accents, Arabic vs Persian letter
    /// forms, zero-width joiners, tatweel, bidi marks and digit script.
    ///
    /// - Arabic yeh/alef maksura (ي ى ئ) -> Persian yeh (ی); Arabic kaf (ك) -> keheh (ک)
    /// - teh marbuta (ة), heh with yeh (ۀ), ae (ە) -> heh (ه); alef forms (أ إ آ ٱ) -> alef (ا); waw with hamza (ؤ) -> و
    /// - harakat, tanwin, superscript alef and tatweel removed; ZWNJ/ZWJ removed (so "می‌شود" matches "میشود")
    /// - Persian and Arabic-Indic digits -> ASCII digits; whitespace collapsed; lowercased; Latin accents removed
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0x064A, 0x0649, 0x0626, 0x06CC, 0x06D0: scalars.append("\u{06CC}")   // ی
            case 0x0643, 0x06A9: scalars.append("\u{06A9}")                            // ک
            case 0x0629, 0x06C0, 0x06D5, 0x0647, 0x06C1: scalars.append("\u{0647}")    // ه
            case 0x0622, 0x0623, 0x0625, 0x0671, 0x0627: scalars.append("\u{0627}")    // ا
            case 0x0624: scalars.append("\u{0648}")                                    // و
            case 0x064B...0x065F, 0x0670, 0x0640: continue                             // harakat, superscript alef, tatweel
            case 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(s.value - 0x06F0 + 0x30)!)
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(s.value - 0x0660 + 0x30)!)
            default: scalars.append(s)
            }
        }
        let folded = String(scalars).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public enum FuzzyMatch {
    /// Scores one normalised query token against normalised text; nil when it doesn't match at all.
    /// Exact > prefix > word prefix > substring > in-order subsequence (with bonuses for consecutive letters and
    /// letters at word starts, and a penalty for gaps).
    public static func score(_ query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !text.isEmpty else { return nil }
        if text == query { return 1000 }
        if text.hasPrefix(query) { return 800 - min(text.count - query.count, 100) }
        if text.contains(" " + query) || text.contains("/" + query) || text.contains("-" + query) || text.contains("." + query) {
            return 600 - min(text.count - query.count, 100)
        }
        if text.contains(query) { return 400 - min(text.count - query.count, 100) }

        let t = Array(text), q = Array(query)
        var qi = 0, score = 100, previous = -2, gaps = 0
        for (i, c) in t.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            if i == previous + 1 { score += 12 }
            if i == 0 || [" ", "/", "-", ".", "_"].contains(t[i - 1]) { score += 15 }
            if previous >= 0 { gaps += i - previous - 1 }
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return max(1, score - min(gaps, 90))
    }
}

/// One thing the palette can offer.
public struct PaletteCandidate: Identifiable, Hashable, Sendable {
    public enum Group: Int, Sendable, Comparable, CaseIterable {
        case navigation = 0, action = 1, entity = 2
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .navigation: L("Go to")
            case .action: L("Actions")
            case .entity: L("Items")
            }
        }
    }

    /// Stable across launches (it is what the recents list stores), e.g. "nav.monitor", "licence.MF-2026-0003".
    public var id: String
    public var title: String
    public var subtitle: String?
    /// Extra searchable words: the English name of a Dari title, product names, ids.
    public var keywords: [String]
    public var group: Group
    public var symbol: String

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String] = [], group: Group, symbol: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.group = group
        self.symbol = symbol
    }
}

public enum PaletteRanker {
    public static let defaultLimit = 50

    /// Score of a whole (possibly multi-word) query: every word must match the title, subtitle or a keyword.
    /// Title matches count fully, the others less.
    public static func score(_ query: String, _ candidate: PaletteCandidate) -> Int? {
        let tokens = PaletteText.normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let title = PaletteText.normalize(candidate.title)
        let others = ([candidate.subtitle].compactMap { $0 } + candidate.keywords).map(PaletteText.normalize)
        var total = 0
        for token in tokens {
            var best = FuzzyMatch.score(token, in: title)
            for o in others {
                if let s = FuzzyMatch.score(token, in: o) { best = max(best ?? 0, s / 2) }
            }
            guard let best else { return nil }
            total += best
        }
        // The whole query as one phrase in the title is better than its words scattered.
        if tokens.count > 1, title.contains(tokens.joined(separator: " ")) { total += 200 }
        return total
    }

    /// Empty query: recents first (most recent first), then every candidate by group in the given order.
    /// With a query: matches only, best first; recent items get a bonus that fades with age; ties keep group order.
    public static func rank(_ query: String, _ candidates: [PaletteCandidate], recents: [String] = [],
                            limit: Int = defaultLimit) -> [PaletteCandidate] {
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let position = Dictionary(candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        if PaletteText.normalize(query).isEmpty {
            let recent = recents.compactMap { id in candidates.first { $0.id == id } }
            let rest = candidates.filter { recentIndex[$0.id] == nil }
                .sorted { ($0.group, position[$0.id] ?? 0) < ($1.group, position[$1.id] ?? 0) }
            return Array((recent + rest).prefix(limit))
        }
        let scored: [(PaletteCandidate, Int)] = candidates.compactMap { c in
            guard var s = score(query, c) else { return nil }
            if let r = recentIndex[c.id] { s += max(0, 120 - r * 10) }
            return (c, s)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return (a.0.group, position[a.0.id] ?? 0) < (b.0.group, position[b.0.id] ?? 0)
        }
        .prefix(limit).map(\.0)
    }
}

/// The ids chosen most recently, newest first. The App keeps it in UserDefaults (ids only).
public struct PaletteRecents: Codable, Equatable, Sendable {
    public static let capacity = 12
    public private(set) var ids: [String]

    public init(ids: [String] = []) { self.ids = Array(ids.prefix(Self.capacity)) }

    public mutating func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.capacity { ids.removeLast(ids.count - Self.capacity) }
    }

    /// Drops ids that no longer exist (a deleted licence, a closed PR).
    public mutating func keep(only existing: Set<String>) {
        ids.removeAll { !existing.contains($0) }
    }
}
