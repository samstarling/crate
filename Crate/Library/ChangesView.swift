import RekordboxKit
import SwiftUI

/// Changes waiting to be applied to the library, and changes already applied, which can be reverted.
struct ChangesView: View {
    @Environment(LibraryModel.self) private var model
    /// The entry being reverted, to show progress in its row.
    @State private var reverting: JournalEntry.ID?
    @State private var revertError: String?
    @State private var isConfirmingDiscardAll = false

    var body: some View {
        List {
            Section {
                if model.pendingChanges.isEmpty {
                    Text("Changes you make to colours or the collection wait here until you apply them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pendingChanges) { change in
                        pendingRow(for: change)
                    }
                }
            } header: {
                Text("Pending")
            } footer: {
                if !model.pendingChanges.isEmpty {
                    Text("Quit Rekordbox before applying, so it doesn\u{2019}t overwrite these changes.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Applied") {
                if model.history.isEmpty {
                    Text("Nothing has been applied to this library yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.history) { entry in
                        appliedRow(for: entry)
                    }
                }
            }
        }
        .navigationTitle("Changes")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Discard All", role: .destructive) { isConfirmingDiscardAll = true }
                    .disabled(model.pendingChanges.isEmpty || model.isApplying)
                Button {
                    Task { await model.applyPendingChanges() }
                } label: {
                    if model.isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply to Rekordbox")
                    }
                }
                .disabled(model.pendingChanges.isEmpty || model.isApplying)
                .help("Write these changes to your Rekordbox library (⌘S)")
            }
        }
        .confirmationDialog(
            "Discard all \(model.pendingChanges.count) pending changes?",
            isPresented: $isConfirmingDiscardAll
        ) {
            Button("Discard All", role: .destructive) { model.discardAllPendingChanges() }
        } message: {
            Text("They haven\u{2019}t been applied to your library, so nothing there changes.")
        }
        .alert(
            "Couldn\u{2019}t Revert",
            isPresented: Binding(get: { revertError != nil }, set: { if !$0 { revertError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(revertError ?? "")
        }
    }

    private func pendingRow(for change: StagedChange) -> some View {
        HStack {
            Text(change.summary)
            Spacer()
            Button {
                model.discard(change)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Discard this change")
            .disabled(model.isApplying)
        }
    }

    private func appliedRow(for entry: JournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                ForEach(entry.items, id: \.self) { item in
                    Text(item)
                        .font(.callout)
                }
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
                    .disabled(reverting != nil || model.isApplying)
            }
        }
        .padding(.vertical, 2)
    }

    private func details(for entry: JournalEntry) -> String {
        var details = "Applied " + entry.date.formatted(.relative(presentation: .named))
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

#Preview("Changes", traits: .sampleData) {
    NavigationStack {
        ChangesView()
    }
    .frame(width: 600, height: 500)
}

#Preview("Nothing yet") {
    NavigationStack {
        ChangesView()
    }
    .environment(LibraryModel(library: .preview, journal: .preview, pendingStore: .preview))
    .frame(width: 600, height: 400)
}
