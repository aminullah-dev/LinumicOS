import Foundation

// MARK: - Ledgers (دفترها): PRIORITIES.md
//
// The owner's PRIORITIES.md files are Markdown written by people and agents. The parser reads only what it can be sure
// of: open checkboxes (`- [ ] …`) at any indentation, the numbered list under a heading that says «اولویت», the
// section each sits in (P0, P1, …) and the «آخرین بازبینی» date. A line that looks like an item but can't be
// understood is set aside by line number, never guessed.

enum LedgerText {
    /// Persian (۰–۹) and Arabic-Indic (٠–٩) digits as ASCII, so "۲۰۲۶-۱۰-۱۹" reads as a date.
    static func asciiDigits(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x06F0...0x06F9).contains($0.value) || (0x0660...0x0669).contains($0.value) }) else {
            return s
        }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(u.value - 0x06F0 + 0x30)!)
            case 0x0660...0x0669: out.append(Unicode.Scalar(u.value - 0x0660 + 0x30)!)
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// The text after the first occurrence of `needle`, compared by Unicode scalars. Swift's `contains` compares whole
    /// characters, and a zero-width non-joiner joins the letter before it («اولویت‌های»), so «اولویت» would not match.
    static func suffix(after needle: String, in s: some StringProtocol) -> String? {
        let h = Array(s.unicodeScalars), n = Array(needle.unicodeScalars)
        guard !n.isEmpty, h.count >= n.count else { return nil }
        for i in 0...(h.count - n.count) where h[i] == n[0] && Array(h[i..<(i + n.count)]) == n {
            var rest = String.UnicodeScalarView()
            rest.append(contentsOf: h[(i + n.count)...])
            return String(rest)
        }
        return nil
    }

    static func contains(_ s: some StringProtocol, _ needle: String) -> Bool {
        suffix(after: needle, in: s) != nil
    }

    /// The first YYYY-MM-DD day in `s` (any digits), or nil.
    static func firstDay(in s: String) -> KeyDay? {
        let ascii = asciiDigits(s)
        guard let m = ascii.firstMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#) else { return nil }
        return KeyDay("\(m.1)-\(m.2)-\(m.3)")
    }

    /// Indentation width (a tab counts as four spaces).
    static func indent(_ line: Substring) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    /// "**Title:** rest" → ("Title", "rest"); otherwise the whole text is the title.
    static func titleAndDetail(_ text: String) -> (title: String, detail: String?) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("**"), let close = t.dropFirst(2).range(of: "**") else { return (t, nil) }
        var title = String(t[t.index(t.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        while let last = title.last, ":.،؛".contains(last) { title.removeLast() }
        var rest = t[close.upperBound...].trimmingCharacters(in: .whitespaces)
        while let first = rest.first, ":.—–-".contains(first) { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !title.isEmpty else { return (t, nil) }
        return (title, rest.isEmpty ? nil : rest)
    }
}

/// The section an item sits in, from its heading ("## P0 — فوری").
public enum LedgerPriority: String, Sendable, Hashable {
    case p0, p1, other

    /// P0 is high, P1 normal, everything else for information (roadmap §4).
    public var severity: BriefSeverity {
        switch self {
        case .p0: .high
        case .p1: .normal
        case .other: .info
        }
    }
}

public struct LedgerItem: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        /// `- [ ] …`
        case checkbox
        /// `1. …` under a heading that says «اولویت».
        case numbered
    }

    public var kind: Kind
    /// 1-based line number in the file.
    public var line: Int
    /// The item's text after the marker, as written.
    public var text: String
    /// The bold lead ("**…**") when there is one, else the whole text.
    public var title: String
    public var detail: String?
    public var priority: LedgerPriority
    /// The heading the item sits under, without the #s.
    public var section: String?
    /// Leading spaces (a nested sub-item has more).
    public var indent: Int

    public init(kind: Kind, line: Int, text: String, title: String, detail: String?, priority: LedgerPriority,
                section: String?, indent: Int) {
        self.kind = kind
        self.line = line
        self.text = text
        self.title = title
        self.detail = detail
        self.priority = priority
        self.section = section
        self.indent = indent
    }
}

public struct ParsedLedger: Hashable, Sendable {
    /// Open items in file order.
    public var items: [LedgerItem]
    /// Ticked checkboxes (`- [x]`), for the summary only.
    public var ticked: Int
    /// The day in the «آخرین بازبینی» line; nil when the file has none.
    public var reviewedOn: KeyDay?
    public var reviewLine: Int?
    /// Lines that looked like an item but could not be understood (an empty checkbox, "- []", "-[ ]x", "1." alone).
    public var skippedLines: [Int]

    public init(items: [LedgerItem] = [], ticked: Int = 0, reviewedOn: KeyDay? = nil, reviewLine: Int? = nil,
                skippedLines: [Int] = []) {
        self.items = items
        self.ticked = ticked
        self.reviewedOn = reviewedOn
        self.reviewLine = reviewLine
        self.skippedLines = skippedLines
    }
}

public enum LedgerParser {
    /// The words that open the review line and a priorities heading.
    public static let reviewMarker = "آخرین بازبینی"
    public static let prioritiesMarker = "اولویت"

    public static func parse(_ text: String) -> ParsedLedger {
        var result = ParsedLedger()
        var headings: [(level: Int, text: String)] = []
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let number = index + 1
            let raw = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let h = heading(trimmed) {
                while let last = headings.last, last.level >= h.level { headings.removeLast() }
                headings.append(h)
                continue
            }
            // «آخرین بازبینی: ۲۰۲۶-۱۰-۱۹ (…)»: the first such line, the first day after its colon.
            if result.reviewLine == nil, let rest = LedgerText.suffix(after: reviewMarker, in: trimmed) {
                let after = rest.drop { $0 == " " || $0 == "*" }
                if after.first == ":" {
                    result.reviewLine = number
                    result.reviewedOn = LedgerText.firstDay(in: String(after.dropFirst()))
                }
            }
            let priority = priority(headings)
            let section = headings.last?.text
            switch checkbox(raw) {
            case .open(let body, let indent):
                let (title, detail) = LedgerText.titleAndDetail(body)
                result.items.append(LedgerItem(kind: .checkbox, line: number, text: body, title: title, detail: detail,
                                               priority: priority, section: section, indent: indent))
                continue
            case .ticked:
                result.ticked += 1
                continue
            case .broken:
                result.skippedLines.append(number)
                continue
            case .none:
                break
            }
            guard let section, LedgerText.contains(section, prioritiesMarker) else { continue }
            switch numbered(raw) {
            case .open(let body, let indent):
                let (title, detail) = LedgerText.titleAndDetail(body)
                result.items.append(LedgerItem(kind: .numbered, line: number, text: body, title: title, detail: detail,
                                               priority: priority, section: section, indent: indent))
            case .broken:
                result.skippedLines.append(number)
            case .ticked, .none:
                break
            }
        }
        return result
    }

    // MARK: Line shapes

    enum Shape: Equatable {
        case open(String, Int)
        case ticked
        case broken
    }

    /// An ATX heading ("## P0 — فوری") as level and text.
    static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        guard let m = trimmed.wholeMatch(of: #/(#{1,6})\s+(.+?)\s*#*/#) else { return nil }
        return (m.1.count, String(m.2))
    }

    /// The innermost heading that names a priority (P0, P1, …) decides; P2 and anything else is "other".
    static func priority(_ headings: [(level: Int, text: String)]) -> LedgerPriority {
        for h in headings.reversed() {
            let text = LedgerText.asciiDigits(h.text).trimmingCharacters(in: .whitespaces)
            guard let m = text.prefixMatch(of: #/[Pp](\d)\b/#) else { continue }
            switch m.1 {
            case "0": return .p0
            case "1": return .p1
            default: return .other
            }
        }
        return .other
    }

    static func checkbox(_ raw: Substring) -> Shape? {
        let line = String(raw)
        if let m = line.wholeMatch(of: #/(\s*)[-*+]\s+\[ \]\s+(\S.*)/#) {
            return .open(String(m.2).trimmingCharacters(in: .whitespaces), LedgerText.indent(raw))
        }
        if line.wholeMatch(of: #/\s*[-*+]\s+\[[xX]\](\s+.*)?/#) != nil { return .ticked }
        // Looks like a checkbox ("- []", "-[ ]", "- [ ]" alone, "- [-] …", "- [ ]text") but is none of the above.
        // A link ("- [PR](…)") is not a checkbox.
        if line.prefixMatch(of: #/\s*[-*+]\s*\[.?\](?!\()/#) != nil { return .broken }
        return nil
    }

    static func numbered(_ raw: Substring) -> Shape? {
        let line = LedgerText.asciiDigits(String(raw))
        if let m = line.wholeMatch(of: #/(\s*)\d+[.)]\s+(\S.*)/#) {
            return .open(String(m.2).trimmingCharacters(in: .whitespaces), LedgerText.indent(raw))
        }
        if line.wholeMatch(of: #/\s*\d+[.)]\s*/#) != nil { return .broken }
        return nil
    }
}
