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

    private var rows: [Product] {
        let filtered = search.isEmpty ? model.products : model.products.filter {
            $0.name.localizedStandardContains(search)
                || ($0.category ?? "").localizedStandardContains(search)
                || $0.repositories.contains { $0.name.localizedStandardContains(search) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in
                Text(p.name).fontWeight(.medium)
            }
            TableColumn("Status", value: \.status.rawValue) { p in
                StatusBadge(text: p.status.title, color: p.status.color)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Platforms") { p in
                Text(p.platforms.isEmpty ? "—" : p.platforms.map(\.title).joined(separator: ", "))
                    .foregroundStyle(p.platforms.isEmpty ? .secondary : .primary)
            }
            TableColumn("Current") { p in Text(p.currentVersion ?? "—").monospacedDigit() }
                .width(min: 60, ideal: 70)
            TableColumn("Next") { p in Text(p.nextVersion ?? "—").monospacedDigit() }
                .width(min: 60, ideal: 70)
            TableColumn("Repos") { p in Text("\(p.repositories.count)").monospacedDigit() }
                .width(50)
            TableColumn("Open issues") { p in
                Text("\(p.openIssues.count)")
                    .monospacedDigit()
                    .foregroundStyle(p.openCriticalIssues.isEmpty ? Color.primary : Color.red)
            }
            .width(min: 70, ideal: 80)
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
            Text("This removes the product and all of its records from the Command Center. It does not touch any repository or store.")
        }
    }
}

struct QuickOpenView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [Product] {
        let all = model.products.sorted { $0.name < $1.name }
        return query.isEmpty ? all : all.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Go to product…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { if let first = matches.first { open(first) } }
            Divider()
            List(matches) { product in
                Button { open(product) } label: {
                    HStack {
                        Text(product.name)
                        Spacer()
                        StatusBadge(text: product.status.title, color: product.status.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 480, height: 360)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func open(_ product: Product) {
        router.open(productID: product.id)
        dismiss()
    }
}
