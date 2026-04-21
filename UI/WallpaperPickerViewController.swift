import AppKit
import Foundation

/// A list-style picker used inside the Preferences window. Each row shows a
/// thumbnail + name. Emits a single WallpaperBundle via the `onSelection`
/// closure whenever the user picks a row.
///
/// We use an NSTableView here (not NSCollectionView) because the layout is
/// simple and NSTableView is much less fiddly without Interface Builder.
final class WallpaperPickerViewController: NSViewController {

    private let importer = WallpaperImporter.shared
    private let thumbnailer = ThumbnailRenderer.shared

    private var wallpapers: [WallpaperBundle] = []
    private let tableView = NSTableView()
    private let onSelection: (WallpaperBundle) -> Void

    /// Per-bundle thumbnail cache (in-memory). The disk cache in
    /// `ThumbnailRenderer` is the source of truth; this just avoids
    /// redispatching a render when we redraw a row.
    private var thumbnailCache: [UUID: NSImage] = [:]

    /// Rendered at the size the rows actually draw at (logical points —
    /// NSImage handles backing scale).
    private static let rowHeight: CGFloat = 56
    private static let thumbnailSize = NSSize(width: 88, height: 48)

    init(onSelection: @escaping (WallpaperBundle) -> Void) {
        self.onSelection = onSelection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Wallpapers"
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Self.rowHeight
        tableView.allowsMultipleSelection = false
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        scroll.documentView = tableView
        self.view = scroll

        loadWallpapers()
    }

    func reload() { loadWallpapers() }

    private func loadWallpapers() {
        wallpapers = importer.listWallpapers()
        thumbnailCache = thumbnailCache.filter { id, _ in
            wallpapers.contains(where: { $0.id == id })
        }
        tableView.reloadData()
    }

    // MARK: Thumbnails

    /// Lazily fetch the thumbnail for `bundle`. Returns immediately with the
    /// cached image (or nil); if nil, kicks off a background render and
    /// reloads the row when it arrives.
    private func thumbnail(for bundle: WallpaperBundle, rowIndex: Int) -> NSImage? {
        if let cached = thumbnailCache[bundle.id] { return cached }

        thumbnailer.thumbnail(for: bundle, size: Self.thumbnailSize) { [weak self] image in
            guard let self = self, let image = image else { return }
            self.thumbnailCache[bundle.id] = image
            // The row may have shifted (after a reload); look up by identity.
            if let newRow = self.wallpapers.firstIndex(where: { $0.id == bundle.id }) {
                self.tableView.reloadData(
                    forRowIndexes: IndexSet(integer: newRow),
                    columnIndexes: IndexSet(integer: 0))
            }
        }
        return nil
    }
}

extension WallpaperPickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { wallpapers.count }
}

extension WallpaperPickerViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("WallpaperCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ThumbnailRow
            ?? ThumbnailRow(identifier: identifier, thumbnailSize: Self.thumbnailSize)

        let bundle = wallpapers[row]
        cell.configure(
            name: bundle.name,
            subtitle: Self.subtitle(for: bundle),
            thumbnail: thumbnail(for: bundle, rowIndex: row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < wallpapers.count else { return }
        onSelection(wallpapers[row])
    }

    private static func subtitle(for bundle: WallpaperBundle) -> String {
        switch bundle.type {
        case .web:     return "Web"
        case .video:   return "Video"
        case .image:   return "Image"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Row view

/// One row in the picker. Stores an NSImageView + title + subtitle laid out
/// with auto-layout. Reused across rows via NSTableView's identifier recycler.
private final class ThumbnailRow: NSTableCellView {

    private let thumbnailView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, thumbnailSize: NSSize) {
        super.init(frame: .zero)
        self.identifier = identifier

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        addSubview(thumbnailView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = NSFont.systemFont(ofSize: 13)
        addSubview(titleField)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = NSFont.systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        addSubview(subtitleField)

        self.textField = titleField

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: thumbnailSize.width),
            thumbnailView.heightAnchor.constraint(equalToConstant: thumbnailSize.height),

            titleField.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleField.topAnchor.constraint(equalTo: thumbnailView.topAnchor),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, subtitle: String, thumbnail: NSImage?) {
        titleField.stringValue = name
        subtitleField.stringValue = subtitle
        thumbnailView.image = thumbnail
    }
}
