import CryptoKit
import Foundation

/// CSV in and out of the ledger.
///
/// Import reads the Python tool's `~/.linumic/licenses/issued.csv`
/// (`id,product,customer,machine,issued,expires,edition`) and this app's own export. That file
/// doesn't record the key or the features, so they stay unknown unless the matching `.lnmlic`
/// files are imported too (`attach(keys:to:)`), which are verified against the production public key.
public enum LicenceCSV {
    public struct ImportResult: Sendable, Equatable {
        public var added: [LicenceRecord] = []
        /// Licence ids already in the ledger (left as they are).
        public var skipped: [String] = []
        /// Line number (1 = header) and reason.
        public var rejected: [Rejection] = []

        public struct Rejection: Sendable, Equatable {
            public let line: Int
            public let reason: String
        }
    }

    public static let exportColumns = ["licence_id", "product", "customer", "machine", "issued", "expires", "edition",
                                       "features", "status", "renewed_from", "notes", "created_by", "created_at", "key_text"]

    // MARK: Import

    public static func importLedger(_ text: String, existing: [LicenceRecord], createdBy: String = "issued.csv import",
                                    now: Date = .now) -> ImportResult {
        var result = ImportResult()
        let rows = parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return result }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let iID = col("id", "licence_id", "license_id"), let iProduct = col("product"), let iCustomer = col("customer"),
              let iMachine = col("machine"), let iIssued = col("issued") else {
            result.rejected.append(.init(line: 1, reason: L("The header doesn't look like issued.csv (id, product, customer, machine, issued, expires, edition).")))
            return result
        }
        let iExpires = col("expires"), iEdition = col("edition"), iStatus = col("status"), iRenewed = col("renewed_from")
        let iNotes = col("notes"), iFeatures = col("features"), iKey = col("key_text")
        var known = Set(existing.map(\.licenceID))

        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func value(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            guard let licenceID = value(iID) else { result.rejected.append(.init(line: line, reason: L("No licence id."))); continue }
            guard let product = value(iProduct).flatMap(LicenceProduct.init(rawValue:)) else {
                result.rejected.append(.init(line: line, reason: LF("%@: unknown product.", licenceID))); continue
            }
            guard let customer = value(iCustomer) else { result.rejected.append(.init(line: line, reason: LF("%@: no customer.", licenceID))); continue }
            guard let machine = value(iMachine).flatMap(MachineCode.normalize) else {
                result.rejected.append(.init(line: line, reason: LF("%@: invalid machine code.", licenceID))); continue
            }
            guard let issued = value(iIssued), LicenceDate.isValid(issued) else {
                result.rejected.append(.init(line: line, reason: LF("%@: invalid issue date.", licenceID))); continue
            }
            let expires = value(iExpires)
            if let expires, !LicenceDate.isValid(expires) {
                result.rejected.append(.init(line: line, reason: LF("%@: invalid expiry date.", licenceID))); continue
            }
            if known.contains(licenceID) { result.skipped.append(licenceID); continue }
            let features = value(iFeatures).map { $0.split(separator: " ").map(String.init) }
            var keyText = value(iKey)
            if let k = keyText, (try? LicenceKey.verify(k, product: product)) == nil { keyText = nil }
            let record = LicenceRecord(product: product, licenceID: licenceID, customer: customer, machine: machine,
                                       issued: issued, expires: expires, edition: value(iEdition) ?? "standard",
                                       features: features, keyText: keyText,
                                       status: value(iStatus).flatMap(LicenceStatus.init(rawValue:)) ?? .active,
                                       renewedFrom: value(iRenewed), notes: value(iNotes) ?? "",
                                       createdBy: createdBy, createdAt: now)
            known.insert(licenceID)
            result.added.append(record)
        }
        return result
    }

    /// Result of attaching `.lnmlic` files.
    public struct KeyAttachResult: Sendable, Equatable {
        public var records: [LicenceRecord]
        /// Licence ids whose key was filled in.
        public var attached: [String] = []
        /// Verified keys with no ledger row; they were added from their payload.
        public var addedFromKey: [String] = []
        /// File name and reason.
        public var rejected: [String] = []
    }

    /// Fills in `keyText` (and features) from `.lnmlic` contents. Every key is verified with the
    /// embedded production public key first; a key that doesn't match its ledger row is refused.
    public static func attach(keys files: [(name: String, text: String)], to records: [LicenceRecord],
                              createdBy: String = "lnmlic import", now: Date = .now,
                              publicKey: (LicenceProduct) -> P256.Signing.PublicKey = { $0.productionPublicKey }) -> KeyAttachResult {
        var result = KeyAttachResult(records: records)
        for file in files {
            let compact = String(file.text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            guard let unverified = LicenceKey.unverifiedPayload(compact), let product = LicenceProduct(rawValue: unverified.product) else {
                result.rejected.append("\(file.name): " + L("not an LNM1 licence key.")); continue
            }
            let payload: LicencePayload
            do { payload = try LicenceKey.verify(compact, product: product, publicKey: publicKey(product)) } catch {
                result.rejected.append("\(file.name): \(error.localizedDescription)"); continue
            }
            if let i = result.records.firstIndex(where: { $0.licenceID == payload.licenceID }) {
                var r = result.records[i]
                let matches = r.product == product && r.customer == payload.customer && r.machine == payload.machine
                    && r.issued == payload.issued && r.expires == payload.expires && r.edition == payload.edition
                guard matches else {
                    result.rejected.append("\(file.name): " + LF("the key doesn't match ledger row %@.", payload.licenceID)); continue
                }
                if r.keyText == nil || r.features == nil {
                    r.keyText = r.keyText ?? compact
                    r.features = r.features ?? payload.features
                    r.updatedAt = now
                    result.records[i] = r
                    result.attached.append(payload.licenceID)
                }
            } else {
                result.records.append(LicenceRecord(product: product, licenceID: payload.licenceID, customer: payload.customer,
                                                    machine: payload.machine, issued: payload.issued, expires: payload.expires,
                                                    edition: payload.edition, features: payload.features, keyText: compact,
                                                    createdBy: createdBy, createdAt: now))
                result.addedFromKey.append(payload.licenceID)
            }
        }
        result.records = LicenceLedger.sorted(result.records)
        return result
    }

    // MARK: Export

    public static func export(_ records: [LicenceRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [exportColumns.joined(separator: ",")]
        for r in LicenceLedger.sorted(records) {
            let fields: [String] = [
                r.licenceID, r.product.rawValue, r.customer, r.machine, r.issued, r.expires ?? "", r.edition,
                r.features?.joined(separator: " ") ?? "", r.status.rawValue, r.renewedFrom ?? "", r.notes, r.createdBy,
                iso.string(from: r.createdAt), r.keyText ?? "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 parser (quoted fields, doubled quotes, CRLF or LF), as Python's csv module writes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        return rows
    }
}
