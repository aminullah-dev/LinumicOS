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
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(text)
    }
}

extension ProductStatus {
    var color: Color {
        switch self {
        case .unknown: .gray
        case .idea: .purple
        case .development: .blue
        case .active: .green
        case .maintenance: .teal
        case .paused: .orange
        case .retired: .secondary
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
