import Foundation

// MARK: - Legal & company (حقوقی و شرکت): the markers in the owner's legal drafts
//
// Module 7 of docs/company-os-roadmap.md. The owner's drafts mark what is still open with three markers: [TO FILL] (a
// value to fill in), [LAWYER] (a question for the lawyer) and [TO DECIDE] (a decision of the owner's). The app counts
// them with the file and line of each, and keeps nothing else of the text: no sentence, no word around a marker, no
// value. Read-only, on the Mac, inside the one folder the owner granted (docs/legal.md).

/// One of the three markers.
public enum LegalMarkerKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case toFill, lawyer, toDecide

    public var id: String { rawValue }

    /// The marker's word inside the bracket, as the drafts write it (upper case).
    public var word: String {
        switch self {
        case .toFill: "TO FILL"
        case .lawyer: "LAWYER"
        case .toDecide: "TO DECIDE"
        }
    }

    /// "[TO FILL]", shown as written (never translated: it is the text the owner searches for).
    public var label: String { "[\(word)]" }

    /// What the marker asks for, in the app's language.
    public var title: String {
        switch self {
        case .toFill: L("To fill")
        case .lawyer: L("For the lawyer")
        case .toDecide: L("To decide")
        }
    }
}

/// One marker: its kind and its 1-based line. Nothing of the line's text.
public struct LegalMarkerHit: Hashable, Sendable, Codable {
    public var kind: LegalMarkerKind
    public var line: Int

    public init(kind: LegalMarkerKind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

/// Finds the markers in a text, the way `grep -noE` does with `LegalMarkerScanner.pattern`: a "[", one of the three
/// words in upper case, then "]", ":", a space or any other character that is not an ASCII letter or digit (or the end of
/// the line). So "[TO FILL]", "[TO FILL: date]" and "[LAWYER — tax]" count, "[TO FILLED]" and "[lawyer]" do not. Each
/// occurrence counts once, several on one line too. Lines are split at "\n", as grep splits them (a "\r" before it is a
/// character of the line).
public enum LegalMarkerScanner {
    /// The same rule as an extended regular expression, for grep: `grep -rnoE '<pattern>' <folder>`.
    public static let pattern = #"\[(TO FILL|LAWYER|TO DECIDE)([^A-Za-z0-9]|$)"#

    private static let regex: NSRegularExpression = {
        // Lines are matched one at a time, so "$" is the end of the line.
        try! NSRegularExpression(pattern: pattern)
    }()

    public static func scan(_ text: String) -> [LegalMarkerHit] {
        var hits: [LegalMarkerHit] = []
        var number = 0
        // Split the bytes, not the Characters: Swift reads "\r\n" as one Character, which a split at "\n" would not cut.
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            number += 1
            // A line without "[" holds no marker: most lines are skipped without a regular expression.
            guard line.contains(UInt8(ascii: "[")) else { continue }
            let s = String(decoding: line, as: UTF8.self)
            let ns = s as NSString
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let kind = kind(ns.substring(with: m.range(at: 1))) else { continue }
                hits.append(LegalMarkerHit(kind: kind, line: number))
            }
        }
        return hits
    }

    static func kind(_ word: String) -> LegalMarkerKind? {
        LegalMarkerKind.allCases.first { $0.word == word }
    }
}
