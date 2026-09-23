import LinumicCore
import SwiftUI

/// A child record paired with the product it belongs to, for cross-product tables.
struct Owned<Record: Identifiable>: Identifiable where Record.ID == UUID {
    let productID: String
    let productName: String
    let record: Record
    var id: UUID { record.id }
}

private extension InventoryModel {
    func owned<R: Identifiable>(_ keyPath: KeyPath<Product, [R]>) -> [Owned<R>] where R.ID == UUID {
        products.flatMap { p in p[keyPath: keyPath].map { Owned(productID: p.id, productName: p.name, record: $0) } }
    }
}

/// Shared chrome for the cross-product tables: search, an empty state, and double-click to open the product.
private struct AggregateTable<Record: Identifiable, Columns: TableColumnContent>: View
where Record.ID == UUID, Columns.TableRowValue == Owned<Record> {
    let title: String
    let rows: [Owned<Record>]
    let emptyText: String
    let matches: (Owned<Record>, String) -> Bool
    @TableColumnBuilder<Owned<Record>, Never> let columns: () -> Columns
    @Environment(Router.self) private var router
    @State private var search = ""

    var body: some View {
        let filtered = search.isEmpty ? rows : rows.filter { matches($0, search) }
        Table(filtered, columns: columns)
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    router.open(productID: row.productID)
                }
            }
            .searchable(text: $search)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(title, systemImage: "tray", description: Text(emptyText))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle(title)
    }
}

struct AllReleasesView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        AggregateTable(
            title: "Releases",
            rows: model.owned(\.releases).sorted { ($0.record.releaseDate ?? .distantFuture) > ($1.record.releaseDate ?? .distantFuture) },
            emptyText: "No releases recorded. Add them from a product's Releases tab.",
            matches: { $0.productName.localizedStandardContains($1) || $0.record.version.localizedStandardContains($1) }
        ) {
            TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
            TableColumn("Version") { Text($0.record.version).monospacedDigit() }
            TableColumn("Build") { Text($0.record.buildNumber ?? "—").monospacedDigit() }
            TableColumn("Platform") { Text($0.record.platform.title) }
            TableColumn("Environment") { Text($0.record.environment.title) }
            TableColumn("Stage") { StatusBadge(text: $0.record.stage.title, color: $0.record.stage.color) }
            TableColumn("RC") { Text($0.record.isReleaseCandidate ? "Yes" : "") }.width(30)
            TableColumn("Date") { Text($0.record.releaseDate?.shortDate ?? "—") }
        }
    }
}

struct AllRoadmapView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        AggregateTable(
            title: "Roadmap",
            rows: model.owned(\.roadmap),
            emptyText: "No roadmap items recorded. Add them from a product's Roadmap tab.",
            matches: { $0.productName.localizedStandardContains($1) || $0.record.title.localizedStandardContains($1) }
        ) {
            TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
            TableColumn("Item") { Text($0.record.title) }
            TableColumn("Status") { StatusBadge(text: $0.record.status.title, color: $0.record.status.color) }
            TableColumn("Target version") { Text($0.record.targetVersion ?? "—") }
            TableColumn("Target date") { Text($0.record.targetDate?.shortDate ?? "—") }
        }
    }
}

struct AllIssuesView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        AggregateTable(
            title: "Issues",
            rows: model.owned(\.issues).sorted { ($0.record.isOpen ? 1 : 0, $0.record.severity) > ($1.record.isOpen ? 1 : 0, $1.record.severity) },
            emptyText: "No issues recorded. GitHub issue sync is planned for Phase 2.",
            matches: { $0.productName.localizedStandardContains($1) || $0.record.title.localizedStandardContains($1) }
        ) {
            TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
            TableColumn("Issue") { Text($0.record.title) }
            TableColumn("Severity") { StatusBadge(text: $0.record.severity.title, color: $0.record.severity.color) }
            TableColumn("State") { Text($0.record.isOpen ? "Open" : "Closed") }
        }
    }
}

struct AllRepositoriesView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        AggregateTable(
            title: "Repositories",
            rows: model.owned(\.repositories),
            emptyText: "No repositories recorded.",
            matches: { $0.productName.localizedStandardContains($1) || $0.record.name.localizedStandardContains($1) }
        ) {
            TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
            TableColumn("Repository") { Text($0.record.gitHubSlug ?? $0.record.name).textSelection(.enabled) }
            TableColumn("Default branch") { Text($0.record.defaultBranch ?? "—") }
            TableColumn("Last commit / PRs / CI") { _ in
                Text("Not connected").foregroundStyle(.secondary)
            }
        }
    }
}

struct AllDeploymentsView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        AggregateTable(
            title: "Deployments",
            rows: model.owned(\.deployments),
            emptyText: "No deployments recorded. Add them from a product's Deployments tab.",
            matches: { $0.productName.localizedStandardContains($1) || $0.record.target.localizedStandardContains($1) }
        ) {
            TableColumn("Product") { Text($0.productName).fontWeight(.medium) }
            TableColumn("Target") { Text($0.record.target) }
            TableColumn("Environment") { Text($0.record.environment.title) }
            TableColumn("Status") { StatusBadge(text: $0.record.status.title, color: $0.record.status.color) }
            TableColumn("Version") { Text($0.record.version ?? "—") }
            TableColumn("Deployed") { Text($0.record.deployedAt?.shortDate ?? "—") }
        }
    }
}
