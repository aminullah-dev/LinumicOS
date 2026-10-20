import Foundation

// MARK: - The CRM answer's shape (the owner's one check)
//
// One `GET /v1/vendor/crm/accounts`, kept as key names, JSON types and counts only. Every value is dropped while the
// report is built, so nothing a customer record says (a name, a note, a phone number) is in it. What the server is
// expected to send: `shape()` (`services/crm.ts:147-155`) spreads the stored document and adds `id`, `createdAt` and
// `updatedAt`; the stored document is what `accountWriteSchema` (`crm.ts:36-51`) accepted, where every field but
// `name` and `stage` is `nullish`, and the WorkTrack console saves a cleared field as null
// (`web/src/pages/vendor/AccountDetail.tsx:72-83`). An account created by a support ticket has `stage: "WON"` and no
// next step (`routes/support.ts:49-68`).

public struct WTShapeReport: Equatable, Sendable {
    /// What a field may be.
    public enum Expectation: Equatable, Sendable {
        /// Present in every row, of this JSON type, never null.
        case always(String)
        /// Present in every row: this JSON type or null.
        case alwaysOrNull(String)
        /// This JSON type, null, or absent.
        case optional(String)

        public var text: String {
            switch self {
            case .always(let t): LF("%@ in every row", t)
            case .alwaysOrNull(let t): LF("%@ or null in every row", t)
            case .optional(let t): LF("%@, null or absent", t)
            }
        }

        /// Whether one row's value (nil: the key is absent) fits.
        func fits(_ value: WTJSON?) -> Bool {
            switch (self, value) {
            case (.always, nil), (.alwaysOrNull, nil): false
            case (.optional, nil): true
            case (.always, .null?): false
            case (.alwaysOrNull, .null?), (.optional, .null?): true
            case (.always(let t), let v?), (.alwaysOrNull(let t), let v?), (.optional(let t), let v?): WTShapeReport.typeName(v) == t
            }
        }
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public var name: String
        public var expected: Expectation
        /// Rows where the key is there (null included).
        public var present: Int
        public var null: Int
        /// JSON type name ("string", "number", "bool", "array", "object") → rows, nulls left out.
        public var types: [String: Int]
        /// Rows whose value does not fit `expected`.
        public var differing: Int
        public var id: String { name }
    }

    /// The keys `shape()` can send, in the write schema's order, with what each may be.
    public static let expected: [(String, Expectation)] = [
        ("id", .always("string")), ("name", .always("string")), ("stage", .always("string")),
        ("companyId", .optional("string")), ("city", .optional("string")), ("industry", .optional("string")),
        ("source", .optional("string")), ("employeesEstimate", .optional("number")), ("nextActionAt", .optional("string")),
        ("nextAction", .optional("string")), ("notes", .optional("string")),
        ("createdAt", .alwaysOrNull("string")), ("updatedAt", .alwaysOrNull("string")),
        ("createdBy", .optional("string")), ("updatedBy", .optional("string")),
    ]

    public var readAt: Date
    /// Elements of `data`.
    public var rows: Int
    /// Elements that are not JSON objects.
    public var nonObjects: Int
    public var fields: [Field]
    /// Key names seen that the server is not expected to send, sorted. Names only.
    public var unexpectedKeys: [String]
    /// `stage` strings outside `ACCOUNT_STAGES`.
    public var unknownStages: Int
    /// `nextActionAt` strings that are not a real `YYYY-MM-DD` day.
    public var nextActionAtNotADay: Int
    /// As many rows as the server sends at most (`crm.ts:204`): accounts past it are not in the answer.
    public var reachedLimit: Bool

    public init(rows list: [WTJSON], readAt: Date) {
        self.readAt = readAt
        rows = list.count
        var objects: [[String: WTJSON]] = []
        for row in list { if case .object(let o) = row { objects.append(o) } }
        nonObjects = list.count - objects.count
        fields = Self.expected.map { name, expectation in
            var present = 0, null = 0, differing = 0
            var types: [String: Int] = [:]
            for o in objects {
                let v = o[name]
                if let v {
                    present += 1
                    if v == .null { null += 1 } else { types[Self.typeName(v), default: 0] += 1 }
                }
                if !expectation.fits(v) { differing += 1 }
            }
            return Field(name: name, expected: expectation, present: present, null: null, types: types, differing: differing)
        }
        let known = Set(Self.expected.map(\.0))
        unexpectedKeys = Set(objects.flatMap(\.keys)).subtracting(known).sorted()
        unknownStages = objects.count { o in
            if case .string(let s)? = o["stage"] { !WTAccountStage(rawValue: s).isKnown } else { false }
        }
        nextActionAtNotADay = objects.count { o in
            if case .string(let s)? = o["nextActionAt"] { !WorkTrackDates.isValid(s) } else { false }
        }
        reachedLimit = list.count >= MoneyBuilder.crmListLimit
    }

    static func typeName(_ v: WTJSON) -> String {
        switch v {
        case .null: "null"
        case .bool: "bool"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// Every way the answer differs from what Sales expects, as sentences with names and counts, never a value. Empty
    /// when it matches.
    public var differences: [String] {
        var out: [String] = []
        if nonObjects > 0 { out.append(LF("%ld rows are not JSON objects.", nonObjects)) }
        for f in fields where f.differing > 0 {
            out.append(LF("%1$@: %2$ld rows are not %3$@.", f.name, f.differing, f.expected.text))
        }
        if !unexpectedKeys.isEmpty { out.append(LF("Keys WorkTrack is not expected to send: %@.", unexpectedKeys.joined(separator: ", "))) }
        if unknownStages > 0 { out.append(LF("%ld rows have a stage WorkTrack does not define.", unknownStages)) }
        if nextActionAtNotADay > 0 { out.append(LF("%ld next-action dates are not a real day.", nextActionAtNotADay)) }
        if reachedLimit { out.append(LF("WorkTrack sent %ld accounts, the most it sends; accounts past that are not in the answer.", MoneyBuilder.crmListLimit)) }
        return out
    }
}
