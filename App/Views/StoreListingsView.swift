import LinumicCore
import SwiftUI

/// Every recorded listing on one store, across products. The App Store screen can refresh
/// public data. Review state and pending versions need App Store Connect / Play Console
/// credentials, which aren't connected.
struct StoreListingsView: View {
    let store: AppStore
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private struct Row: Identifiable {
        let productID: String
        let productName: String
        let listing: StoreListing
        var id: UUID { listing.id }
    }

    private var rows: [Row] {
        model.products.flatMap { p in p.listings(on: store).map { Row(productID: p.id, productName: p.name, listing: $0) } }
            .sorted { $0.productName < $1.productName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            Table(rows) {
                TableColumn("Product") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.productName).fontWeight(.medium)
                        // An iPhone shows only this column, so the essentials come along.
                        if compact {
                            Text(row.listing.appName ?? "—").font(.subheadline)
                            FitRow {
                                ReviewPhaseBadge(phase: row.listing.reviewPhase)
                                Text("Live: \(row.listing.productionVersion ?? String(localized: "unknown"))").font(.caption).foregroundStyle(.secondary)
                                if let s = row.listing.latestSubmittedVersion { Text("Submitted: \(s)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                TableColumn("App") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.listing.appName ?? "—")
                        Text(row.listing.appIdentifier ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Live") { Text($0.listing.productionVersion ?? String(localized: "Unknown")).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Submitted") { Text($0.listing.latestSubmittedVersion ?? "—") }
                TableColumn("Review") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        ReviewPhaseBadge(phase: row.listing.reviewPhase)
                        if let text = row.listing.reviewStatus {
                            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(row.listing.reviewStatus ?? "")
                }
                if store == .appStore {
                    TableColumn("Storefront") { Text($0.listing.storefront ?? "—") }
                        .width(min: 70, ideal: 90)
                }
                TableColumn("Evidence") { EvidenceButton(verification: $0.listing.verification) }
                    .width(min: 150, ideal: 170)
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) { router.open(productID: row.productID) }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No \(store.title) listings recorded", systemImage: "tray",
                                           description: Text("Add listings from a product's Stores tab."))
                }
            }
        }
        .navigationTitle(store.title)
        .toolbar {
            if model.hasConsoleCredentials(store) {
                Button {
                    Task { await model.refreshFromConsole(store) }
                } label: {
                    if model.syncingConsoles.contains(store) { ProgressView().controlSize(.small) } else { Label(store == .appStore ? "Refresh from App Store Connect" : "Refresh from Play Console", systemImage: "arrow.triangle.2.circlepath") }
                }
                .help("Read versions and review states with the read-only key in Settings → Integrations")
                .disabled(model.syncingConsoles.contains(store))
            }
            if store == .appStore {
                Button {
                    Task { await model.refreshAppStore() }
                } label: {
                    if model.isSyncingAppStore { ProgressView().controlSize(.small) } else { Label("Refresh Public Status", systemImage: "arrow.clockwise") }
                }
                .keyboardShortcut("r")
                .help("Read the public App Store lookup for each bundle ID (no credentials)")
                .disabled(model.isSyncingAppStore)
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sync = model.lastConsoleSync[store] {
                Text(verbatim: String(localized: "Console refresh \(sync.at.formatted(date: .omitted, time: .shortened)): \(sync.report.updated.count) updated")
                     + (sync.report.notInAccount.isEmpty ? "" : String(localized: ", not in this account: \(sync.report.notInAccount.joined(separator: ", "))"))
                     + (sync.report.failed.isEmpty ? "" : String(localized: ", failed: \(sync.report.failed.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; "))")))
                    .foregroundStyle(.primary)
            }
            if store == .appStore {
                Text(model.hasConsoleCredentials(.appStore)
                     ? "Versions and review states come from App Store Connect (read-only key). Refresh Public Status reads Apple's public lookup instead."
                     : "Live versions come from Apple's public lookup (US, then Afghanistan storefront). Submitted versions and review states come from the owner's App Store Connect screenshot. Add a read-only key in Settings → Integrations to read them directly.")
                if let sync = model.lastAppStoreSync {
                    Text(verbatim: String(localized: "Last refresh \(sync.at.formatted(date: .omitted, time: .shortened)): \(sync.report.updated.count) updated")
                         + (sync.report.notPublic.isEmpty ? "" : String(localized: ", not public yet: \(sync.report.notPublic.joined(separator: ", "))"))
                         + (sync.report.failed.isEmpty ? "" : String(localized: ", failed: \(sync.report.failed.keys.sorted().joined(separator: ", "))")))
                        .foregroundStyle(.primary)
                }
            } else {
                Text(model.hasConsoleCredentials(.googlePlay)
                     ? "Releases and review states come from the Google Play Developer API (read-only service account)."
                     : "Listings here were checked on their public pages and in the Play Console. Add a read-only service account in Settings → Integrations to read releases directly.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
