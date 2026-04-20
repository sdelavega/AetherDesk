import AppKit
import Foundation

/// A simple list-style picker used inside the Preferences window. Emits a
/// single WallpaperBundle via the `onSelection` closure whenever the user
/// picks a row.
///
/// We use an NSTableView here (not NSCollectionView) because the layout is
/// simple and NSTableView is much less fiddly without Interface Builder.
final class WallpaperPickerViewController: NSViewController {

    private let importer = WallpaperImporter()
    private var wallpapers: [WallpaperBundle] = []
    private let tableView = NSTableView()
    private let onSelection: (WallpaperBundle) -> Void

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
        tableView.rowHeight = 22
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
        tableView.reloadData()
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
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let c = NSTableCellView()
                c.identifier = identifier
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor)
                ])
                return c
            }()
        let bundle = wallpapers[row]
        cell.textField?.stringValue = bundle.name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < wallpapers.count else { return }
        onSelection(wallpapers[row])
    }
}
