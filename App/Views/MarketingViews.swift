import LinumicCore
import SwiftUI

/// Drafts, approval and schedule for social posts. The Command Center never posts anything.
/// "Published" is recorded by a person, with the link to the live post.
struct ContentCalendarView: View {
    @Environment(InventoryModel.self) private var model
    @State private var editing: ContentItem?
    @State private var isAdding = false
    @State private var filter: ContentStatus?

    private var groups: [(ContentStatus, [ContentItem])] {
        ContentStatus.allCases.compactMap { status in
            guard filter == nil || filter == status else { return nil }
            let items = model.content.filter { $0.status == status }
                .sorted { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
            return items.isEmpty ? nil : (status, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Workflow: Idea → Draft → In Review → Approved → Scheduled → Published. Publishing is done by a person on the network, then recorded here with its link.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Show", selection: $filter) {
                        Text("All").tag(ContentStatus?.none)
                        ForEach(ContentStatus.allCases) { Text($0.title).tag(ContentStatus?.some($0)) }
                    }
                    .frame(width: 200)
                }
                if model.content.isEmpty {
                    ContentUnavailableView {
                        Label("No content yet", systemImage: "calendar")
                    } description: {
                        Text("Draft a product or release announcement, send it for review, and schedule it once approved.")
                    } actions: {
                        Button("New Post") { isAdding = true }
                    }
                }
                ForEach(groups, id: \.0) { status, items in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            StatusBadge(text: status.title, color: status.color)
                            Text("\(items.count)").foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            ContentCard(item: item, productName: model.product(id: item.productID ?? "")?.name) { editing = item }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Content Calendar")
        .toolbar {
            Button { isAdding = true } label: { Label("New Post", systemImage: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .sheet(isPresented: $isAdding) { ContentEditor(item: nil) }
        .sheet(item: $editing) { ContentEditor(item: $0) }
    }
}

private struct ContentCard: View {
    let item: ContentItem
    let productName: String?
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title).fontWeight(.medium)
                StatusBadge(text: item.kind.title, color: .indigo)
                Spacer()
                if let d = item.scheduledFor { Label(d.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.caption) }
            }
            Text(item.body).lineLimit(2).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(item.networks.map(\.title).joined(separator: " · ")).font(.caption)
                if let productName { Text("· \(productName)").font(.caption).foregroundStyle(.secondary) }
                if let campaign = item.campaign { Text("· \(campaign)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let by = item.approvedBy, let at = item.approvedAt { Text("Approved by \(by), \(at.shortDate)").font(.caption).foregroundStyle(.secondary) }
                if let url = item.publishedURL { Link("View post", destination: url).font(.caption) }
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu { Button("Open…", action: onOpen) }
        .accessibilityAction(named: "Open", onOpen)
    }
}

private struct ContentEditor: View {
    @Environment(InventoryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ContentItem
    @State private var scheduleDate: Date
    @State private var publishedLink = ""
    @State private var error: String?
    private let isNew: Bool

    init(item: ContentItem?) {
        isNew = item == nil
        _draft = State(initialValue: item ?? ContentItem(title: ""))
        _scheduleDate = State(initialValue: item?.scheduledFor ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
    }

    var body: some View {
        EditorSheet(title: isNew ? "New Post" : draft.title, canSave: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() }, onSave: { model.upsertContent(draft); dismiss() }) {
            Section("Post") {
                TextField("Title (internal)", text: $draft.title)
                TextField("Text", text: $draft.body, axis: .vertical).lineLimit(4...12)
                    .disabled(draft.status == .published)
                Picker("Kind", selection: $draft.kind) { ForEach(ContentKind.allCases) { Text($0.title).tag($0) } }
                Picker("Product", selection: $draft.productID) {
                    Text("None").tag(String?.none)
                    ForEach(model.products) { Text($0.name).tag(String?.some($0.id)) }
                }
                TextField("Campaign", text: $draft.campaign.orEmpty)
                TextField("Language (e.g. Dari, Pashto, English)", text: $draft.language.orEmpty)
            }
            Section("Networks") {
                ForEach(SocialNetwork.allCases) { n in
                    Toggle(n.title, isOn: Binding(get: { draft.networks.contains(n) },
                                                  set: { on in if on { draft.networks.append(n) } else { draft.networks.removeAll { $0 == n } } }))
                }
            }
            Section("Workflow: currently \(draft.status.title)") {
                if draft.status.next.contains(.scheduled) {
                    DatePicker("Schedule for", selection: $scheduleDate)
                }
                if draft.status.next.contains(.published) {
                    TextField("Link to the published post", text: $publishedLink)
                }
                HStack {
                    ForEach(draft.status.next) { target in
                        Button(actionTitle(target)) { move(to: target) }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                Text("Nothing is posted automatically. Publish on the network yourself, then record it here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(1...4)
            if !isNew {
                Button("Delete Post", role: .destructive) { model.deleteContent(draft.id); dismiss() }
            }
        }
        .frame(minHeight: 720)
    }

    private func actionTitle(_ target: ContentStatus) -> String {
        switch target {
        case .draft: draft.status == .cancelled ? "Restore to Draft" : "Back to Draft"
        case .inReview: "Submit for Review"
        case .approved: draft.status == .scheduled ? "Unschedule" : "Approve"
        case .scheduled: "Schedule"
        case .published: "Mark Published"
        case .cancelled: "Cancel Post"
        case .idea: "Idea"
        }
    }

    private func move(to target: ContentStatus) {
        do {
            try draft.transition(to: target, scheduledFor: target == .scheduled ? scheduleDate : nil,
                                 publishedURL: URL(string: publishedLink.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil })
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ContentStatus {
    var color: Color {
        switch self {
        case .idea: .purple
        case .draft: .gray
        case .inReview: .orange
        case .approved: .teal
        case .scheduled: .blue
        case .published: .green
        case .cancelled: .secondary
        }
    }
}

/// Social accounts recorded per product. No network is connected.
struct SocialAccountsView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        let rows = model.products.flatMap { p in p.socialAccounts.map { (p.name, $0) } }
        List {
            Section {
                Text("LinkedIn, Facebook, Instagram, X and YouTube aren't connected: that needs OAuth credentials, which will live on the backend. Draft and approve posts in the Content Calendar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("No social accounts recorded. None were found as verified evidence during discovery.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.1.id) { product, account in
                LabeledContent("\(product) · \(account.network.title)") {
                    if let url = account.url { Link(account.handle, destination: url) } else { Text(account.handle) }
                }
            }
        }
        .navigationTitle("Social Media")
    }
}
