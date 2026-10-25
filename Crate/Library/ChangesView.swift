import RekordboxKit
import SwiftUI

/// Changes waiting to be applied to the library, and changes already applied, which can be reverted.
struct ChangesView: View {
    @Environment(LibraryModel.self) private var model
    @State private var selection = Set<Row>()
    @State private var isConfirmingDiscardAll = false

    /// A row in the list: a pending change or an applied one.
    enum Row: Hashable {
        case pending(StagedChange.ID)
        case applied(AppliedChange.ID)
    }

    var body: some View {
        Group {
            if model.pendingChanges.isEmpty && model.appliedChanges.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Colours you set and tracks you remove wait here until you apply them to your Rekordbox library. Until you quit Crate, you can revert what you\u{2019}ve applied.")
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
    }

    private var list: some View {
        List(selection: $selection) {
            if !model.pendingChanges.isEmpty {
                Section("Pending") {
                    ForEach(model.pendingChanges) { change in
                        pendingRow(for: change)
                            .tag(Row.pending(change.id))
                    }
                }
            }
            if !model.appliedChanges.isEmpty {
                Section("Applied") {
                    ForEach(model.appliedChanges) { entry in
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
            if let applied = selectedAppliedChange(in: rows) {
                if applied.isReverted {
                    Button("Apply Again") { Task { await model.applyAgain(applied) } }
                } else {
                    Button("Revert") { Task { await model.revert(applied) } }
                }
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
                .disabled(model.pendingChanges.isEmpty || model.isWriting)
            Button("Apply Changes") { Task { await model.applyPendingChanges() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingChanges.isEmpty || model.isWriting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var status: String {
        if model.isWriting { return "Saving to your library\u{2026}" }
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

    private func appliedRow(for entry: AppliedChange) -> some View {
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
            if entry.isReverted {
                Text("Reverted")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func details(for entry: AppliedChange) -> String {
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

    /// The applied change selected, if exactly one is and nothing is being written.
    private func selectedAppliedChange(in rows: Set<Row>) -> AppliedChange? {
        let applied = model.appliedChanges.filter { rows.contains(.applied($0.id)) }
        guard applied.count == 1, !model.isWriting else { return nil }
        return applied.first
    }

    private func discard(_ changes: [StagedChange]) {
        model.discard(changes)
        selection.subtract(changes.map { .pending($0.id) })
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
    .environment(LibraryModel(session: LibrarySession(library: .preview, files: .none), files: .none))
    .frame(width: 700, height: 400)
}
