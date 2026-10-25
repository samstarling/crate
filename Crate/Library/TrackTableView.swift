import AppKit
import SwiftUI

/// The track list, backed by `NSTableView`.
///
/// SwiftUI's `Table` diffs every row by identity when the order changes, which took ~3s to re-sort a
/// few thousand tracks. `NSTableView` just reloads the visible rows.
struct TrackTableView: NSViewRepresentable {
    let tracks: [Track]
    /// The colours offered in the Colour column and context menu.
    let colors: [TrackColor]
    @Binding var sortOrder: [KeyPathComparator<Track>]
    @Binding var selection: Set<Track.ID>
    let onPlay: (Track) -> Void
    let onTogglePlayback: () -> Void
    let onSetColor: ([Track.ID], TrackColor?) -> Void
    let onRemove: ([Track]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = TrackNSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 24

        for column in TrackColumn.all {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            tableColumn.headerCell.alignment = column.alignment
            if column.comparator != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            if column.content == .artwork {
                tableColumn.resizingMask = []
            }
            tableView.addTableColumn(tableColumn)
        }

        // Remembers column widths and order between launches.
        tableView.autosaveName = "TrackTable"
        tableView.autosaveTableColumns = true

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.playClickedTrack)
        tableView.onTogglePlayback = { [weak coordinator = context.coordinator] in coordinator?.togglePlayback() }
        tableView.onPlaySelection = { [weak coordinator = context.coordinator] in coordinator?.playSelectedTrack() }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var parent: TrackTableView
        private var tracks: [Track] = []
        /// Set while we push state into the table, so the resulting delegate callbacks don't echo it back.
        private var isApplyingUpdate = false
        weak var tableView: NSTableView?

        init(_ parent: TrackTableView) {
            self.parent = parent
        }

        func update(from parent: TrackTableView) {
            self.parent = parent
            guard let tableView else { return }
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }

            let descriptors = parent.sortOrder.first.flatMap { TrackColumn.sortDescriptor(for: $0) }.map { [$0] } ?? []
            if tableView.sortDescriptors != descriptors {
                tableView.sortDescriptors = descriptors
            }

            guard parent.tracks != tracks else { return }
            tracks = parent.tracks
            tableView.reloadData()

            let rowsByID = Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            let rows = IndexSet(parent.selection.compactMap { rowsByID[$0] })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first {
                tableView.scrollRowToVisible(first)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            tracks.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingUpdate else { return }
            parent.sortOrder = tableView.sortDescriptors.first.flatMap { TrackColumn.comparator(for: $0) }.map { [$0] } ?? []
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = TrackColumn.byID[tableColumn.identifier.rawValue] else { return nil }
            let track = tracks[row]

            switch column.content {
            case .artwork:
                let cell = tableView.makeView(withIdentifier: ArtworkCellView.identifier, owner: nil) as? ArtworkCellView ?? ArtworkCellView()
                cell.url = track.artworkURL
                return cell
            case .color:
                let cell = tableView.makeView(withIdentifier: ColorCellView.identifier, owner: nil) as? ColorCellView ?? ColorCellView()
                cell.configure(selected: track.color, colors: parent.colors) { [weak self] color in
                    self?.parent.onSetColor([track.id], color)
                }
                return cell
            case .text, .number:
                break
            }

            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? TextCellView
                ?? TextCellView(identifier: tableColumn.identifier, alignment: column.alignment)
            column.configure(cell.field, track)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let tableView else { return }
            parent.selection = Set(tableView.selectedRowIndexes.map { tracks[$0].id })
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let rows = clickedRows
            guard !rows.isEmpty else { return }

            if rows.count == 1 {
                menu.addItem(item("Play", action: #selector(playClickedTrack)))
            }

            let colorMenu = NSMenu()
            let current = Set(rows.map { tracks[$0].color?.id ?? 0 })
            for color in [nil] + parent.colors.map(Optional.some) {
                let colorItem = item(color?.name ?? "None", action: #selector(setColorFromMenu(_:)))
                colorItem.tag = color?.id ?? 0
                colorItem.image = color.map { ColorCellView.swatch(for: $0) }
                colorItem.state = current == [colorItem.tag] ? .on : .off
                colorMenu.addItem(colorItem)
            }
            let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)

            menu.addItem(.separator())
            menu.addItem(item("Show in Finder", action: #selector(revealClickedTracks)))

            menu.addItem(.separator())
            menu.addItem(item("Remove from Collection\u{2026}", action: #selector(removeClickedTracks)))
        }

        @objc private func removeClickedTracks() {
            parent.onRemove(clickedRows.map { tracks[$0] })
        }

        private func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func setColorFromMenu(_ sender: NSMenuItem) {
            let ids = clickedRows.map { tracks[$0].id }
            parent.onSetColor(ids, parent.colors.first { $0.id == sender.tag })
        }

        // MARK: Playback

        @objc func playClickedTrack() {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            parent.onPlay(tracks[tableView.clickedRow])
        }

        func playSelectedTrack() {
            guard let row = tableView?.selectedRowIndexes.first else { return }
            parent.onPlay(tracks[row])
        }

        func togglePlayback() {
            parent.onTogglePlayback()
        }

        /// The rows a right-click or double-click applies to: the whole selection if the clicked row is part of it.
        private var clickedRows: IndexSet {
            guard let tableView, tableView.clickedRow >= 0 else { return [] }
            return tableView.selectedRowIndexes.contains(tableView.clickedRow)
                ? tableView.selectedRowIndexes
                : [tableView.clickedRow]
        }

        @objc func revealClickedTracks() {
            let urls = clickedRows.map { tracks[$0].fileURL }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

/// Handles Space (play/pause) and Return (play the selection).
private final class TrackNSTableView: NSTableView {
    var onTogglePlayback: () -> Void = {}
    var onPlaySelection: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": onTogglePlayback()
        case "\r": onPlaySelection()
        default: super.keyDown(with: event)
        }
    }
}

#Preview {
    @Previewable @State var sortOrder: [KeyPathComparator<Track>] = []
    @Previewable @State var selection: Set<Track.ID> = []
    TrackTableView(
        tracks: sortOrder.first.map { RekordboxLibrary.preview.sorted(Track.previews, by: $0) } ?? Track.previews,
        colors: TrackColor.previews,
        sortOrder: $sortOrder,
        selection: $selection,
        onPlay: { _ in },
        onTogglePlayback: {},
        onSetColor: { _, _ in },
        onRemove: { _ in }
    )
    .frame(width: 1100, height: 250)
}
