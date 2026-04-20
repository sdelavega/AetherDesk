import AppKit
import Foundation

class WallpaperPickerViewController: NSViewController {

    private var collectionView: NSCollectionView!
    private var wallpapers: [WallpaperBundle] = []
    private let importer = WallpaperImporter()
    private var onSelection: ((WallpaperBundle) -> Void)?

    init(onSelection: @escaping (WallpaperBundle) -> Void) {
        self.onSelection = onSelection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        collectionView = NSCollectionView()
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]

        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.itemSize = NSSize(width: 120, height: 80)
        flowLayout.minimumInteritemSpacing = 10
        flowLayout.minimumLineSpacing = 10
        flowLayout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView.collectionViewLayout = flowLayout

        collectionView.register(NSCollectionViewItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("WallpaperItem"))

        scrollView.documentView = collectionView

        self.view = scrollView

        loadWallpapers()
    }

    private func loadWallpapers() {
        wallpapers = importer.listWallpapers()
        collectionView.reloadData()
    }

    func reload() {
        loadWallpapers()
    }
}

extension WallpaperPickerViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return wallpapers.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("WallpaperItem"), for: indexPath)

        let bundle = wallpapers[indexPath.item]
        if let collectionItem = item as? NSCollectionViewItem {
            collectionItem.textField?.stringValue = bundle.name
        }

        return item
    }
}

extension WallpaperPickerViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        let bundle = wallpapers[indexPath.item]
        onSelection?(bundle)
    }
}
