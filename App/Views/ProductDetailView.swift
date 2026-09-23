import LinumicCore
import SwiftUI

enum ProductTab: String, CaseIterable, Identifiable {
    case overview = "Overview", releases = "Releases", repositories = "Repos", roadmap = "Roadmap",
         issues = "Issues", deployments = "Deploys", stores = "Stores", links = "Links"
    var id: String { rawValue }
}

/// Which record editor sheet is open. The ID is `nil` when adding a new record.
enum RecordEditing: Identifiable {
    case product
    case release(UUID?), repository(UUID?), roadmap(UUID?), issue(UUID?), deployment(UUID?)
    case appStore, googlePlay

    var id: String {
        switch self {
        case .product: "product"
        case .release(let id): "release-\(id?.uuidString ?? "new")"
        case .repository(let id): "repo-\(id?.uuidString ?? "new")"
        case .roadmap(let id): "roadmap-\(id?.uuidString ?? "new")"
        case .issue(let id): "issue-\(id?.uuidString ?? "new")"
        case .deployment(let id): "deployment-\(id?.uuidString ?? "new")"
        case .appStore: "appStore"
        case .googlePlay: "googlePlay"
        }
    }
}

struct ProductDetailView: View {
    let productID: String
    @Environment(InventoryModel.self) private var model
    @State private var tab: ProductTab = .overview
    @State private var editing: RecordEditing?

    var body: some View {
        if let product = model.product(id: productID) {
            VStack(alignment: .leading, spacing: 0) {
                header(product)
                Picker("Section", selection: $tab) {
                    ForEach(ProductTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                Divider()
                ScrollView {
                    tabContent(product)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(product.name)
            .toolbar {
                Button { editing = .product } label: { Label("Edit", systemImage: "pencil") }
                    .keyboardShortcut("e")
                    .help("Edit product (⌘E)")
            }
            .sheet(item: $editing) { editor(for: $0, product: product) }
        } else {
            ContentUnavailableView("Product not found", systemImage: "questionmark.folder")
        }
    }

    private func header(_ p: Product) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name).font(.largeTitle.weight(.semibold))
                StatusBadge(text: p.status.title, color: p.status.color)
            }
            Text("Source: \(p.provenance.source) · recorded \(p.provenance.recordedAt.shortDate)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(20)
    }

    @ViewBuilder
    private func tabContent(_ p: Product) -> some View {
        switch tab {
        case .overview: OverviewTab(product: p)
        case .releases:
            RecordSection(title: "Releases", items: p.releases.sorted { ($0.releaseDate ?? .distantFuture) > ($1.releaseDate ?? .distantFuture) },
                          empty: "No releases recorded.", onAdd: { editing = .release(nil) },
                          onEdit: { editing = .release($0.id) },
                          onDelete: { r in model.update(p.id) { $0.releases.removeAll { $0.id == r.id } } }) { r in
                HStack {
                    Text(r.version).monospacedDigit().bold()
                    if let build = r.buildNumber { Text("(\(build))").foregroundStyle(.secondary) }
                    Text(r.platform.title)
                    Text(r.environment.title).foregroundStyle(.secondary)
                    if r.isReleaseCandidate { StatusBadge(text: "RC", color: .indigo) }
                    Spacer()
                    if let d = r.releaseDate { Text(d.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: r.stage.title, color: r.stage.color)
                }
            }
        case .repositories:
            RecordSection(title: "Repositories", items: p.repositories, empty: "No repositories recorded.",
                          onAdd: { editing = .repository(nil) }, onEdit: { editing = .repository($0.id) },
                          onDelete: { r in model.update(p.id) { $0.repositories.removeAll { $0.id == r.id } } }) { r in
                HStack {
                    Image(systemName: "externaldrive.connected.to.line.below")
                    Text(r.name).bold()
                    if let url = r.url { Link(url.absoluteString, destination: url).font(.callout) }
                    Spacer()
                    Text(r.defaultBranch ?? "branch unknown").foregroundStyle(.secondary)
                }
            }
        case .roadmap:
            RecordSection(title: "Roadmap", items: p.roadmap, empty: "No roadmap items recorded.",
                          onAdd: { editing = .roadmap(nil) }, onEdit: { editing = .roadmap($0.id) },
                          onDelete: { r in model.update(p.id) { $0.roadmap.removeAll { $0.id == r.id } } }) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.title).bold()
                        if !r.detail.isEmpty { Text(r.detail).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let v = r.targetVersion { Text(v).monospacedDigit().foregroundStyle(.secondary) }
                    if let d = r.targetDate { Text(d.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: r.status.title, color: r.status.color)
                }
            }
        case .issues:
            RecordSection(title: "Issues", items: p.issues.sorted { ($0.isOpen ? 1 : 0, $0.severity) > ($1.isOpen ? 1 : 0, $1.severity) },
                          empty: "No issues recorded. GitHub issue sync is planned.",
                          onAdd: { editing = .issue(nil) }, onEdit: { editing = .issue($0.id) },
                          onDelete: { r in model.update(p.id) { $0.issues.removeAll { $0.id == r.id } } }) { i in
                HStack {
                    Image(systemName: i.isOpen ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(i.isOpen ? Color.primary : Color.green)
                    Text(i.title).strikethrough(!i.isOpen)
                    Spacer()
                    StatusBadge(text: i.severity.title, color: i.severity.color)
                }
            }
        case .deployments:
            RecordSection(title: "Deployments", items: p.deployments, empty: "No deployments recorded.",
                          onAdd: { editing = .deployment(nil) }, onEdit: { editing = .deployment($0.id) },
                          onDelete: { r in model.update(p.id) { $0.deployments.removeAll { $0.id == r.id } } }) { d in
                HStack {
                    Text(d.target).bold()
                    Text(d.environment.title).foregroundStyle(.secondary)
                    Spacer()
                    if let v = d.version { Text(v).monospacedDigit() }
                    if let at = d.deployedAt { Text(at.shortDate).foregroundStyle(.secondary) }
                    StatusBadge(text: d.status.title, color: d.status.color)
                }
            }
        case .stores:
            VStack(alignment: .leading, spacing: 16) {
                StoreBox(title: "App Store", listing: p.appStore) { editing = .appStore }
                StoreBox(title: "Google Play", listing: p.googlePlay) { editing = .googlePlay }
                Text("Values here are entered by hand. Live store status needs the App Store Connect / Google Play integrations, which are not connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .links:
            LinksTab(product: p)
        }
    }

    @ViewBuilder
    private func editor(for editing: RecordEditing, product p: Product) -> some View {
        switch editing {
        case .product:
            ProductEditor(product: p) { model.upsert($0) }
        case .release(let id):
            ReleaseEditor(release: p.releases.first { $0.id == id }, defaultPlatform: p.platforms.first ?? .macOS) { r in
                model.update(p.id) { $0.releases.upsert(r) }
            }
        case .repository(let id):
            RepositoryEditor(repository: p.repositories.first { $0.id == id }) { r in
                model.update(p.id) { $0.repositories.upsert(r) }
            }
        case .roadmap(let id):
            RoadmapEditor(item: p.roadmap.first { $0.id == id }) { r in
                model.update(p.id) { $0.roadmap.upsert(r) }
            }
        case .issue(let id):
            IssueEditor(issue: p.issues.first { $0.id == id }) { r in
                model.update(p.id) { $0.issues.upsert(r) }
            }
        case .deployment(let id):
            DeploymentEditor(deployment: p.deployments.first { $0.id == id }) { r in
                model.update(p.id) { $0.deployments.upsert(r) }
            }
        case .appStore:
            StoreListingEditor(title: "App Store", listing: p.appStore) { l in model.update(p.id) { $0.appStore = l } }
        case .googlePlay:
            StoreListingEditor(title: "Google Play", listing: p.googlePlay) { l in model.update(p.id) { $0.googlePlay = l } }
        }
    }
}

extension Array where Element: Identifiable {
    mutating func upsert(_ element: Element) {
        if let i = firstIndex(where: { $0.id == element.id }) { self[i] = element } else { append(element) }
    }
}

private struct OverviewTab: View {
    let product: Product

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            row("Description") { ValueOrUnknown(value: product.summary) }
            row("Category") { ValueOrUnknown(value: product.category) }
            row("Platforms") {
                ValueOrUnknown(value: product.platforms.isEmpty ? nil : product.platforms.map(\.title).joined(separator: ", "))
            }
            row("Current version") { ValueOrUnknown(value: product.currentVersion) }
            row("Next version") { ValueOrUnknown(value: product.nextVersion) }
            row("Backend") { ValueOrUnknown(value: product.backend) }
            row("Website") {
                if let url = product.website { Link(url.absoluteString, destination: url) } else { UnknownLabel() }
            }
            row("Notes") {
                Text(product.notes.isEmpty ? "—" : product.notes)
                    .textSelection(.enabled)
                    .foregroundStyle(product.notes.isEmpty ? .secondary : .primary)
            }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StoreBox: View {
    let title: String
    let listing: StoreListing?
    let onEdit: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let l = listing {
                    LabeledContent("Listing URL") {
                        if let url = l.url { Link(url.absoluteString, destination: url) } else { UnknownLabel() }
                    }
                    LabeledContent("Production version") { ValueOrUnknown(value: l.productionVersion) }
                    LabeledContent("Latest submitted") { ValueOrUnknown(value: l.latestSubmittedVersion) }
                    LabeledContent("Review status") { ValueOrUnknown(value: l.reviewStatus) }
                    LabeledContent("Last checked") { ValueOrUnknown(value: l.lastChecked?.shortDate) }
                } else {
                    Text("No listing recorded. Unknown whether this product is on \(title).")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(listing == nil ? "Record listing…" : "Edit…", action: onEdit)
            }
        }
    }
}

private struct LinksTab: View {
    let product: Product

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            linkGroup("Documentation", product.documentation)
            linkGroup("Analytics", product.analytics)
            GroupBox("Social accounts") {
                if product.socialAccounts.isEmpty {
                    Text("None recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(product.socialAccounts) { a in
                        LabeledContent(a.network.title, value: a.handle)
                    }
                }
            }
            Text("Editing documentation, analytics and social links will come with the Marketing module.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func linkGroup(_ title: String, _ links: [DocumentLink]) -> some View {
        GroupBox(title) {
            if links.isEmpty {
                Text("None recorded.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(links) { Link($0.title, destination: $0.url).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }
}

/// A titled list of child records with Add, Edit (double-click) and Delete actions.
struct RecordSection<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    let empty: String
    let onAdd: () -> Void
    let onEdit: (Item) -> Void
    let onDelete: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(action: onAdd) { Label("Add", systemImage: "plus") }
            }
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onEdit(item) }
                            .contextMenu {
                                Button("Edit…") { onEdit(item) }
                                Button("Delete", role: .destructive) { onDelete(item) }
                            }
                        Divider()
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("Double-click a row to edit. Right-click for more actions.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
