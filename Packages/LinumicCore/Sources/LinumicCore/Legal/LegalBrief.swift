import Foundation

// MARK: - Legal & company in the Daily Brief (and so on the Desk)

/// Legal & company as the App holds it.
public struct LegalInput: Sendable {
    /// The last reading of the legal folder on this device; nil when it was not read (yet, or ever on iPhone and iPad).
    public var reading: LegalReading?
    /// Where the legal folder's access stands; nil before the first check.
    public var access: LegalAccessState?
    /// Whether this device reads the legal folder at all (the Mac).
    public var readsFolder: Bool
    public var company: CompanyStatus

    public init(reading: LegalReading?, access: LegalAccessState?, readsFolder: Bool, company: CompanyStatus) {
        self.reading = reading
        self.access = access
        self.readsFolder = readsFolder
        self.company = company
    }
}

/// Which lines Legal & company puts in the Brief, with their ids. Ids never carry a file or folder name (a folder may
/// be named after a customer): a group's id is a hash, and nothing of the drafts' text is in a line.
public enum LegalBrief {
    static let markersPrefix = "legal.markers."
    public static let asasnamaID = "legal.asasnama"
    public static let registrationID = "legal.company.registration"

    /// The id of the line for one kind of marker in one group (first folder under the legal folder, or none).
    public static func markersID(_ kind: LegalMarkerKind, group: String?) -> String {
        markersPrefix + kind.rawValue + "." + (group.map { DeskHash.of("legal-group", $0) } ?? "root")
    }

    /// The gaps a line's part depends on: a marker or Asasnama line is known to be gone only once the legal folder was
    /// read (no "folder" gap); a company line, whenever the section was read.
    public static func readGapKeys(forLineID id: String) -> Set<String> {
        id.hasPrefix(markersPrefix) || id == asasnamaID ? ["folder"] : []
    }

    /// The sentence for one kind, exact or "at least" when some files were not read.
    static func text(_ kind: LegalMarkerKind, count: Int, complete: Bool) -> String {
        switch (kind, complete) {
        case (.toFill, true): LF("%1$d %2$@ markers to fill in the legal drafts", count, kind.label)
        case (.toFill, false): LF("At least %1$d %2$@ markers to fill in the legal drafts", count, kind.label)
        case (.lawyer, true): LF("%1$d %2$@ questions for the lawyer in the legal drafts", count, kind.label)
        case (.lawyer, false): LF("At least %1$d %2$@ questions for the lawyer in the legal drafts", count, kind.label)
        case (.toDecide, true): LF("%1$d %2$@ decisions of yours in the legal drafts", count, kind.label)
        case (.toDecide, false): LF("At least %1$d %2$@ decisions of yours in the legal drafts", count, kind.label)
        }
    }

    /// "Sample/Agreement.md: 5, 13, 13; Sample/Terms.md: 9" (made-up names), paths under the legal folder.
    static func places(_ reading: LegalReading, kind: LegalMarkerKind, group: String?) -> String {
        let prefix = reading.folder + "/"
        return reading.files.filter { $0.group == group }.sorted { $0.path < $1.path }.compactMap { file -> String? in
            let lines = file.hits.filter { $0.kind == kind }.map { String($0.line) }
            guard !lines.isEmpty else { return nil }
            let name = file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
            return "\(name): \(lines.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    /// The state of the legal folder in words, when it was not read.
    public static func notReadText(_ access: LegalAccessState?, reading: LegalReading?) -> String? {
        if let reading {
            switch reading.state {
            case .read: return nil
            case .notGranted: break
            case .notFound: return LF("~/%@ was not found, so the markers are unknown here.", LegalReader.folder)
            case .unreadable(let why): return LF("~/%1$@ could not be read (%2$@), so the markers are unknown here.", LegalReader.folder, why)
            }
        }
        switch access {
        case .granted?, .readableWithoutGrant?:
            return reading == nil ? L("The legal folder has not been read yet, so the markers are unknown here.") : nil
        case .notFound?: return LF("~/%@ was not found, so the markers are unknown here.", LegalReader.folder)
        case .unresolved?: return L("The stored grant of the legal folder could not be resolved, so the markers are unknown here.")
        case .denied(let why)?: return LF("macOS refused the legal folder (%@), so the markers are unknown here.", why)
        case .moved?: return L("The granted legal folder was moved or renamed; grant it again. Until then the markers are unknown here.")
        case .notGranted?, nil:
            return LF("~/%@ is not granted, so the markers are unknown here, not zero.", LegalReader.folder)
        }
    }
}

extension DailyBriefBuilder {
    static func legal(_ input: BriefInput) -> BriefSection {
        let source = L("Legal folder (read-only, markers and Asasnama names only) and the store listings")
        guard let l = input.legal else {
            return BriefSection(kind: .legal, state: .neverRead(L("Legal & company has not been collected on this device yet.")),
                                readAt: nil, source: source)
        }
        let calendar = KeyDay.calendar
        var lines: [BriefLine] = []
        var gaps: [BriefGap] = []
        let company = l.company

        // The company: registration (from the records), then what is unknown.
        if let value = company.registration.value, let from = company.registration.source {
            lines.append(BriefLine(id: LegalBrief.registrationID, kind: .legal, severity: .info, text: L(value),
                                   detail: L("When to register, and the tax clause of the WorkTrack contract, are yours to decide with a lawyer (roadmap §6, decision 2)."),
                                   source: from, readAt: company.registration.recordedOn?.start(calendar: calendar), destination: .legal))
        } else {
            gaps.append(BriefGap(key: "registration", text: L("Whether the company is registered is unknown: no source records it.")))
        }
        for seller in company.sellers where !seller.isKnown {
            gaps.append(BriefGap(key: "seller.\(seller.store.rawValue)",
                                 text: seller.listings == 0 ? LF("%@: no store listing is recorded, so the seller is unknown.", seller.store.title)
                                                            : LF("%@: no store listing names the seller, so it is unknown.", seller.store.title)))
        }
        if !company.dsa.isKnown {
            gaps.append(BriefGap(key: "dsa", text: L("EU DSA trader status in the stores: Unknown. No source records it.")))
        }

        // The legal folder.
        if !l.readsFolder {
            gaps.append(BriefGap(key: "folder", text: L("The legal folder is read on the Mac only."), isDeskItem: false))
        } else if let why = LegalBrief.notReadText(l.access, reading: l.reading) {
            gaps.append(BriefGap(key: "folder", text: why))
        }
        if let r = l.reading, r.state == .read {
            for kind in LegalMarkerKind.allCases {
                for group in r.groups(kind) {
                    let count = r.count(kind, group: group)
                    lines.append(BriefLine(id: LegalBrief.markersID(kind, group: group), kind: .legal, severity: .normal,
                                           text: LegalBrief.text(kind, count: count, complete: r.isComplete),
                                           detail: LegalBrief.places(r, kind: kind, group: group),
                                           source: LF("~/%@ (file:line only; the text is never shown or stored)", LegalReader.folder),
                                           readAt: r.readAt, destination: .legal, product: group,
                                           factKey: BriefLine.countBucket(count)))
                }
            }
            let unread = r.unreadFiles.count
            if unread > 0 || r.skipped > 0 {
                gaps.append(BriefGap(key: "files",
                                     text: LF("%1$d files in the legal folder were not read (not text, or unreadable) and %2$d entries were left alone (links, or too deep), so the counts are at least.", unread, r.skipped),
                                     isCaveat: true))
            }
        }
        if let r = l.reading {
            if !r.asasnama.isEmpty {
                lines.append(BriefLine(id: LegalBrief.asasnamaID, kind: .legal, severity: .normal,
                                       text: LF("%d Asasnama files: whether there is a partner is your decision", r.asasnama.count),
                                       detail: L("Names and dates only; the files are never opened (roadmap §6, decision 1)."),
                                       source: LF("Names and modification dates in %@", r.searched.filter { $0.state == .read }.map(\.path).joined(separator: ", ")),
                                       readAt: r.readAt, destination: .legal,
                                       factKey: DeskHash.of(r.asasnama.map { "\($0.id)|\($0.modifiedAt.timeIntervalSince1970)" })))
            } else if r.searched.contains(where: { $0.state == .read }) {
                gaps.append(BriefGap(key: "asasnama", text: L("No Asasnama file in the folders read, so their names and dates are unknown here. Add the folder that holds them in Legal & company.")))
            }
        }
        let readAt = [l.reading?.readAt, company.sellers.compactMap(\.readAt).max()].compactMap { $0 }.max()
        return finish(.legal, lines: lines, readAt: readAt, source: source, gaps: gaps)
    }
}
