import LinumicCore
import SwiftUI

/// Everything that still needs the owner's confirmation, conflicts first, plus the
/// projects found during discovery that aren't confirmed products.
struct VerificationView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @State private var filter: VerificationStatus?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif
    private var statusColumns: Int { compact ? 2 : 4 }

    private struct Row: Identifiable {
        let id: String
        let productID: String
        let productName: String
        let item: String
        let verification: Verification
    }

    private var rows: [Row] {
        model.products.flatMap { p in
            p.needsConfirmation.enumerated().map { i, entry in
                Row(id: "\(p.id)-\(i)", productID: p.id, productName: p.name, item: entry.label, verification: entry.verification)
            }
        }
        .filter { filter == nil || $0.verification.status == filter }
        .sorted { ($0.verification.status, $0.productName) < ($1.verification.status, $1.productName) }
    }

    var body: some View {
        let s = model.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: statusColumns), spacing: 12) {
                    ForEach([VerificationStatus.verified, .partiallyVerified, .unknown, .conflicting]) { status in
                        VStack(alignment: .leading, spacing: 4) {
                            VerificationBadge(status: status)
                            Text("\(s.countsByVerification[status, default: 0])")
                                .font(.title.weight(.semibold)).monospacedDigit()
                            Text("products").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(s.countsByVerification[status, default: 0]) products \(status.title)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    AdaptiveStack(spacing: 8) {
                        HStack {
                            Text("Needs your confirmation").font(.headline)
                            Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        if !compact { Spacer() }
                        Picker("Show", selection: $filter) {
                            Text("All").tag(VerificationStatus?.none)
                            ForEach([VerificationStatus.conflicting, .unknown, .partiallyVerified]) { Text(verbatim: $0 == .partiallyVerified ? L("Partial") : $0.title).tag(VerificationStatus?.some($0)) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                    Text("Only you can settle these. Open a product and use Edit… on the row, or click a badge to see the evidence gathered so far.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            Group {
                                if compact {
                                    // Phone: product and badge on one line, the item and its notes below.
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Button(row.productName) { router.open(productID: row.productID) }
                                                .buttonStyle(.borderless).foregroundStyle(.tint)
                                            Spacer()
                                            EvidenceButton(verification: row.verification)
                                        }
                                        itemText(row)
                                    }
                                } else {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        EvidenceButton(verification: row.verification).frame(width: 170, alignment: .leading)
                                        Button(row.productName) { router.open(productID: row.productID) }
                                            .buttonStyle(.borderless).foregroundStyle(.tint)
                                            .frame(width: 180, alignment: .leading)
                                        itemText(row)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            Divider()
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Not yet confirmed as products").font(.headline)
                    Text("Found during discovery, but the evidence can't settle whether they belong to Linumic. See docs/product-discovery-report.md.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.unresolved) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.location).font(.caption.monospaced()).textSelection(.enabled)
                                Text(item.findings).font(.callout).textSelection(.enabled)
                                if let q = item.question {
                                    Label(q, systemImage: "questionmark.bubble").font(.callout.weight(.medium)).foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                Text(item.name).bold()
                                StatusBadge(text: item.kind.title, color: .purple)
                                Spacer()
                                EvidenceButton(verification: item.verification)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Verification")
    }

    private func itemText(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.item).fontWeight(.medium)
            if !row.verification.notes.isEmpty {
                Text(row.verification.notes).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
