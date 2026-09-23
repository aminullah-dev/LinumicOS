import LinumicCore
import SwiftUI

/// Edits a product's name and notes, or creates a new product with every fact unknown.
/// Facts are edited one at a time with `FactEditor`, so each change gets its own evidence.
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
            TextField("Name", text: $draft.name)
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            Text(isNew
                 ? "A new product starts with every fact Unknown. Record facts from its Overview tab, each with its source."
                 : "Edit each fact from its row on the Overview tab, so the change carries its own source and status.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        var product = draft
        product.name = product.name.trimmingCharacters(in: .whitespaces)
        if isNew {
            product.id = model.newProductID(for: product.name)
            product.provenance = .manualEntry()
        }
        onSave(product)
        dismiss()
    }
}

/// Editable copy of a `Verification`, shared by every editor that records evidence.
struct VerificationDraft {
    var status: VerificationStatus
    var sources: [Source]
    var notes: String
    var newKind: SourceKind = .ownerStatement
    var newReference = ""
    var newDetail = ""
    /// Adds "confirmed by the owner in the Command Center" as a source on save.
    var recordOwnerConfirmation = false

    init(_ v: Verification) {
        status = v.status
        sources = v.sources
        notes = v.notes
    }

    /// Sources after applying the pending additions.
    var finalSources: [Source] {
        var result = sources
        let ref = newReference.trimmingCharacters(in: .whitespaces)
        if !ref.isEmpty {
            result.append(Source(kind: newKind, reference: ref, detail: newDetail.isEmpty ? nil : newDetail))
        }
        if recordOwnerConfirmation {
            result.append(Source(kind: .ownerStatement, reference: "Confirmed by the owner in Linumic Command Center"))
        }
        return result
    }

    /// Why this can't be saved yet, or nil if it can.
    var blocker: String? {
        if (status == .verified || status == .partiallyVerified) && finalSources.isEmpty {
            return "\(status.title) needs at least one source. Add one, or record your own confirmation."
        }
        if status == .conflicting && finalSources.count < 2 && notes.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Conflicting needs the conflicting sources or a note explaining the conflict."
        }
        return nil
    }

    func build(previous: Verification) -> Verification {
        let changed = status != previous.status || finalSources != previous.sources
        let date: Date? = status == .unknown ? nil : (changed ? .now : previous.verifiedAt ?? .now)
        return Verification(status: status, sources: finalSources, verifiedAt: date, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Form sections for status, notes, existing sources and a new source.
struct VerificationSection: View {
    @Binding var draft: VerificationDraft

    var body: some View {
        Section("Verification") {
            Picker("Status", selection: $draft.status) {
                ForEach(VerificationStatus.allCases) { Text($0.title).tag($0) }
            }
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
        }
        Section("Sources") {
            if draft.sources.isEmpty {
                Text("No sources yet.").foregroundStyle(.secondary)
            }
            ForEach(draft.sources) { source in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(source.kind.title) · \(source.observedAt.shortDate)").font(.caption.weight(.semibold))
                        Text(source.reference).font(.caption).lineLimit(2)
                    }
                    Spacer()
                    Button(role: .destructive) { draft.sources.removeAll { $0.id == source.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this source")
                }
            }
            Toggle("Record my confirmation as a source", isOn: $draft.recordOwnerConfirmation)
            Picker("New source type", selection: $draft.newKind) {
                ForEach(SourceKind.allCases) { Text($0.title).tag($0) }
            }
            TextField("New source reference (URL, file path, or document)", text: $draft.newReference)
            TextField("What the source says (optional)", text: $draft.newDetail)
        }
        if let blocker = draft.blocker {
            Section { Label(blocker, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
        }
    }
}

/// Edits one product fact: its value and its evidence.
struct FactEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: ProductField
    let state: FieldState
    /// Returns false if the value can't be parsed for this field.
    let onSave: (String?, Verification) -> Bool
    @State private var text: String
    @State private var draft: VerificationDraft
    @State private var parseError: String?

    init(field: ProductField, state: FieldState, onSave: @escaping (String?, Verification) -> Bool) {
        self.field = field
        self.state = state
        self.onSave = onSave
        _text = State(initialValue: state.displayValue ?? "")
        _draft = State(initialValue: VerificationDraft(state.verification))
    }

    var body: some View {
        EditorSheet(title: field.title, canSave: draft.blocker == nil, onCancel: { dismiss() }, onSave: save) {
            Section("Value") {
                switch field {
                case .status:
                    Picker("Development status", selection: $text) {
                        Text("Unknown — to be verified").tag("")
                        ForEach(ProductStatus.allCases) { Text($0.title).tag($0.title) }
                    }
                case .isLinumicProduct:
                    Picker("Linumic product", selection: $text) {
                        Text("Unknown — to be verified").tag("")
                        Text("Yes").tag("Yes")
                        Text("No").tag("No")
                    }
                case .summary:
                    TextField("Description", text: $text, axis: .vertical).lineLimit(2...6)
                case .alsoKnownAs:
                    TextField("Names, separated by commas", text: $text)
                default:
                    TextField(field.title, text: $text)
                }
                Text("Leave it empty if the fact is unknown. Record where the value comes from below.")
                    .font(.caption).foregroundStyle(.secondary)
                if let parseError { Label(parseError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
            VerificationSection(draft: $draft)
        }
        .frame(minHeight: 560)
    }

    private func save() {
        let isEmpty = text.trimmingCharacters(in: .whitespaces).isEmpty
        if isEmpty && (draft.status == .verified || draft.status == .partiallyVerified) {
            parseError = "A verified fact needs a value. Leave it Unknown, or mark it Conflicting."
            return
        }
        if !isEmpty && draft.status == .unknown {
            parseError = "A value marked Unknown would look like a fact. Choose a status and a source, or clear the value."
            return
        }
        if onSave(isEmpty ? nil : text, draft.build(previous: state.verification)) {
            dismiss()
        } else {
            parseError = "That value isn't valid for \(field.title)."
        }
    }
}

struct PlatformEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let original: PlatformRecord
    @State private var draft: PlatformRecord
    @State private var verification: VerificationDraft
    let onSave: (PlatformRecord) -> Void

    init(record: PlatformRecord?, onSave: @escaping (PlatformRecord) -> Void) {
        let r = record ?? PlatformRecord(platform: .unknown, verification: .unknown)
        original = r
        _draft = State(initialValue: r)
        _verification = State(initialValue: VerificationDraft(r.verification))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Platform", canSave: verification.blocker == nil, onCancel: { dismiss() }, onSave: {
            var r = draft
            r.verification = verification.build(previous: original.verification)
            onSave(r)
            dismiss()
        }) {
            Section("Platform") {
                Picker("Platform", selection: $draft.platform) {
                    ForEach(Platform.allCases) { Text($0.title).tag($0) }
                }
                TextField("Component (e.g. Passenger app)", text: $draft.component.orEmpty)
                TextField("Bundle / application ID", text: $draft.identifier.orEmpty)
                TextField("Version in build config", text: $draft.sourceVersion.orEmpty)
                Text("Evidence should be a build file, a store listing or a release asset. A folder name isn't evidence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VerificationSection(draft: $verification)
        }
        .frame(minHeight: 600)
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
    private let original: RepositoryRecord
    @State private var draft: RepositoryRecord
    @State private var link: VerificationDraft
    let onSave: (RepositoryRecord) -> Void

    init(repository: RepositoryRecord?, onSave: @escaping (RepositoryRecord) -> Void) {
        let r = repository ?? RepositoryRecord(name: "")
        original = r
        _draft = State(initialValue: r)
        _link = State(initialValue: VerificationDraft(r.link))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Repository", canSave: !draft.name.isEmpty && link.blocker == nil, onCancel: { dismiss() }, onSave: {
            var r = draft
            r.link = link.build(previous: original.link)
            onSave(r)
            dismiss()
        }) {
            Section("Repository") {
                TextField("Name", text: $draft.name)
                TextField("Owner", text: $draft.owner.orEmpty)
                TextField("URL", text: $draft.url.asText)
                Picker("Host", selection: $draft.host) {
                    Text("GitHub").tag(RepositoryHost.github)
                    Text("Other").tag(RepositoryHost.other)
                }
                Picker("Type", selection: $draft.type) {
                    ForEach(RepositoryType.allCases) { Text($0.title).tag($0) }
                }
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(1...4)
                Text("This only records the repository. The Command Center never pushes, merges or deletes anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Evidence that this repository belongs to the product:").font(.caption).foregroundStyle(.secondary)
            VerificationSection(draft: $link)
        }
        .frame(minHeight: 640)
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
    private let original: StoreListing
    @State private var draft: StoreListing
    @State private var verification: VerificationDraft
    let onSave: (StoreListing) -> Void

    init(listing: StoreListing?, onSave: @escaping (StoreListing) -> Void) {
        let l = listing ?? StoreListing(store: .appStore)
        original = l
        _draft = State(initialValue: l)
        _verification = State(initialValue: VerificationDraft(l.verification))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Store Listing", canSave: verification.blocker == nil, onCancel: { dismiss() }, onSave: {
            var l = draft
            l.verification = verification.build(previous: original.verification)
            onSave(l)
            dismiss()
        }) {
            Section("Listing") {
                Picker("Store", selection: $draft.store) {
                    ForEach(AppStore.allCases) { Text($0.title).tag($0) }
                }
                TextField("App name", text: $draft.appName.orEmpty)
                TextField("Bundle / application ID", text: $draft.appIdentifier.orEmpty)
                TextField("Listing URL", text: $draft.url.asText)
                TextField("Live (production) version", text: $draft.productionVersion.orEmpty)
                TextField("Latest submitted version", text: $draft.latestSubmittedVersion.orEmpty)
                TextField("Review status", text: $draft.reviewStatus.orEmpty)
                TextField("Storefront", text: $draft.storefront.orEmpty)
                TextField("Seller", text: $draft.seller.orEmpty)
            }
            VerificationSection(draft: $verification)
        }
        .frame(minHeight: 680)
    }
}
