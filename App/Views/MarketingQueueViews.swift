import LinumicCore
import SwiftUI

// MARK: - Marketing queue screen (صف بازاریابی)

/// Each brand's scheduled queue (its end, the clock change) as the obligations register holds it, with sources, beside
/// the brand's own ledger. Read-only; it never posts. A ledger's text is never read: the page shows when the ledger file
/// last changed, says when that is after a date was recorded, and Verify opens the ledger in its own app.
struct MarketingQueueView: View {
    @Environment(MarketingQueueModel.self) private var model
    @Environment(ObligationsModel.self) private var obligations
    @Environment(Router.self) private var router

    var body: some View {
        let brands = model.brands(obligations: obligations)
        let today = KeyDay(.now)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Read-only, and nothing is ever posted from here. The end of each brand's scheduled queue and the clock change are obligations, with their sources, so they reach the Desk and the reminders. The ledgers' text is never read: Verify opens a ledger in its own app, and you correct a date or record Done on the Obligations screen.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(brands) { brand in
                    MarketingBrandCard(brand: brand, today: today, checked: model.checkedAt != nil,
                                       verify: brand.ledger.map { ledger in { verify(ledger) } },
                                       open: { router.go(.obligations, request: .obligation($0)) })
                }
                Text("A ledger's date is its file's modification date, read without opening it. A ledger that changed after a date was recorded may have moved that date: verify it there.")
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                if !model.grantedFolders.isEmpty {
                    HStack {
                        Text(String(localized: "Read-only grants for Verify: \(model.grantedFolders.joined(separator: ", "))"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Remove access", role: .destructive) { model.revokeAll() }
                    }
                }
                #endif
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle(SidebarItem.marketingQueue.title)
        .toolbar {
            if MarketingQueueModel.readsLedgers {
                ToolbarItem {
                    Button { Task { await model.refresh() } } label: { Label("Check ledgers", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                        .help("Read the ledgers' modification dates again (never their text)")
                }
            }
        }
        .task { await model.refresh() }
        .alert("Not opened", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    private func verify(_ ledger: MarketingLedger) {
        #if os(macOS)
        model.verify(ledger)
        #endif
    }
}

private struct MarketingBrandCard: View {
    let brand: MarketingQueueBrand
    let today: KeyDay
    let checked: Bool
    let verify: (() -> Void)?
    let open: (String) -> Void

    var body: some View {
        StripeCard(tint: brand.changedSince.isEmpty ? .brandAccent : .statusWarn) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: brand.brand).font(.title3.weight(.semibold))
                Spacer()
                if let verify, MarketingQueueModel.readsLedgers {
                    Button(action: verify) { Label("Verify…", systemImage: "checkmark.magnifyingglass") }
                        .help("Open the ledger in its own app to check the dates there. The first time, grant its folder (read-only).")
                }
            }
            if let ledger = brand.ledger {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ledger.displayFile).font(.caption.monospaced()).textSelection(.enabled)
                    Text(fileText).font(.caption).foregroundStyle(.secondary)
                    Text(String(localized: "Named as the ledger in: \(ledger.source)")).font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
                }
            } else {
                Text("No ledger is recorded for this brand.").font(.caption).foregroundStyle(.secondary)
            }
            if brand.obligations.isEmpty {
                Text("No queue end is recorded for this brand.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(brand.obligations) { o in
                Divider()
                MarketingObligationRow(obligation: o, today: today, changed: brand.changedSince.contains(o.id), open: { open(o.id) })
            }
        }
    }

    private var fileText: String {
        guard MarketingQueueModel.readsLedgers else { return String(localized: "Ledger dates are read on the Mac only.") }
        switch brand.file {
        case .modified(let d)?: return String(localized: "Ledger last changed \(d.formatted(date: .abbreviated, time: .shortened))")
        case .missing?: return String(localized: "The ledger file was not found.")
        case .unknown(let why)?: return String(localized: "When the ledger last changed is unknown (\(why)).")
        case nil: return checked ? String(localized: "When the ledger last changed is unknown.") : String(localized: "Not checked yet.")
        }
    }
}

private struct MarketingObligationRow: View {
    let obligation: Obligation
    let today: KeyDay
    let changed: Bool
    let open: () -> Void

    var body: some View {
        let o = obligation
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ObligationsBriefRules.text(o, today: today)).fixedSize(horizontal: false, vertical: true)
                if changed {
                    ReleaseBadge(text: String(localized: "The ledger changed after this was recorded: verify"),
                                 symbol: "exclamationmark.triangle", color: .statusWarn)
                }
                if let consequence = o.displayConsequence {
                    Text("If missed: \(consequence)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let dueSource = o.dueSource {
                    Text("Date from: \(dueSource)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Text(String(localized: "Source: \(o.source), recorded \(o.recordedOn.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "unknown"))"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(4).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: open) { Label("Open", systemImage: "chevron.forward") }
                .buttonStyle(.borderless)
                .help("Open it on the Obligations screen, where its date is corrected or its Done recorded")
                .minTapTarget()
        }
    }
}
