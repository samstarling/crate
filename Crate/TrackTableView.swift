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
    let onSetColor: ([Track.ID], TrackColor?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
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
        tableView.doubleAction = #selector(Coordinator.revealClickedTracks)

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

// MARK: - Columns

struct TrackColumn {
    enum Content {
        case artwork, color, text, number
    }

    let id: String
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    let content: Content
    /// `nil` for columns that can't be sorted. Always ascending; the table flips it as needed.
    let comparator: KeyPathComparator<Track>?
    let configure: (NSTextField, Track) -> Void

    var alignment: NSTextAlignment { content == .number ? .right : .left }

    private init(
        _ id: String, _ title: String, width: CGFloat, minWidth: CGFloat, content: Content = .text,
        comparator: KeyPathComparator<Track>?, configure: @escaping (NSTextField, Track) -> Void = { _, _ in }
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.content = content
        self.comparator = comparator
        self.configure = configure
    }

    /// A plain text column showing `keyPath`, sorted Finder-style.
    private static func text(_ id: String, _ title: String, _ keyPath: KeyPath<Track, String> & Sendable, width: CGFloat, minWidth: CGFloat) -> TrackColumn {
        TrackColumn(id, title, width: width, minWidth: minWidth, comparator: KeyPathComparator(keyPath, comparator: .localizedStandard)) { field, track in
            field.stringValue = track[keyPath: keyPath]
        }
    }

    /// A right-aligned numeric column; `format` returns "" for missing values.
    private static func number<Value: Comparable>(_ id: String, _ title: String, _ keyPath: KeyPath<Track, Value> & Sendable, width: CGFloat, minWidth: CGFloat, format: @escaping (Value) -> String) -> TrackColumn {
        TrackColumn(id, title, width: width, minWidth: minWidth, content: .number, comparator: KeyPathComparator(keyPath)) { field, track in
            field.stringValue = format(track[keyPath: keyPath])
        }
    }

    static let all: [TrackColumn] = [
        TrackColumn("artwork", "", width: 22, minWidth: 22, content: .artwork, comparator: nil),
        TrackColumn("colour", "Colour", width: 90, minWidth: 60, content: .color, comparator: KeyPathComparator(\.colorSortKey)),
        text("title", "Title", \.title, width: 260, minWidth: 120),
        text("artist", "Artist", \.artist, width: 180, minWidth: 80),
        text("album", "Album", \.album, width: 160, minWidth: 60),
        text("genre", "Genre", \.genre, width: 110, minWidth: 50),
        number("bpm", "BPM", \.bpm, width: 55, minWidth: 40) { $0 > 0 ? $0.formatted(.number.precision(.fractionLength(0...2))) : "" },
        text("key", "Key", \.key, width: 45, minWidth: 30),
        number("time", "Time", \.duration, width: 50, minWidth: 40) { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) },
        TrackColumn("rating", "Rating", width: 70, minWidth: 60, comparator: KeyPathComparator(\.rating)) { field, track in
            field.stringValue = String(repeating: "★", count: track.rating) + String(repeating: "☆", count: max(0, 5 - track.rating))
            field.textColor = track.rating > 0 ? .labelColor : .tertiaryLabelColor
        },
        number("year", "Year", \.year, width: 45, minWidth: 35) { $0 > 0 ? String($0) : "" },
        text("label", "Label", \.label, width: 120, minWidth: 60),
        text("dateAdded", "Date Added", \.dateAdded, width: 85, minWidth: 70),
        number("plays", "Plays", \.playCount, width: 45, minWidth: 35) { $0 > 0 ? String($0) : "" },
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func comparator(for descriptor: NSSortDescriptor) -> KeyPathComparator<Track>? {
        guard let key = descriptor.key, var comparator = byID[key]?.comparator else { return nil }
        comparator.order = descriptor.ascending ? .forward : .reverse
        return comparator
    }

    static func sortDescriptor(for comparator: KeyPathComparator<Track>) -> NSSortDescriptor? {
        guard let column = all.first(where: { $0.comparator?.keyPath == comparator.keyPath }) else { return nil }
        return NSSortDescriptor(key: column.id, ascending: comparator.order == .forward)
    }
}

// MARK: - Cells

private final class TextCellView: NSTableCellView {
    let field = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        if alignment == .right {
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        field.textColor = .labelColor
    }
}

/// The Colour column: a borderless pop-up button offering None and the library's colours.
private final class ColorCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("colour")

    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var colors: [TrackColor] = []
    private var onChange: (TrackColor?) -> Void = { _ in }

    static func swatch(for color: TrackColor) -> NSImage {
        let nsColor = NSColor(color.color)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        popUp.isBordered = false
        popUp.target = self
        popUp.action = #selector(changed)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popUp)
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: leadingAnchor),
            popUp.trailingAnchor.constraint(equalTo: trailingAnchor),
            popUp.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(selected: TrackColor?, colors: [TrackColor], onChange: @escaping (TrackColor?) -> Void) {
        self.onChange = onChange
        if colors != self.colors {
            self.colors = colors
            popUp.removeAllItems()
            popUp.addItem(withTitle: "None")
            for color in colors {
                popUp.addItem(withTitle: color.name)
                popUp.lastItem?.image = Self.swatch(for: color)
                popUp.lastItem?.tag = color.id
            }
        }
        popUp.selectItem(withTag: selected?.id ?? 0)
    }

    @objc private func changed() {
        onChange(colors.first { $0.id == popUp.selectedTag() })
    }
}

/// A small artwork thumbnail from Rekordbox's artwork cache.
private final class ArtworkCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("artwork")
    private static let cache = NSCache<NSURL, NSImage>()

    private let artwork = NSImageView()

    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            artwork.image = url.map { url in
                if let cached = Self.cache.object(forKey: url as NSURL) { return cached }
                // Defers reading the file until the image is first drawn.
                let image = NSImage(byReferencing: url)
                Self.cache.setObject(image, forKey: url as NSURL)
                return image
            }
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 3
        artwork.layer?.masksToBounds = true
        artwork.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)
        imageView = artwork
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 20),
            artwork.heightAnchor.constraint(equalToConstant: 20),
            artwork.centerXAnchor.constraint(equalTo: centerXAnchor),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
