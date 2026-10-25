import AppKit
import RekordboxKit
import SwiftUI

final class TextCellView: NSTableCellView {
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
final class ColorCellView: NSTableCellView {
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
final class ArtworkCellView: NSTableCellView {
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
