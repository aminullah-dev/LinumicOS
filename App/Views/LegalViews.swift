import LinumicCore
import SwiftUI

// MARK: - Legal & company screen (حقوقی و شرکت)

/// The company's status card, and on the Mac the legal folder: how many [TO FILL], [LAWYER] and [TO DECIDE] markers the
/// drafts hold, with the file and line of each, and the Asasnama files by name and date. Read-only. The drafts' text is
/// never shown, kept or sent; an Asasnama file is never opened.
struct LegalView: View {
    @Environment(LegalModel.self) private var model

    var body: some View {
        let company = model.company
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Read-only. The drafts' text is never shown, kept or sent: only each marker's file and line, and the Asasnama files by name and date.")
                    .font(.callout).foregroundStyle(.secondary)
                LegalCompanyCard(company: company)
                if LegalModel.readsFolder {
                    LegalMarkersCard(reading: model.reading, access: model.access, isReading: model.isReading)
                    LegalAsasnamaCard(reading: model.reading)
                    #if os(macOS)
                    LegalAccessCard()
                    #endif
                } else {
                    Label("The legal folder is read on the Mac only. The company card above is the same on every device.", systemImage: "desktopcomputer")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Nothing on this page is saved or sent to Linumic's cloud. On the Desk only counts appear, with ids that carry no file or folder name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle(SidebarItem.legal.title)
        .toolbar {
            if LegalModel.readsFolder {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Read now", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .disabled(model.isReading)
                        .help("Read the legal folder again: markers and Asasnama names and dates only")
                }
            }
        }
        .task { if model.reading == nil && LegalModel.readsFolder { await model.refresh() } }
        .alert("Not saved", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }
}

/// Registration, the seller of record per store, and the DSA trader status: each with its source, or Unknown.
private struct LegalCompanyCard: View {
    let company: CompanyStatus

    var body: some View {
        StripeCard(tint: .blue) {
            Label("Company", systemImage: "building.columns").font(.headline)
            fact(title: String(localized: "Registration"), company.registration)
            Divider()
            ForEach(company.sellers) { seller in
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent {
                        if seller.isKnown {
                            Text(verbatim: seller.sellers.joined(separator: ", ")).textSelection(.enabled)
                        } else {
                            UnknownLabel()
                        }
                    } label: {
                        Text("Seller on \(seller.store.title)").fontWeight(.medium)
                    }
                    Text(listingsText(seller)).font(.caption).foregroundStyle(.secondary)
                    if let at = seller.readAt {
                        ReleaseSourceLine(source: seller.source, at: at)
                    } else {
                        Text(String(localized: "Source: \(seller.source), recorded \(seller.recordedOn.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "unknown"))"))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            Divider()
            fact(title: String(localized: "EU DSA trader status"), company.dsa)
        }
    }

    private func listingsText(_ s: StoreSellerFact) -> String {
        s.withoutSeller > 0 ? String(localized: "\(s.listings) store listings, \(s.withoutSeller) without a seller")
                            : String(localized: "\(s.listings) store listings")
    }

    private func fact(title: String, _ f: CompanyFact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                if let value = f.value { Text(verbatim: L(value)).multilineTextAlignment(.trailing) } else { UnknownLabel() }
            } label: {
                Text(verbatim: title).fontWeight(.medium)
            }
            if let source = f.source {
                Text(String(localized: "Source: \(source), recorded \(f.recordedOn.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "unknown"))"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(4).textSelection(.enabled)
            } else if let why = f.unknownReason {
                Text(verbatim: L(why)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The markers: counts by kind (exact, or "at least" when a file was not read), then each file with its lines.
private struct LegalMarkersCard: View {
    let reading: LegalReading?
    let access: LegalAccessState?
    let isReading: Bool

    var body: some View {
        StripeCard(tint: .orange) {
            HStack {
                Label("Markers in the legal drafts", systemImage: "text.badge.checkmark").font(.headline)
                Spacer()
                if isReading { ProgressView().controlSize(.small) }
            }
            if let reading, reading.state == .read {
                FitRow(spacing: 8) {
                    ForEach(LegalMarkerKind.allCases) { kind in
                        let n = reading.count(kind)
                        ReleaseBadge(text: reading.isComplete ? "\(kind.label) \(n.formatted())" : String(localized: "\(kind.label) at least \(n.formatted())"),
                                     symbol: n == 0 ? "checkmark.circle" : "exclamationmark.circle", color: n == 0 ? .green : .orange)
                            .help(Text(verbatim: kind.title))
                    }
                }
                ForEach(reading.files.filter(\.isRead).filter { !$0.hits.isEmpty }) { file in
                    LegalFileRow(file: file)
                }
                ForEach(reading.unreadFiles) { file in
                    Label { Text(unreadText(file)).font(.caption) } icon: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    }
                }
                if reading.skipped > 0 {
                    Text("\(reading.skipped) entries left alone: links are never followed, and folders deeper than \(LegalReader.maxDepth) are not entered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: String(localized: "Same rule as: grep -rnoE '\(LegalMarkerScanner.pattern)' \(reading.folder) (text files only, Asasnama files left out)"))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                ReleaseSourceLine(source: String(localized: "\(reading.folder), file:line only"), at: reading.readAt)
            } else {
                Text(verbatim: LegalBrief.notReadText(access, reading: reading) ?? String(localized: "Not read yet.")).font(.callout)
                if let step = access?.ownerStep { Text(verbatim: step).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func unreadText(_ file: LegalFileResult) -> String {
        switch file.status {
        case .notText(let ext): String(localized: "\(file.path): not a text file (.\(ext)), so its markers are unknown.")
        case .unreadable(let why): String(localized: "\(file.path): not read (\(why)), so its markers are unknown.")
        case .read: file.path
        }
    }
}

/// One file: its path and, per kind, the lines (a line with two markers is named twice).
private struct LegalFileRow: View {
    let file: LegalFileResult
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(LegalMarkerKind.allCases) { kind in
                    let lines = file.hits.filter { $0.kind == kind }.map(\.line)
                    if !lines.isEmpty {
                        LabeledContent {
                            Text(verbatim: lines.map { $0.formatted() }.joined(separator: ", "))
                                .font(.caption.monospacedDigit()).textSelection(.enabled).multilineTextAlignment(.trailing)
                        } label: {
                            Text(verbatim: kind.label).font(.caption.monospaced())
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(verbatim: file.path).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text("\(file.hits.count) markers").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Asasnama files: name, folder and modification date. Never opened.
private struct LegalAsasnamaCard: View {
    let reading: LegalReading?

    var body: some View {
        StripeCard(tint: .purple) {
            Label("Asasnama (articles of association)", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text("Only the names and dates are read; the files are never opened. Whether there is a partner is your decision (roadmap §6, decision 1).")
                .font(.caption).foregroundStyle(.secondary)
            if let reading {
                if reading.asasnama.isEmpty {
                    Text("No Asasnama file in the folders read. Add the folder that holds them below.").font(.callout)
                } else {
                    ForEach(reading.asasnama) { f in
                        LabeledContent {
                            Text(f.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: f.name).textSelection(.enabled)
                                Text(verbatim: f.folder).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                ForEach(reading.searched.filter { $0.state != .read }) { s in
                    Text(verbatim: searchedText(s)).font(.caption).foregroundStyle(.orange)
                }
                ReleaseSourceLine(source: String(localized: "Names and modification dates"), at: reading.readAt)
            } else {
                UnknownLabel()
            }
        }
    }

    private func searchedText(_ s: LegalSearchedFolder) -> String {
        switch s.state {
        case .read: s.path
        case .notFound: String(localized: "\(s.path) was not found.")
        case .unreadable(let why): String(localized: "\(s.path) could not be listed (\(why)).")
        }
    }
}

#if os(macOS)
/// The sandbox check and the read-only grants.
private struct LegalAccessCard: View {
    @Environment(LegalModel.self) private var model

    var body: some View {
        StripeCard(tint: .gray) {
            Label("Access", systemImage: "lock.shield").font(.headline)
            LabeledContent {
                StatusBadge(text: stateText, color: model.access?.canRead == true ? .green : .orange)
            } label: {
                Text(verbatim: model.legalFolderDisplay).font(.callout.monospaced())
            }
            if let probe = model.probe {
                Text(verbatim: probeText(probe)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Grant…") { model.chooseLegalFolder() }
                    .disabled(model.access?.canRead == true)
                Button("Remove access", role: .destructive) { model.revokeAll() }
                    .disabled(LegalAccessStore.storedPaths(.legalFolder).isEmpty && model.asasnamaFolders.isEmpty)
            }
            Divider()
            Text("Folders searched for Asasnama files (names and dates only)").font(.callout.weight(.medium))
            ForEach(model.asasnamaFolders, id: \.self) { folder in
                HStack {
                    Text(verbatim: folder).font(.caption.monospaced())
                    if model.unresolvedAsasnama.contains(folder) {
                        StatusBadge(text: "Could not be resolved", color: .orange)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeAsasnamaFolder(folder) }.buttonStyle(.borderless)
                }
            }
            Button("Add folder…") { model.addAsasnamaFolder() }
            Text("Only ~/Documents/Linumic-Legal is accepted for the legal grant. An Asasnama folder can be any folder inside your home folder. The grants are read-only and kept on this Mac; Remove access forgets them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stateText: String {
        switch model.access {
        case nil: String(localized: "Not checked yet")
        case .readableWithoutGrant?: String(localized: "Readable without a grant")
        case .notGranted?: String(localized: "Not granted")
        case .granted?: String(localized: "Read-only access")
        case .unresolved?: String(localized: "Could not be resolved")
        case .denied?: String(localized: "Refused by macOS")
        case .moved?: String(localized: "Moved: grant again")
        case .notFound?: String(localized: "Not found")
        }
    }

    private func probeText(_ probe: LegalProbe) -> String {
        switch probe {
        case .readable: String(localized: "Sandbox check: the app can list the folder without a grant.")
        case .refused(let why): String(localized: "Sandbox check: listing the folder without a grant is refused (\(why)), so a one-time grant is needed.")
        case .notFound: String(localized: "Sandbox check: the folder is not there.")
        }
    }
}
#endif
