import LinumicCore
import SwiftUI

/// Question answering over Command Center records only. Each statement is labelled
/// Verified, Derived or Unknown and shows its basis. No language model is connected.
struct AssistantView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @State private var question = ""
    @State private var answers: [AssistantAnswer] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Answers come only from the records in this app: facts with their sources, GitHub and App Store snapshots, and releases, roadmap, issues and market evidence you've recorded. No language model is connected, and nothing comes from general knowledge.",
                              systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                        if answers.isEmpty {
                            Text("Try a question").font(.headline)
                            FlowButtons(items: Assistant.suggestedQuestions) { ask($0) }
                        }
                        ForEach(Array(answers.enumerated()), id: \.offset) { index, answer in
                            AnswerCard(answer: answer) { router.open(productID: $0) }
                                .id(index)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: answers.count) { proxy.scrollTo(answers.count - 1, anchor: .top) }
            }
            Divider()
            HStack {
                TextField("Ask about products, releases, issues, changes or market evidence… (English or Persian)", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { ask(question) }
                Button("Ask") { ask(question) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                if !answers.isEmpty {
                    Menu("Suggestions") { ForEach(Assistant.suggestedQuestions, id: \.self) { q in Button(L(q)) { ask(L(q)) } } }
                        .fixedSize()
                }
            }
            .padding(12)
        }
        .navigationTitle("AI Assistant")
        .onAppear { focused = true }
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let inventory = Inventory(products: model.products, unresolved: model.unresolved, market: model.market, content: model.content)
        answers.append(Assistant(inventory: inventory).answer(q))
        question = ""
    }
}

private struct AnswerCard: View {
    let answer: AssistantAnswer
    let openProduct: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.question).font(.headline)
            ForEach(answer.statements) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    KindBadge(kind: s.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.text).textSelection(.enabled)
                        Text(s.basis).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if let id = s.productID {
                        Button("Open") { openProduct(id) }.buttonStyle(.link).font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct KindBadge: View {
    let kind: AnswerKind
    private var color: Color { kind == .verified ? .green : kind == .derived ? .blue : .gray }
    private var symbol: String { kind == .verified ? "checkmark.seal.fill" : kind == .derived ? "function" : "questionmark.circle" }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(kind.title.uppercased()).foregroundStyle(.primary)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .frame(width: 90, alignment: .leading)
        .accessibilityLabel(kind.title)
    }
}

/// Wrapping row of suggestion buttons.
private struct FlowButtons: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(L(item)) { action(L(item)) }.buttonStyle(.bordered)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(width: bounds.width, subviews: subviews).positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
