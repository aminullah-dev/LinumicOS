import LinumicCore
import SwiftUI

/// Every recorded listing on one store, across products. The App Store screen can refresh
/// public data. Review state and pending versions need App Store Connect / Play Console
/// credentials, which aren't connected.
struct StoreListingsView: View {
    let store: AppStore
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router

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
                TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
                TableColumn("App") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.listing.appName ?? "—")
                        Text(row.listing.appIdentifier ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Live") { Text($0.listing.productionVersion ?? "Unknown").monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Submitted") { Text($0.listing.latestSubmittedVersion ?? "—") }
                TableColumn("Review") { Text($0.listing.reviewStatus ?? "—").lineLimit(2).help($0.listing.reviewStatus ?? "") }
                TableColumn("Storefront") { Text($0.listing.storefront ?? "—") }
                    .width(min: 70, ideal: 90)
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
            if store == .appStore {
                Text("Live versions come from Apple's public lookup (US, then Afghanistan storefront). Submitted versions and review states come from the owner's App Store Connect screenshot. App Store Connect itself isn't connected.")
                if let sync = model.lastAppStoreSync {
                    Text("Last refresh \(sync.at.formatted(date: .omitted, time: .shortened)): \(sync.report.updated.count) updated"
                         + (sync.report.notPublic.isEmpty ? "" : ", not public yet: \(sync.report.notPublic.joined(separator: ", "))")
                         + (sync.report.failed.isEmpty ? "" : ", failed: \(sync.report.failed.keys.sorted().joined(separator: ", "))"))
                        .foregroundStyle(.primary)
                }
            } else {
                Text("Google Play has no public API. Listings here were checked on their public pages. Production versions need the Google Play Developer API, which needs a service account that isn't connected.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
