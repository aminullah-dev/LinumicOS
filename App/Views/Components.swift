import LinumicCore
import SwiftUI

/// Shown wherever a fact has not been verified. Never replaced by a guess.
struct UnknownLabel: View {
    var body: some View {
        Text("Unknown — to be verified")
            .foregroundStyle(.secondary)
            .italic()
    }
}

/// Displays an optional value, or `UnknownLabel` when it is missing.
struct ValueOrUnknown: View {
    let value: String?

    var body: some View {
        if let value, !value.isEmpty {
            Text(value).textSelection(.enabled)
        } else {
            UnknownLabel()
        }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(text)
    }
}

extension ProductStatus {
    var color: Color {
        switch self {
        case .idea: .purple
        case .development: .blue
        case .active: .green
        case .maintenance: .teal
        case .paused: .orange
        case .retired: .secondary
        }
    }
}

extension VerificationStatus {
    var color: Color {
        switch self {
        case .verified: .green
        case .partiallyVerified: .orange
        case .unknown: .gray
        case .conflicting: .red
        }
    }

    var symbol: String {
        switch self {
        case .verified: "checkmark.seal.fill"
        case .partiallyVerified: "circle.lefthalf.filled"
        case .unknown: "questionmark.circle"
        case .conflicting: "exclamationmark.triangle.fill"
        }
    }

    /// Upper-case label used on badges: VERIFIED, PARTIALLY VERIFIED, UNKNOWN, CONFLICTING.
    var badgeText: String {
        switch self {
        case .verified: "VERIFIED"
        case .partiallyVerified: "PARTIALLY VERIFIED"
        case .unknown: "UNKNOWN"
        case .conflicting: "CONFLICTING"
        }
    }
}

/// The verification badge used everywhere a fact is shown.
struct VerificationBadge: View {
    let status: VerificationStatus
    var compact = false

    var body: some View {
        // Meaning is carried by icon + text, never color alone. The text uses the primary
        // color so it keeps at least 4.5:1 contrast in light and dark mode. Color goes on the icon and border.
        HStack(spacing: 4) {
            Image(systemName: status.symbol).foregroundStyle(status.color)
            Text(compact ? status.title : status.badgeText).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(status.color.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verification: \(status.title)")
    }
}

/// A badge that opens a popover listing the sources, the verification date and the notes.
struct EvidenceButton: View {
    let verification: Verification
    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            VerificationBadge(status: verification.status)
        }
        .buttonStyle(.plain)
        .help("Show evidence")
        .accessibilityHint("Shows the sources, verification date and notes")
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            EvidenceView(verification: verification)
                .padding()
                .frame(width: 440)
        }
    }
}

struct EvidenceView: View {
    let verification: Verification

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VerificationBadge(status: verification.status)
                Spacer()
                if let at = verification.verifiedAt {
                    Text("Verified \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Never verified").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !verification.notes.isEmpty {
                Text(verification.notes).font(.callout).textSelection(.enabled)
            }
            Divider()
            if verification.sources.isEmpty {
                Text("No sources recorded.").foregroundStyle(.secondary)
            } else {
                Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(verification.sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(source.kind.title).font(.caption.weight(.semibold))
                            Text(source.observedAt.shortDate).font(.caption).foregroundStyle(.secondary)
                        }
                        if let url = URL(string: source.reference), url.scheme?.hasPrefix("http") == true {
                            Link(source.reference, destination: url).font(.caption)
                        } else {
                            Text(source.reference).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let detail = source.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

extension ReleaseStage {
    var color: Color {
        switch self {
        case .planning: .gray
        case .development: .blue
        case .internalTesting, .beta: .indigo
        case .review: .orange
        case .released: .green
        case .deprecated: .secondary
        case .blocked: .red
        }
    }
}

extension IssueSeverity {
    var color: Color {
        switch self {
        case .low: .gray
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }
}

extension DeploymentStatus {
    var color: Color {
        switch self {
        case .unknown: .gray
        case .healthy: .green
        case .degraded: .orange
        case .failed: .red
        case .inProgress: .blue
        }
    }
}

extension RoadmapStatus {
    var color: Color {
        switch self {
        case .idea: .purple
        case .planned: .gray
        case .inProgress: .blue
        case .done: .green
        case .dropped: .secondary
        }
    }
}

/// Screen for a module whose integration doesn't exist yet. It says plainly that nothing is connected.
struct NotIntegratedView: View {
    let item: SidebarItem
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.symbol)
        } description: {
            Text(message)
        } actions: {
            Text("Not connected. No data is shown until this integration is implemented and authorized.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(item.title)
    }
}

extension Binding where Value == String? {
    /// Maps an optional string to a text field, so an empty field stores `nil` (unknown).
    var orEmpty: Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: { wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }
}

extension Binding where Value == URL? {
    var asText: Binding<String> {
        Binding<String>(
            get: { wrappedValue?.absoluteString ?? "" },
            set: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                wrappedValue = trimmed.isEmpty ? nil : URL(string: trimmed)
            }
        )
    }
}

/// A "has date" toggle paired with a date picker, so the date can stay unknown.
struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { date != nil },
            set: { date = $0 ? (date ?? .now) : nil }
        ))
        if let unwrapped = date {
            DatePicker("Date", selection: Binding(get: { unwrapped }, set: { date = $0 }), displayedComponents: .date)
        }
    }
}

/// Standard sheet chrome for editing forms: title, Cancel, Save.
struct EditorSheet<Content: View>: View {
    let title: String
    var canSave = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding()
            Form { content }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}

extension Date {
    var shortDate: String { formatted(date: .abbreviated, time: .omitted) }
}
