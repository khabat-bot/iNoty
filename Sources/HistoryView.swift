import SwiftUI

/// One compact line of the history (used on the main screen and in the full list).
struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(entry.ok ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "(no title)" : entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                let second = entry.error ?? entry.body
                if !second.isEmpty {
                    Text(second)
                        .font(.caption)
                        .foregroundStyle(entry.ok ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(entry.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationView {
            Group {
                if model.history.isEmpty {
                    Text("No requests yet")
                        .foregroundStyle(.secondary)
                } else {
                    List(model.history) { entry in
                        NavigationLink(destination: HistoryDetail(entry: entry)) {
                            HistoryRow(entry: entry)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                }
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { model.clearHistory() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct HistoryDetail: View {
    let entry: HistoryEntry

    private var kindLabel: String {
        switch entry.kind {
        case "test": return "Test button"
        case "clear": return "Clear request"
        default: return "Notification request"
        }
    }

    private var resultLabel: String {
        if let error = entry.error { return "Failed: \(error)" }
        return entry.kind == "notify" || entry.kind == "test" ? "Handed to iOS" : "Done"
    }

    var body: some View {
        List {
            Section("Summary") {
                row("Time", entry.date.formatted(date: .abbreviated, time: .standard))
                row("Type", kindLabel)
                row("Result", resultLabel)
                if !entry.title.isEmpty { row("Title", entry.title) }
                if !entry.body.isEmpty { row("Body", entry.body) }
            }
            if !entry.details.isEmpty {
                Section("Request fields") {
                    Text(entry.details)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
