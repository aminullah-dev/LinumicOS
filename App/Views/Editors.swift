import LinumicCore
import SwiftUI

struct ProductEditor: View {
    @Environment(InventoryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    @State private var draft: Product
    let onSave: (Product) -> Void

    init(product: Product?, onSave: @escaping (Product) -> Void) {
        isNew = product == nil
        _draft = State(initialValue: product ?? Product(id: "", name: ""))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: isNew ? "New Product" : "Edit \(draft.name)",
                    canSave: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() },
                    onSave: save) {
            Section("Identity") {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.summary.orEmpty, axis: .vertical)
                TextField("Category", text: $draft.category.orEmpty)
                Picker("Status", selection: $draft.status) {
                    ForEach(ProductStatus.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Platforms") {
                ForEach(Platform.allCases) { platform in
                    Toggle(platform.title, isOn: Binding(
                        get: { draft.platforms.contains(platform) },
                        set: { on in
                            if on { draft.platforms.append(platform) } else { draft.platforms.removeAll { $0 == platform } }
                            draft.platforms.sort { Platform.allCases.firstIndex(of: $0)! < Platform.allCases.firstIndex(of: $1)! }
                        }
                    ))
                }
            }
            Section("Versions & infrastructure") {
                TextField("Current version", text: $draft.currentVersion.orEmpty)
                TextField("Next version", text: $draft.nextVersion.orEmpty)
                TextField("Backend", text: $draft.backend.orEmpty)
                TextField("Website", text: $draft.website.asText)
            }
            Section("Notes") {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Text("Leave a field empty if the fact is unknown. It will show as \"Unknown — to be verified\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 620)
    }

    private func save() {
        var product = draft
        product.name = product.name.trimmingCharacters(in: .whitespaces)
        if isNew { product.id = model.newProductID(for: product.name) }
        product.provenance = .manualEntry()
        onSave(product)
        dismiss()
    }
}

struct ReleaseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Release
    let onSave: (Release) -> Void

    init(release: Release?, defaultPlatform: Platform, onSave: @escaping (Release) -> Void) {
        _draft = State(initialValue: release ?? Release(version: "", platform: defaultPlatform))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Release", canSave: !draft.version.isEmpty, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Version", text: $draft.version)
            TextField("Build number", text: $draft.buildNumber.orEmpty)
            Picker("Platform", selection: $draft.platform) {
                ForEach(Platform.allCases) { Text($0.title).tag($0) }
            }
            Picker("Environment", selection: $draft.environment) {
                ForEach(DeploymentEnvironment.allCases) { Text($0.title).tag($0) }
            }
            Picker("Stage", selection: $draft.stage) {
                ForEach(ReleaseStage.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Release candidate", isOn: $draft.isReleaseCandidate)
            OptionalDatePicker(title: "Release date known", date: $draft.releaseDate)
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...6)
        }
    }
}

struct RepositoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RepositoryRecord
    let onSave: (RepositoryRecord) -> Void

    init(repository: RepositoryRecord?, onSave: @escaping (RepositoryRecord) -> Void) {
        _draft = State(initialValue: repository ?? RepositoryRecord(name: ""))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Repository", canSave: !draft.name.isEmpty, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Name", text: $draft.name)
            TextField("URL", text: $draft.url.asText)
            Picker("Host", selection: $draft.host) {
                Text("GitHub").tag(RepositoryHost.github)
                Text("Other").tag(RepositoryHost.other)
            }
            TextField("Default branch", text: $draft.defaultBranch.orEmpty)
            Text("This only records the repository. The Command Center never pushes, merges or deletes anything.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RoadmapEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoadmapItem
    let onSave: (RoadmapItem) -> Void

    init(item: RoadmapItem?, onSave: @escaping (RoadmapItem) -> Void) {
        _draft = State(initialValue: item ?? RoadmapItem(title: ""))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Roadmap Item", canSave: !draft.title.isEmpty, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Title", text: $draft.title)
            TextField("Detail", text: $draft.detail, axis: .vertical).lineLimit(2...6)
            Picker("Status", selection: $draft.status) {
                ForEach(RoadmapStatus.allCases) { Text($0.title).tag($0) }
            }
            TextField("Target version", text: $draft.targetVersion.orEmpty)
            OptionalDatePicker(title: "Target date known", date: $draft.targetDate)
        }
    }
}

struct IssueEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IssueRecord
    let onSave: (IssueRecord) -> Void

    init(issue: IssueRecord?, onSave: @escaping (IssueRecord) -> Void) {
        _draft = State(initialValue: issue ?? IssueRecord(title: ""))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Issue", canSave: !draft.title.isEmpty, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Title", text: $draft.title)
            Picker("Severity", selection: $draft.severity) {
                ForEach(IssueSeverity.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Open", isOn: $draft.isOpen)
            TextField("URL", text: $draft.url.asText)
        }
    }
}

struct DeploymentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Deployment
    let onSave: (Deployment) -> Void

    init(deployment: Deployment?, onSave: @escaping (Deployment) -> Void) {
        _draft = State(initialValue: deployment ?? Deployment(environment: .production, target: ""))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Deployment", canSave: !draft.target.isEmpty, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Target (e.g. API server, website)", text: $draft.target)
            Picker("Environment", selection: $draft.environment) {
                ForEach(DeploymentEnvironment.allCases) { Text($0.title).tag($0) }
            }
            Picker("Status", selection: $draft.status) {
                ForEach(DeploymentStatus.allCases) { Text($0.title).tag($0) }
            }
            TextField("Version", text: $draft.version.orEmpty)
            OptionalDatePicker(title: "Deployment date known", date: $draft.deployedAt)
        }
    }
}

struct StoreListingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    private let existed: Bool
    @State private var draft: StoreListing
    let onSave: (StoreListing?) -> Void

    init(title: String, listing: StoreListing?, onSave: @escaping (StoreListing?) -> Void) {
        self.title = title
        existed = listing != nil
        _draft = State(initialValue: listing ?? StoreListing())
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "\(title) Listing", onCancel: { dismiss() }, onSave: {
            var l = draft
            l.lastChecked = .now
            onSave(l)
            dismiss()
        }) {
            TextField("Listing URL", text: $draft.url.asText)
            TextField("Production version", text: $draft.productionVersion.orEmpty)
            TextField("Latest submitted version", text: $draft.latestSubmittedVersion.orEmpty)
            TextField("Review status", text: $draft.reviewStatus.orEmpty)
            if existed {
                Button("Remove listing record", role: .destructive) { onSave(nil); dismiss() }
            }
            Text("Saving sets \"Last checked\" to today. Enter only values you have verified in the store console.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
