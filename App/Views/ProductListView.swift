import LinumicCore
import SwiftUI

struct ProductsRootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.productPath) {
            ProductListView()
                .navigationDestination(for: String.self) { id in
                    ProductDetailView(productID: id)
                }
        }
    }
}

struct ProductListView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @State private var search = ""
    @State private var selection: Set<Product.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Product.name)]
    @State private var pendingDelete: Product?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var rows: [Product] {
        let filtered = search.isEmpty ? model.products : model.products.filter {
            $0.name.localizedStandardContains(search)
                || ($0.category.value ?? "").localizedStandardContains(search)
                || ($0.alsoKnownAs.value ?? []).contains { $0.localizedStandardContains(search) }
                || $0.repositories.contains { $0.name.localizedStandardContains(search) }
        }
        // Sidelined products always sink to the bottom. Otherwise the chosen sort order applies.
        return filtered.sorted(using: sortOrder).sorted { ($0.priority.value == .sidelined ? 1 : 0) < ($1.priority.value == .sidelined ? 1 : 0) }
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).fontWeight(.medium)
                    // Always two lines, so every row has the same height.
                    Text(verbatim: p.alsoKnownAs.value.map { $0.joined(separator: " · ") } ?? " ")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(p.alsoKnownAs.value?.isEmpty ?? true)
                    // An iPhone shows only this column, so the key badges come along.
                    if compact {
                        FitRow {
                            VerificationBadge(status: p.overallVerification, compact: true)
                            if let st = p.status.value { StatusBadge(text: st.title, color: st.color) }
                            let n = p.needsConfirmation.count
                            if n > 0 { Label("\(n)", systemImage: "person.badge.clock").font(.caption).foregroundStyle(.orange).accessibilityLabel("\(n) items need your confirmation") }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Verification", value: \.overallVerification.rawValue) { p in
                VerificationBadge(status: p.overallVerification)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Needs you") { p in
                let n = p.needsConfirmation.count
                Text(n == 0 ? "—" : n.formatted()).monospacedDigit().fontWeight(n == 0 ? .regular : .semibold)
                    .accessibilityLabel(n == 0 ? "Nothing to confirm" : "\(n) items need your confirmation")
            }
            .width(min: 60, ideal: 70)
            TableColumn("Priority") { p in
                if let pr = p.priority.value {
                    StatusBadge(text: pr.title, color: pr.color)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("Status") { p in
                if let s = p.status.value {
                    HStack(spacing: 4) {
                        StatusBadge(text: s.title, color: s.color)
                        if p.status.status != .verified {
                            Image(systemName: p.status.status.symbol).foregroundStyle(p.status.status.color)
                                .help("Status is \(p.status.status.title)")
                                .accessibilityLabel("Status verification: \(p.status.status.title)")
                        }
                    }
                } else {
                    Text("Unknown").foregroundStyle(.secondary).italic()
                }
            }
            .width(min: 100, ideal: 130)
            TableColumn("Platforms") { p in
                let platforms = p.evidencedPlatforms
                Text(platforms.isEmpty ? String(localized: "Unknown") : platforms.map(\.title).joined(separator: String(localized: ", ")))
                    .foregroundStyle(platforms.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            TableColumn("Repos") { p in Text("\(p.repositories.count)").monospacedDigit() }
                .width(45)
            TableColumn("Stores") { p in
                HStack(spacing: 4) {
                    if !p.listings(on: .appStore).isEmpty { Image(systemName: "applelogo").help("App Store") }
                    if !p.listings(on: .googlePlay).isEmpty { Image(systemName: "play.rectangle").help("Google Play") }
                    if p.storeListings.isEmpty { Text("—").foregroundStyle(.secondary) }
                }
            }
            .width(55)
            TableColumn("Last verified") { p in
                Text(p.lastVerifiedAt?.shortDate ?? String(localized: "Never")).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
        }
        .contextMenu(forSelectionType: Product.ID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Open") { router.productPath = [id] }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = model.product(id: id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { router.productPath = [id] }
        }
        .searchable(text: $search, prompt: "Search products")
        .overlay {
            if model.isLoaded && model.products.isEmpty {
                ContentUnavailableView("No products", systemImage: "shippingbox", description: Text("Press ⌘N to add a product."))
            } else if !search.isEmpty && rows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Products")
        .toolbar {
            Button { router.isNewProductPresented = true } label: { Label("New Product", systemImage: "plus") }
                .help("New Product (⌘N)")
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { product in
            Button("Delete", role: .destructive) { model.delete(product.id) }
        } message: { _ in
            Text("This removes the product and all of its records from Linumic OS. It does not touch any repository or store.")
        }
    }
}
