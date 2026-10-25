import RekordboxKit
import SwiftUI

/// Changes waiting to be applied to the library, and changes already applied, which can be reverted.
struct ChangesView: View {
    @Environment(LibraryModel.self) private var model
    @State private var selection = Set<Row>()
    /// The entry being reverted, to show progress in its row.
    @State private var reverting: JournalEntry.ID?
    @State private var revertError: String?
    @State private var isConfirmingDiscardAll = false

    /// A row in the list: a pending change or an applied one.
    enum Row: Hashable {
        case pending(StagedChange.ID)
        case applied(JournalEntry.ID)
    }

    var body: some View {
        Group {
            if model.pendingChanges.isEmpty && model.history.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Colours you set and tracks you remove wait here until you apply them to your Rekordbox library.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Changes")
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .confirmationDialog(
            "Discard all \(model.pendingChanges.count) changes?",
            isPresented: $isConfirmingDiscardAll
        ) {
            Button("Discard All", role: .destructive) { model.discardAllPendingChanges() }
        } message: {
            Text("They haven\u{2019}t been applied, so your Rekordbox library won\u{2019}t change.")
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

    private var list: some View {
        List(selection: $selection) {
            if !model.pendingChanges.isEmpty {
                Section("Waiting to Be Applied") {
                    ForEach(model.pendingChanges) { change in
                        pendingRow(for: change)
                            .tag(Row.pending(change.id))
                    }
                }
            }
            if !model.history.isEmpty {
                Section("Applied") {
                    ForEach(model.history) { entry in
                        appliedRow(for: entry)
                            .tag(Row.applied(entry.id))
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Row.self) { rows in
            let pending = pendingChanges(in: rows)
            if !pending.isEmpty {
                Button(pending.count == 1 ? "Discard Change" : "Discard \(pending.count) Changes") { discard(pending) }
            }
            if let entry = revertibleEntry(in: rows) {
                Button("Revert") { revert(entry) }
            }
        }
        .onDeleteCommand {
            discard(pendingChanges(in: selection))
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(status)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Discard All\u{2026}") { isConfirmingDiscardAll = true }
                .disabled(model.pendingChanges.isEmpty || model.isApplying)
            Button("Apply Changes") { Task { await model.applyPendingChanges() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingChanges.isEmpty || model.isApplying)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var status: String {
        if model.isApplying { return "Applying changes\u{2026}" }
        switch model.pendingChanges.count {
        case 0: return "No changes waiting to be applied"
        case 1: return "1 change waiting to be applied"
        case let count: return "\(count) changes waiting to be applied"
        }
    }

    // MARK: Rows

    private func pendingRow(for change: StagedChange) -> some View {
        Label {
            Text(change.summary)
        } icon: {
            switch change.change {
            case .setColor(let colorID, _):
                if let color = model.library?.colors.first(where: { $0.id == colorID }) {
                    Image(systemName: "circle.fill").foregroundStyle(color.color)
                } else {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            case .remove(_, let movingFilesToTrash):
                Image(systemName: movingFilesToTrash ? "trash" : "minus.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func appliedRow(for entry: JournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.summary)
                    ForEach(entry.items, id: \.self) { item in
                        Text(item)
                    }
                    Text(details(for: entry))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: entry.isReverted ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if reverting == entry.id {
                ProgressView()
                    .controlSize(.small)
            } else if entry.isReverted {
                Text("Reverted")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func details(for entry: JournalEntry) -> String {
        var details = "Applied " + entry.date.formatted(.relative(presentation: .named))
        if !entry.trashedFiles.isEmpty {
            let files = entry.trashedFiles.count == 1 ? "1 file" : "\(entry.trashedFiles.count) files"
            details += " \u{B7} moved \(files) to the Trash"
        }
        return details
    }

    // MARK: Actions

    private func pendingChanges(in rows: Set<Row>) -> [StagedChange] {
        model.pendingChanges.filter { rows.contains(.pending($0.id)) }
    }

    /// The applied entry selected, if exactly one is and it can be reverted.
    private func revertibleEntry(in rows: Set<Row>) -> JournalEntry? {
        let entries = model.history.filter { rows.contains(.applied($0.id)) }
        guard entries.count == 1, let entry = entries.first, !entry.isReverted, reverting == nil, !model.isApplying else { return nil }
        return entry
    }

    private func discard(_ changes: [StagedChange]) {
        for change in changes {
            model.discard(change)
        }
        selection.subtract(changes.map { .pending($0.id) })
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
    .frame(width: 700, height: 500)
}

#Preview("No changes") {
    NavigationStack {
        ChangesView()
    }
    .environment(LibraryModel(library: .preview, journal: .preview, pendingStore: .preview))
    .frame(width: 700, height: 400)
}
