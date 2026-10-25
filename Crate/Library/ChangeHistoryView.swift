import RekordboxKit
import SwiftUI

/// Every change Crate has made to the open library, newest first, each of which can be reverted.
struct ChangeHistoryView: View {
    static let windowID = "change-history"

    @Environment(LibraryModel.self) private var model
    /// The entry being reverted, to show progress in its row.
    @State private var reverting: JournalEntry.ID?
    @State private var revertError: String?

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No Changes Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Changes Crate makes to your Rekordbox library appear here, and can be reverted.")
                )
            } else {
                List(model.history) { entry in
                    row(for: entry)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .alert(
            "Couldn\u{2019}t Revert",
            isPresented: Binding(get: { revertError != nil }, set: { if !$0 { revertError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(revertError ?? "")
        }
    }

    private func row(for entry: JournalEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                Text(details(for: entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isReverted {
                Text("Reverted")
                    .foregroundStyle(.secondary)
            } else if reverting == entry.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Revert") { revert(entry) }
                    .disabled(reverting != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func details(for entry: JournalEntry) -> String {
        var details = entry.date.formatted(.relative(presentation: .named))
        if !entry.trashedFiles.isEmpty {
            let files = entry.trashedFiles.count == 1 ? "1 file" : "\(entry.trashedFiles.count) files"
            details += " \u{B7} moved \(files) to the Trash"
        }
        return details
    }

    private func revert(_ entry: JournalEntry) {
        reverting = entry.id
        Task {
            defer { reverting = nil }
            do {
                try await model.revert(entry)
            } catch {
                revertError = error.localizedDescription
            }
        }
    }
}

/// File ▸ Change History.
struct ChangeHistoryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Change History") { openWindow(id: ChangeHistoryView.windowID) }
            .keyboardShortcut("y")
    }
}

#Preview("History", traits: .sampleData) {
    ChangeHistoryView()
}

#Preview("Empty") {
    ChangeHistoryView()
        .environment(LibraryModel(library: .preview))
}
