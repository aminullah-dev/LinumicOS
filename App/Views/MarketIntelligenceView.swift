import LinumicCore
import SwiftUI

/// Sources → evidence → findings. Nothing appears here unless a person records it with its source.
struct MarketIntelligenceView: View {
    @Environment(InventoryModel.self) private var model
    @State private var editing: Editing?
    @State private var refusal: String?

    enum Editing: Identifiable {
        case source(MarketSource?), evidence(MarketEvidence?), finding(MarketFinding?)
        var id: String {
            switch self {
            case .source(let s): "s-\(s?.id.uuidString ?? "new")"
            case .evidence(let e): "e-\(e?.id.uuidString ?? "new")"
            case .finding(let f): "f-\(f?.id.uuidString ?? "new")"
            }
        }
    }

    var body: some View {
        let m = model.market
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Market intelligence for Afghanistan. Every evidence item names its source and collection date, every finding cites evidence, and derived findings state their method. Nothing here is generated.")
                    .font(.callout).foregroundStyle(.secondary)

                if m.sources.isEmpty && m.evidence.isEmpty && m.findings.isEmpty {
                    ContentUnavailableView {
                        Label("No market evidence recorded yet", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("Start by registering a source, such as a dataset, survey, customer interview or product request. Then record what it says.")
                    } actions: {
                        Button("Add Source") { editing = .source(nil) }
                    }
                }

                section("Findings", count: m.findings.count, add: m.evidence.isEmpty ? nil : { editing = .finding(nil) },
                        hint: m.evidence.isEmpty ? "Record evidence before adding findings." : nil) {
                    ForEach(m.findings) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(f.statement).fontWeight(.medium)
                                Spacer()
                                StatusBadge(text: f.kind.title, color: f.kind == .verified ? .green : .blue)
                                StatusBadge(text: f.review.title, color: f.review == .reviewed ? .green : .orange)
                            }
                            if f.kind == .derived { Text("Method: \(f.method)").font(.caption).foregroundStyle(.secondary) }
                            Text(verbatim: String(localized: "Evidence:") + " " + m.evidence(for: f).map { "“\($0.excerpt.prefix(60))” (\(m.source(for: $0)?.name ?? "?"), \($0.collectedAt.shortDate))" }.joined(separator: "; "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .row { editing = .finding(f) } delete: {
                            model.updateMarket { $0.findings.removeAll { $0.id == f.id } }
                        }
                    }
                }

                section("Evidence", count: m.evidence.count, add: m.sources.isEmpty ? nil : { editing = .evidence(nil) },
                        hint: m.sources.isEmpty ? "Register a source before recording evidence." : nil) {
                    ForEach(m.evidence.sorted { $0.collectedAt > $1.collectedAt }) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("“\(e.excerpt)”")
                            Text([m.source(for: e)?.name, e.publishedAt.map { String(localized: "published \($0.shortDate)") }, String(localized: "collected \(e.collectedAt.shortDate)"), e.region, e.sector]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .row { editing = .evidence(e) } delete: {
                            var ok = false
                            model.updateMarket { ok = $0.removeEvidence(e.id) }
                            if !ok { refusal = String(localized: "This evidence is cited by a finding. Remove or edit the finding first.") }
                        }
                    }
                }

                section("Sources", count: m.sources.count, add: { editing = .source(nil) }, hint: nil) {
                    ForEach(m.sources) { src in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(src.name).fontWeight(.medium)
                                StatusBadge(text: src.kind.title, color: .indigo)
                                Spacer()
                                if let url = src.url { Link("Open", destination: url) }
                            }
                            if !src.reliabilityNote.isEmpty { Text(src.reliabilityNote).font(.caption).foregroundStyle(.secondary) }
                        }
                        .row { editing = .source(src) } delete: {
                            var ok = false
                            model.updateMarket { ok = $0.removeSource(src.id) }
                            if !ok { refusal = String(localized: "Evidence still comes from this source. Remove that evidence first.") }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Market Intelligence")
        .sheet(item: $editing) { e in
            switch e {
            case .source(let s): MarketSourceEditor(source: s) { new in model.updateMarket { $0.sources.upsert(new) } }
            case .evidence(let ev): MarketEvidenceEditor(evidence: ev, sources: model.market.sources) { new in model.updateMarket { $0.evidence.upsert(new) } }
            case .finding(let f): MarketFindingEditor(finding: f, market: model.market, products: model.products) { new in model.updateMarket { $0.findings.upsert(new) } }
            }
        }
        .alert("Not removed", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK") { refusal = nil }
        } message: { Text(verbatim: refusal ?? "") }
    }

    private func section<Content: View>(_ title: String, count: Int, add: (() -> Void)?, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let add { Button(action: add) { Label("Add", systemImage: "plus") } }
            }
            if let hint { Text(LocalizedStringKey(hint)).font(.caption).foregroundStyle(.secondary) }
            VStack(spacing: 0) { content() }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private extension View {
    /// Standard row: padding, double-click to edit, context menu with Edit and Delete.
    func row(edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        self.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)
            .contextMenu {
                Button("Edit…", action: edit)
                Button("Delete", role: .destructive, action: delete)
            }
            .overlay(alignment: .bottom) { Divider() }
    }
}

struct MarketSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MarketSource
    let onSave: (MarketSource) -> Void

    init(source: MarketSource?, onSave: @escaping (MarketSource) -> Void) {
        _draft = State(initialValue: source ?? MarketSource(name: "", kind: .publication))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Market Source", canSave: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            TextField("Name", text: $draft.name)
            Picker("Kind", selection: $draft.kind) { ForEach(MarketSourceKind.allCases) { Text($0.title).tag($0) } }
            TextField("Publisher", text: $draft.publisher.orEmpty)
            TextField("URL", text: $draft.url.asText)
            TextField("Language", text: $draft.language.orEmpty)
            TextField("Reliability and terms of use", text: $draft.reliabilityNote, axis: .vertical).lineLimit(2...5)
        }
    }
}

struct MarketEvidenceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let sources: [MarketSource]
    @State private var draft: MarketEvidence
    @State private var tags: String
    let onSave: (MarketEvidence) -> Void

    init(evidence: MarketEvidence?, sources: [MarketSource], onSave: @escaping (MarketEvidence) -> Void) {
        self.sources = sources
        let e = evidence ?? MarketEvidence(sourceID: sources.first?.id ?? UUID(), excerpt: "")
        _draft = State(initialValue: e)
        _tags = State(initialValue: e.tags.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        EditorSheet(title: "Evidence", canSave: !draft.excerpt.trimmingCharacters(in: .whitespaces).isEmpty && sources.contains { $0.id == draft.sourceID },
                    onCancel: { dismiss() }, onSave: {
            var e = draft
            e.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            onSave(e)
            dismiss()
        }) {
            Picker("Source", selection: $draft.sourceID) { ForEach(sources) { Text($0.name).tag($0.id) } }
            TextField("What the source says (quote or figure, as found)", text: $draft.excerpt, axis: .vertical).lineLimit(3...8)
            OptionalDatePicker(title: "Publication date known", date: $draft.publishedAt)
            DatePicker("Collected", selection: $draft.collectedAt, displayedComponents: .date)
            TextField("Region", text: $draft.region.orEmpty)
            TextField("Sector", text: $draft.sector.orEmpty)
            TextField("Language", text: $draft.language.orEmpty)
            TextField("Tags, separated by commas", text: $tags)
        }
        .frame(minHeight: 520)
    }
}

struct MarketFindingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let market: MarketIntelligence
    let products: [Product]
    @State private var draft: MarketFinding
    let onSave: (MarketFinding) -> Void

    init(finding: MarketFinding?, market: MarketIntelligence, products: [Product], onSave: @escaping (MarketFinding) -> Void) {
        self.market = market
        self.products = products
        _draft = State(initialValue: finding ?? MarketFinding(statement: "", kind: .derived, evidenceIDs: []))
        self.onSave = onSave
    }

    private var blocker: String? {
        if draft.statement.trimmingCharacters(in: .whitespaces).isEmpty { return "Write the finding." }
        if draft.evidenceIDs.isEmpty { return "Select at least one evidence item." }
        if draft.kind == .derived && draft.method.trimmingCharacters(in: .whitespaces).isEmpty { return "A derived finding must state its method." }
        return nil
    }

    var body: some View {
        EditorSheet(title: "Finding", canSave: blocker == nil, onCancel: { dismiss() }, onSave: { onSave(draft); dismiss() }) {
            Section {
                TextField("Finding", text: $draft.statement, axis: .vertical).lineLimit(2...5)
                Picker("Kind", selection: $draft.kind) { ForEach(FindingKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                if draft.kind == .derived { TextField("Method (how the evidence leads to this)", text: $draft.method, axis: .vertical).lineLimit(1...4) }
                Picker("Review", selection: $draft.review) { ForEach(MarketFinding.Review.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Section("Evidence cited") {
                ForEach(market.evidence) { e in
                    Toggle(isOn: Binding(get: { draft.evidenceIDs.contains(e.id) },
                                         set: { on in if on { draft.evidenceIDs.append(e.id) } else { draft.evidenceIDs.removeAll { $0 == e.id } } })) {
                        VStack(alignment: .leading) {
                            Text("“\(e.excerpt.prefix(80))”").lineLimit(2)
                            Text("\(market.source(for: e)?.name ?? "?") · \(e.collectedAt.shortDate)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Related products") {
                ForEach(products) { p in
                    Toggle(p.name, isOn: Binding(get: { draft.productIDs.contains(p.id) },
                                                 set: { on in if on { draft.productIDs.append(p.id) } else { draft.productIDs.removeAll { $0 == p.id } } }))
                }
            }
            if let blocker { Section { Label(blocker, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
        }
        .frame(minHeight: 620)
    }
}
