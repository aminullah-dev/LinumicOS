import Foundation

// MARK: - Ledgers (دفترها): NEXT-ACTIONS-<day>.md
//
// The daily "next actions" report in ~/Projects/Multiplatform. Only the owner's own sections are read: "(TODAY)" and
// "(THIS WEEK)". An item is a line "1) …" at the start of the line, and it must carry a «منبع: <Product> / <slug>»
// line; an item without one is set aside by line number, not guessed. So is any other numbered or bulleted line at the
// start of a line in those sections, and a «منبع» line that belongs to no item. Claude's own sections, "SAFE TO
// IGNORE" and "CONTRADICTIONS" are not tasks for the owner and are not read.

public enum NextActionsSection: String, Sendable, Hashable {
    case today, thisWeek

    /// The section a "(TAG)" heading opens, or nil for any other tag.
    static func from(tag: String) -> NextActionsSection? {
        switch normalized(tag) {
        case "TODAY": .today
        case "THIS WEEK": .thisWeek
        default: nil
        }
    }

    /// The tags of the report's other sections: Claude's own work, what can be ignored, and contradictions.
    static let otherTags: Set<String> = ["CLAUDE CAN DO NOW", "SAFE TO IGNORE", "CONTRADICTIONS"]

    static func normalized(_ tag: String) -> String {
        tag.uppercased().split(separator: " ").joined(separator: " ")
    }
}

public struct NextActionItem: Hashable, Sendable {
    public var section: NextActionsSection
    /// 1-based line of the "1) …" line.
    public var line: Int
    public var number: Int
    public var title: String
    /// The lines under the item (trimmed, the «منبع» line left out), in order.
    public var body: [String]
    /// "WorkTrack" in «منبع: WorkTrack / first-customer-contract».
    public var product: String
    /// "first-customer-contract".
    public var slug: String
    public var sourceLine: Int
    /// The whole «منبع: …» text, kept for the agent brief.
    public var sourceText: String
    /// Other products the «منبع» line names after the first ("Talar", "NerkhTimes"), in order, without repeats.
    public var otherProducts: [String]

    public init(section: NextActionsSection, line: Int, number: Int, title: String, body: [String], product: String,
                slug: String, sourceLine: Int, sourceText: String, otherProducts: [String] = []) {
        self.section = section
        self.line = line
        self.number = number
        self.title = title
        self.body = body
        self.product = product
        self.slug = slug
        self.sourceLine = sourceLine
        self.sourceText = sourceText
        self.otherProducts = otherProducts
    }
}

public struct ParsedNextActions: Hashable, Sendable {
    /// The report's day: from the file name, else the first date in its first line.
    public var day: KeyDay?
    public var items: [NextActionItem]
    /// Lines set aside in the owner's sections: items with no «منبع» line, numbered or bulleted lines at the start of a
    /// line that are not items, and «منبع» lines that belong to no item. In file order.
    public var skippedLines: [Int]
    /// The owner sections that were found (a report without them yields no items, which is not "0 to do").
    public var sections: Set<NextActionsSection>

    public init(day: KeyDay? = nil, items: [NextActionItem] = [], skippedLines: [Int] = [], sections: Set<NextActionsSection> = []) {
        self.day = day
        self.items = items
        self.skippedLines = skippedLines
        self.sections = sections
    }
}

public enum NextActionsParser {
    public static let filePrefix = "NEXT-ACTIONS-"
    public static let sourceMarker = "منبع:"

    /// The day in "NEXT-ACTIONS-2026-10-19.md", or nil when the name is anything else.
    public static func day(fromFileName name: String) -> KeyDay? {
        guard let m = name.wholeMatch(of: #/NEXT-ACTIONS-(\d{4}-\d{2}-\d{2})\.md/#) else { return nil }
        return KeyDay(String(m.1))
    }

    /// The newest NEXT-ACTIONS file among `names`, by the day in its name.
    public static func newest(_ names: [String]) -> String? {
        names.compactMap { n in day(fromFileName: n).map { (n, $0) } }.max { $0.1 < $1.1 }?.0
    }

    public static func parse(_ text: String, fileName: String? = nil) -> ParsedNextActions {
        let lines = LedgerText.lines(text).map(String.init)
        var result = ParsedNextActions()
        result.day = fileName.flatMap(day(fromFileName:)) ?? lines.first.flatMap { LedgerText.firstDay(in: $0) }

        var section: NextActionsSection?
        var current: (line: Int, number: Int, title: String, body: [String], source: (line: Int, text: String)?)?
        var currentSection: NextActionsSection?

        func flush() {
            guard let c = current, let s = currentSection else { return }
            current = nil
            guard let src = c.source, let parsed = sourceParts(src.text) else {
                result.skippedLines.append(c.line)
                return
            }
            var others: [String] = []
            for pair in sourcePairs(src.text) where pair.product != parsed.product && !others.contains(pair.product) {
                others.append(pair.product)
            }
            result.items.append(NextActionItem(section: s, line: c.line, number: c.number, title: c.title, body: c.body,
                                               product: parsed.product, slug: parsed.slug, sourceLine: src.line,
                                               sourceText: src.text, otherProducts: others))
        }

        for (index, line) in lines.enumerated() {
            let number = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ascii = LedgerText.asciiDigits(line)
            if let opened = heading(ascii) {
                flush()
                section = opened
                if let section { result.sections.insert(section) }
                continue
            }
            guard section != nil else { continue }
            if let m = ascii.wholeMatch(of: #/(\d+)\)\s+(\S.*)/#) {
                flush()
                current = (number, Int(m.1) ?? 0, String(line.drop { $0 != ")" }.dropFirst()).trimmingCharacters(in: .whitespaces),
                           [], nil)
                currentSection = section
                continue
            }
            if let source = sourceText(trimmed) {
                // The item's «منبع» line; a second one, or one outside any item, is set aside.
                if current != nil, current?.source == nil {
                    current?.source = (number, source)
                } else {
                    result.skippedLines.append(number)
                }
                continue
            }
            // Numbered or bulleted at the start of the line, but not "N) …": another numbering style ("1. …", "**1)** …"),
            // or a line that would otherwise be taken for a heading. Set aside; the item above keeps its lines.
            if ascii.prefixMatch(of: #/(?:\*\*)?\d+(?:\*\*)?[.)]|[-*+]\s/#) != nil {
                result.skippedLines.append(number)
                continue
            }
            guard current != nil, !trimmed.isEmpty else { continue }
            current?.body.append(trimmed)
        }
        flush()
        result.skippedLines.sort()
        return result
    }

    /// A section heading, and the owner's section it opens (nil for any other section); nil overall when the line is
    /// no heading. A Markdown heading ("## …") always is one. A numbered line ending in a tag ("۱. امروز، … (TODAY)")
    /// is one only when the tag is known, so a line such as "2. merge the branch (PR)" does not end the section.
    static func heading(_ ascii: String) -> NextActionsSection?? {
        let tag = ascii.firstMatch(of: #/\(([A-Z][A-Z ]*[A-Z])\)\s*$/#).map { NextActionsSection.normalized(String($0.1)) }
        if ascii.prefixMatch(of: #/#+\s/#) != nil {
            return .some(tag.flatMap(NextActionsSection.from(tag:)))
        }
        guard let tag, ascii.prefixMatch(of: #/\d+\.\s/#) != nil else { return nil }
        if let owner = NextActionsSection.from(tag: tag) { return .some(owner) }
        return NextActionsSection.otherTags.contains(tag) ? .some(nil) : nil
    }

    /// The text after «منبع:», also when written "- منبع:", "**منبع:**" or "منبع :"; nil for any other line.
    static func sourceText(_ trimmed: String) -> String? {
        var s = Substring(trimmed)
        if let first = s.first, "-*+".contains(first), s.dropFirst().first?.isWhitespace == true {
            s = s.dropFirst().drop(while: \.isWhitespace)
        }
        s = s.drop { $0 == "*" || $0 == "_" }
        let word = sourceMarker.dropLast()   // «منبع»
        guard s.hasPrefix(word) else { return nil }
        let rest = s.dropFirst(word.count).drop { $0 == " " || $0 == "*" || $0 == "_" }
        guard rest.first == ":" else { return nil }
        return rest.dropFirst().drop { $0 == " " || $0 == "*" || $0 == "_" }.trimmingCharacters(in: .whitespaces)
    }

    /// "WorkTrack / first-customer-contract (…)؛ Talar / …" → ("WorkTrack", "first-customer-contract"): the first pair.
    static func sourceParts(_ text: String) -> (product: String, slug: String)? {
        guard let m = text.firstMatch(of: #/([^/؛،;]+?)\s*/\s*([A-Za-z0-9][A-Za-z0-9._-]*)/#) else { return nil }
        let product = String(m.1).trimmingCharacters(in: .whitespaces)
        guard !product.isEmpty else { return nil }
        return (product, String(m.2))
    }

    /// Every "Product / slug" pair, one per part between «؛». Text in parentheses ("(PRIORITIES.md:13؛ …)") holds file
    /// paths and notes, not products, and is left out; so is a "slug" with a dot (a file name).
    static func sourcePairs(_ text: String) -> [(product: String, slug: String)] {
        var plain = ""
        var depth = 0
        for c in text {
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) } else if depth == 0 { plain.append(c) }
        }
        return plain.split(whereSeparator: { "؛;".contains($0) }).compactMap { part in
            guard let m = String(part).prefixMatch(of: #/\s*([^/،~]+?)\s*/\s*([A-Za-z0-9][A-Za-z0-9_-]*)(?![A-Za-z0-9_.-])/#) else { return nil }
            let product = String(m.1).trimmingCharacters(in: .whitespaces)
            return product.isEmpty ? nil : (product, String(m.2))
        }
    }
}
