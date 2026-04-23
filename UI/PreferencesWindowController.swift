import AppKit
import Foundation

/// Preferences window with three tabs:
///   General      – launch-at-login, reveal-folder, etc.
///   Performance  – FPS cap, pause-when-occluded, respect low-power mode
///   Wallpaper    – picker + property editor for the selected wallpaper
///   About        – build info
///
/// The AppDelegate wires this up via `shared.showWindow()` from the menu bar.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private let rootViewController = PreferencesViewController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ÆtherDesk Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        self.init(window: window)
        window.delegate = self
        window.contentViewController = rootViewController
        rootViewController.setupTabs()
        rootViewController.observePropertyChanges()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Window delegate

    func windowWillClose(_ notification: Notification) {
        // Keep the shared instance around; just let it deallocate children.
    }
}

// MARK: - Root view controller

/// The actual NSViewController that owns child view controllers.
/// PreferencesWindowController sets this as the window's contentViewController.
private final class PreferencesViewController: NSViewController {

    private let tabView = NSTabView()
    private var currentEditor: PropertyEditorViewController?
    private let wallpaperEditorContainer = NSView()
    private var contactedDomainsLabel: NSTextField?

    override func loadView() {
        view = NSView()
    }

    // MARK: Layout

    fileprivate func setupTabs() {
        let contentView = view

        tabView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        // Force a layout pass so the tab view has its correct frame before
        // we add tab items. In macOS 26, NSTabView eagerly places the first
        // tab's content view the moment addTabViewItem is called; without this
        // flush, contentRect can be as narrow as 20 pt, which freezes via the
        // autoresizing mask and conflicts with the tab's leading/trailing constraints.
        contentView.layoutSubtreeIfNeeded()

        tabView.addTabViewItem(tabViewItem(id: "general",     label: "General",     view: buildGeneralTab()))
        tabView.addTabViewItem(tabViewItem(id: "performance", label: "Performance", view: buildPerformanceTab()))
        tabView.addTabViewItem(tabViewItem(id: "wallpaper",   label: "Wallpaper",   view: buildWallpaperTab()))
        tabView.addTabViewItem(tabViewItem(id: "about",       label: "About",       view: buildAboutTab()))
    }

    private func tabViewItem(id: String, label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: id)
        item.label = label
        item.view = view
        return item
    }

    // MARK: Tabs

    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let launchAtLoginStatusLabel = NSTextField(labelWithString: "")
    private let autoCheckUpdatesCheckbox = NSButton(
        checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let autoInstallUpdatesCheckbox = NSButton(
        checkboxWithTitle: "Automatically install updates", target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let lowPowerCheckbox = NSButton(checkboxWithTitle: "Respect Low Power Mode",
                                           target: nil,
                                           action: nil)
    private let pauseOnOcclusionCheckbox = NSButton(
        checkboxWithTitle: "Pause when wallpaper is not visible",
        target: nil,
        action: nil)
    private let pauseOnBatteryCheckbox = NSButton(
        checkboxWithTitle: "Pause when on battery power",
        target: nil,
        action: nil)
    private let blockExternalNetworkCheckbox = NSButton(
        checkboxWithTitle: "Block external network requests",
        target: nil,
        action: nil)
    private let allowLANAccessCheckbox = NSButton(
        checkboxWithTitle: "Allow wallpapers to access local network (LAN)",
        target: nil,
        action: nil)

    private func buildGeneralTab() -> NSView {
        let container = NSView()

        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin(_:))
        launchAtLoginCheckbox.isEnabled = LoginItem.isSupported
        launchAtLoginCheckbox.state = LoginItem.isEnabled ? .on : .off
        container.addSubview(launchAtLoginCheckbox)

        launchAtLoginStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        launchAtLoginStatusLabel.font = NSFont.systemFont(ofSize: 11)
        launchAtLoginStatusLabel.textColor = .secondaryLabelColor
        launchAtLoginStatusLabel.stringValue = LoginItem.statusDescription
        container.addSubview(launchAtLoginStatusLabel)

        autoCheckUpdatesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCheckUpdatesCheckbox.target = self
        autoCheckUpdatesCheckbox.action = #selector(updateSettingsChanged(_:))
        container.addSubview(autoCheckUpdatesCheckbox)

        autoInstallUpdatesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoInstallUpdatesCheckbox.target = self
        autoInstallUpdatesCheckbox.action = #selector(updateSettingsChanged(_:))
        container.addSubview(autoInstallUpdatesCheckbox)

        let revealButton = NSButton(title: "Reveal wallpaper folder",
                                    target: self,
                                    action: #selector(revealWallpaperFolder))
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(revealButton)

        let note = NSTextField(wrappingLabelWithString:
            "ÆtherDesk runs as a menu-bar-only application. It has no Dock presence.")
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(note)

        loadUpdateSettingsIntoControls()

        NSLayoutConstraint.activate([
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            launchAtLoginStatusLabel.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 2),
            launchAtLoginStatusLabel.leadingAnchor.constraint(equalTo: launchAtLoginCheckbox.leadingAnchor, constant: 20),
            launchAtLoginStatusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            autoCheckUpdatesCheckbox.topAnchor.constraint(equalTo: launchAtLoginStatusLabel.bottomAnchor, constant: 16),
            autoCheckUpdatesCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            autoInstallUpdatesCheckbox.topAnchor.constraint(equalTo: autoCheckUpdatesCheckbox.bottomAnchor, constant: 6),
            autoInstallUpdatesCheckbox.leadingAnchor.constraint(equalTo: autoCheckUpdatesCheckbox.leadingAnchor, constant: 20),

            revealButton.topAnchor.constraint(equalTo: autoInstallUpdatesCheckbox.bottomAnchor, constant: 16),
            revealButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            note.topAnchor.constraint(equalTo: revealButton.bottomAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20)
        ])
        return container
    }

    private func loadUpdateSettingsIntoControls() {
        let settings = UpdateSettingsStore.shared.load()
        autoCheckUpdatesCheckbox.state  = settings.automaticallyCheckForUpdates ? .on : .off
        autoInstallUpdatesCheckbox.state = settings.automaticallyInstallUpdates ? .on : .off
        autoInstallUpdatesCheckbox.isEnabled = settings.automaticallyCheckForUpdates
    }

    @objc private func updateSettingsChanged(_ sender: Any) {
        let checkOn = autoCheckUpdatesCheckbox.state == .on
        autoInstallUpdatesCheckbox.isEnabled = checkOn
        if !checkOn { autoInstallUpdatesCheckbox.state = .off }
        var settings = UpdateSettingsStore.shared.load()
        settings.automaticallyCheckForUpdates = checkOn
        settings.automaticallyInstallUpdates  = autoInstallUpdatesCheckbox.state == .on
        // Toggling settings signals the user is re-engaging — clear any skip.
        settings.skippedVersion = nil
        UpdateSettingsStore.shared.save(settings)
        UpdateManager.shared.updateTimerForSettingsChange()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let desired = sender.state == .on
        do {
            try LoginItem.setEnabled(desired)
            launchAtLoginStatusLabel.stringValue = LoginItem.statusDescription
        } catch {
            // Revert the checkbox to the actual state and surface the error.
            sender.state = LoginItem.isEnabled ? .on : .off
            launchAtLoginStatusLabel.stringValue = LoginItem.statusDescription

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func buildPerformanceTab() -> NSView {
        let container = NSView()

        let fpsLabel = NSTextField(labelWithString: "Default FPS cap:")
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fpsLabel)

        fpsPopup.translatesAutoresizingMaskIntoConstraints = false
        fpsPopup.addItems(withTitles: ["15", "30", "60"])
        fpsPopup.target = self
        fpsPopup.action = #selector(performanceSettingsChanged(_:))
        container.addSubview(fpsPopup)

        lowPowerCheckbox.target = self
        lowPowerCheckbox.action = #selector(performanceSettingsChanged(_:))
        lowPowerCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lowPowerCheckbox)

        pauseOnOcclusionCheckbox.target = self
        pauseOnOcclusionCheckbox.action = #selector(performanceSettingsChanged(_:))
        pauseOnOcclusionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pauseOnOcclusionCheckbox)

        pauseOnBatteryCheckbox.target = self
        pauseOnBatteryCheckbox.action = #selector(performanceSettingsChanged(_:))
        pauseOnBatteryCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pauseOnBatteryCheckbox)

        blockExternalNetworkCheckbox.target = self
        blockExternalNetworkCheckbox.action = #selector(performanceSettingsChanged(_:))
        blockExternalNetworkCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blockExternalNetworkCheckbox)

        allowLANAccessCheckbox.target = self
        allowLANAccessCheckbox.action = #selector(performanceSettingsChanged(_:))
        allowLANAccessCheckbox.translatesAutoresizingMaskIntoConstraints = false
        allowLANAccessCheckbox.toolTip = "When disabled, wallpapers cannot connect to private IP addresses (192.168.x.x, 10.x.x.x, etc.) or localhost."
        container.addSubview(allowLANAccessCheckbox)

        loadPerformanceSettingsIntoControls()

        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            fpsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            fpsPopup.centerYAnchor.constraint(equalTo: fpsLabel.centerYAnchor),
            fpsPopup.leadingAnchor.constraint(equalTo: fpsLabel.trailingAnchor, constant: 10),

            lowPowerCheckbox.topAnchor.constraint(equalTo: fpsLabel.bottomAnchor, constant: 20),
            lowPowerCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            pauseOnOcclusionCheckbox.topAnchor.constraint(equalTo: lowPowerCheckbox.bottomAnchor, constant: 10),
            pauseOnOcclusionCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            pauseOnBatteryCheckbox.topAnchor.constraint(equalTo: pauseOnOcclusionCheckbox.bottomAnchor, constant: 10),
            pauseOnBatteryCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            blockExternalNetworkCheckbox.topAnchor.constraint(equalTo: pauseOnBatteryCheckbox.bottomAnchor, constant: 10),
            blockExternalNetworkCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),

            allowLANAccessCheckbox.topAnchor.constraint(equalTo: blockExternalNetworkCheckbox.bottomAnchor, constant: 10),
            allowLANAccessCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20)
        ])
        return container
    }

    private func loadPerformanceSettingsIntoControls() {
        let settings = AppSettingsStore.shared.loadPerformanceSettings()
        fpsPopup.selectItem(withTitle: "\(settings.clampedFPSCap)")
        lowPowerCheckbox.state = settings.respectLowPowerMode ? .on : .off
        pauseOnOcclusionCheckbox.state = settings.pauseWhenNotVisible ? .on : .off
        pauseOnBatteryCheckbox.state = settings.pauseOnBatteryPower ? .on : .off
        blockExternalNetworkCheckbox.state = settings.blockExternalNetwork ? .on : .off
        allowLANAccessCheckbox.state = settings.allowLANAccess ? .on : .off
    }

    @objc private func performanceSettingsChanged(_ sender: Any) {
        let selectedFPS = Int(fpsPopup.titleOfSelectedItem ?? "") ?? Constants.Defaults.fpsCap
        let settings = PerformanceSettings(
            fpsCap: selectedFPS,
            respectLowPowerMode: lowPowerCheckbox.state == .on,
            pauseWhenNotVisible: pauseOnOcclusionCheckbox.state == .on,
            pauseOnBatteryPower: pauseOnBatteryCheckbox.state == .on,
            blockExternalNetwork: blockExternalNetworkCheckbox.state == .on,
            allowLANAccess: allowLANAccessCheckbox.state == .on
        )
        AppSettingsStore.shared.savePerformanceSettings(settings)
    }

    private func buildWallpaperTab() -> NSView {
        // Split: picker on left, editor on right.
        let container = NSView()

        let picker = WallpaperPickerViewController { [weak self] bundle in
            self?.installEditor(for: bundle)
        }
        addChild(picker)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker.view)

        wallpaperEditorContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wallpaperEditorContainer)

        let placeholder = NSTextField(labelWithString: "Select a wallpaper to edit properties.")
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        wallpaperEditorContainer.addSubview(placeholder)

        NSLayoutConstraint.activate([
            picker.view.topAnchor.constraint(equalTo: container.topAnchor),
            picker.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            picker.view.widthAnchor.constraint(equalToConstant: 220),

            wallpaperEditorContainer.topAnchor.constraint(equalTo: container.topAnchor),
            wallpaperEditorContainer.leadingAnchor.constraint(equalTo: picker.view.trailingAnchor, constant: 10),
            wallpaperEditorContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wallpaperEditorContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: wallpaperEditorContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: wallpaperEditorContainer.centerYAnchor)
        ])
        return container
    }

    private func buildAboutTab() -> NSView {
        let view = NSView()

        let title = NSTextField(labelWithString: "ÆtherDesk")
        title.font = NSFont.boldSystemFont(ofSize: 24)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let version = NSTextField(labelWithString: "Version \(versionString)")
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(version)

        let desc = NSTextField(wrappingLabelWithString:
            "A native macOS live wallpaper host for a curated subset of Lively wallpapers.")
        desc.textColor = .secondaryLabelColor
        desc.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(desc)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            version.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            desc.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 20),
            desc.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            desc.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
        return view
    }

    // MARK: Editor swap-in

    private func installEditor(for bundle: WallpaperBundle) {
        wallpaperEditorContainer.subviews.forEach { $0.removeFromSuperview() }

        let editor = PropertyEditorViewController(bundle: bundle)
        currentEditor = editor
        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        wallpaperEditorContainer.addSubview(editor.view)

        let geoPermission = GeolocationPermissionStore.shared.load(for: bundle.id)
        let geoCheckbox = NSButton(
            checkboxWithTitle: "Allow geolocation",
            target: nil, action: nil)
        geoCheckbox.translatesAutoresizingMaskIntoConstraints = false
        geoCheckbox.state = (geoPermission == .allowed) ? .on : .off
        geoCheckbox.target = self
        geoCheckbox.action = #selector(geoPermissionChanged(_:))
        geoCheckbox.toolTip = "When enabled, this wallpaper can access your location via CoreLocation."
        objc_setAssociatedObject(geoCheckbox,
                                 &AssociatedKeys.bundleID,
                                 bundle.id,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        wallpaperEditorContainer.addSubview(geoCheckbox)

        let domains = NetworkPolicy.contactedDomains(for: bundle.id)
        let domainsLabel: NSTextField
        if domains.isEmpty {
            domainsLabel = NSTextField(labelWithString: "No external domains contacted yet.")
        } else {
            let sorted = domains.sorted()
            domainsLabel = NSTextField(wrappingLabelWithString:
                "Domains contacted: " + sorted.joined(separator: ", "))
        }
        domainsLabel.font = NSFont.systemFont(ofSize: 11)
        domainsLabel.textColor = .tertiaryLabelColor
        domainsLabel.translatesAutoresizingMaskIntoConstraints = false
        domainsLabel.lineBreakMode = .byWordWrapping
        wallpaperEditorContainer.addSubview(domainsLabel)
        self.contactedDomainsLabel = domainsLabel

        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: wallpaperEditorContainer.topAnchor),
            editor.view.leadingAnchor.constraint(equalTo: wallpaperEditorContainer.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: wallpaperEditorContainer.trailingAnchor),

            geoCheckbox.topAnchor.constraint(equalTo: editor.view.bottomAnchor, constant: 12),
            geoCheckbox.leadingAnchor.constraint(equalTo: wallpaperEditorContainer.leadingAnchor, constant: 10),

            domainsLabel.topAnchor.constraint(equalTo: geoCheckbox.bottomAnchor, constant: 8),
            domainsLabel.leadingAnchor.constraint(equalTo: wallpaperEditorContainer.leadingAnchor, constant: 10),
            domainsLabel.trailingAnchor.constraint(equalTo: wallpaperEditorContainer.trailingAnchor, constant: -10),
            domainsLabel.bottomAnchor.constraint(lessThanOrEqualTo: wallpaperEditorContainer.bottomAnchor, constant: -10)
        ])
    }

    // MARK: Forward property edits to the running wallpaper

    fileprivate func observePropertyChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePropertyChanged(_:)),
            name: PropertyEditorViewController.propertyChangedNotification,
            object: nil)
    }

    @objc private func handlePropertyChanged(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String,
              let value = note.userInfo?["value"],
              let bundleID = note.object as? UUID else { return }

        // Route to the global WallpaperManager via the shared AppDelegate.
        guard let delegate = NSApp.delegate as? AppDelegate,
              let manager = delegate.wallpaperManager else { return }

        manager.updateProperty(key, value: value, forBundleID: bundleID)
    }

    // MARK: Actions

    @objc private func revealWallpaperFolder() {
        let importer = WallpaperImporter()
        NSWorkspace.shared.open(importer.wallpapersDirectory)
    }

    @objc private func geoPermissionChanged(_ sender: NSButton) {
        guard let bundleID = objc_getAssociatedObject(sender, &AssociatedKeys.bundleID) as? UUID else { return }
        let permission: GeolocationPermission = (sender.state == .on) ? .allowed : .denied
        GeolocationPermissionStore.shared.save(permission, for: bundleID)
    }
}

private enum AssociatedKeys {
    static var bundleID: UInt8 = 0
}
