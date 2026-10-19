import Foundation

// MARK: - Ledgers (دفترها): NEXT-ACTIONS-<day>.md
//
// The daily "next actions" report in ~/Projects/Multiplatform. Only the owner's own sections are read: "(TODAY)" and
// "(THIS WEEK)". An item is a line "1) …" at the start of the line, and it must carry a «منبع: <Product> / <slug>»
// line; an item without one is set aside by line number, not guessed. Claude's own sections, "SAFE TO IGNORE" and
// "CONTRADICTIONS" are not tasks for the owner and are not read.

public enum NextActionsSection: String, Sendable, Hashable {
    case today, thisWeek

    /// The section a "(TAG)" heading opens, or nil for any other tag.
    static func from(tag: String) -> NextActionsSection? {
        switch tag.uppercased().split(separator: " ").joined(separator: " ") {
        case "TODAY": .today
        case "THIS WEEK": .thisWeek
        default: nil
        }
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

    public init(section: NextActionsSection, line: Int, number: Int, title: String, body: [String], product: String,
                slug: String, sourceLine: Int, sourceText: String) {
        self.section = section
        self.line = line
        self.number = number
        self.title = title
        self.body = body
        self.product = product
        self.slug = slug
        self.sourceLine = sourceLine
        self.sourceText = sourceText
    }
}

public struct ParsedNextActions: Hashable, Sendable {
    /// The report's day: from the file name, else the first date in its first line.
    public var day: KeyDay?
    public var items: [NextActionItem]
    /// Lines of items with no «منبع» line.
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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { l in
            String(l.hasSuffix("\r") ? l.dropLast() : l)
        }
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
            result.items.append(NextActionItem(section: s, line: c.line, number: c.number, title: c.title, body: c.body,
                                               product: parsed.product, slug: parsed.slug, sourceLine: src.line,
                                               sourceText: src.text))
        }

        for (index, line) in lines.enumerated() {
            let number = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ascii = LedgerText.asciiDigits(line)
            // A section heading starts the line with "N." (or #s) and ends with an upper-case tag: "۱. امروز، … (TODAY)".
            if let m = ascii.wholeMatch(of: #/(?:\d+\.|#+)\s.*\(([A-Z][A-Z ]*[A-Z])\)\s*/#) {
                flush()
                section = NextActionsSection.from(tag: String(m.1))
                if let section { result.sections.insert(section) }
                continue
            }
            guard let section else { continue }
            if let m = ascii.wholeMatch(of: #/(\d+)\)\s+(\S.*)/#) {
                flush()
                current = (number, Int(m.1) ?? 0, String(line.drop { $0 != ")" }.dropFirst()).trimmingCharacters(in: .whitespaces),
                           [], nil)
                currentSection = section
                continue
            }
            guard current != nil, !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix(sourceMarker), current?.source == nil {
                current?.source = (number, String(trimmed.dropFirst(sourceMarker.count)).trimmingCharacters(in: .whitespaces))
            } else {
                current?.body.append(trimmed)
            }
        }
        flush()
        return result
    }

    /// "WorkTrack / first-customer-contract (…)؛ Talar / …" → ("WorkTrack", "first-customer-contract"): the first pair.
    static func sourceParts(_ text: String) -> (product: String, slug: String)? {
        guard let m = text.firstMatch(of: #/([^/؛،;]+?)\s*/\s*([A-Za-z0-9][A-Za-z0-9._-]*)/#) else { return nil }
        let product = String(m.1).trimmingCharacters(in: .whitespaces)
        guard !product.isEmpty else { return nil }
        return (product, String(m.2))
    }
}
