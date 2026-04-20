import AppKit
import Foundation

class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private var tabView: NSTabView!

    private override init(window: NSWindow?) {
        let prefWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        prefWindow.title = "AetherDesk Preferences"
        prefWindow.center()

        super.init(window: prefWindow)

        setupTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTabs() {
        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = createGeneralTab()
        tabView.addTabViewItem(generalTab)

        let performanceTab = NSTabViewItem(identifier: "performance")
        performanceTab.label = "Performance"
        performanceTab.view = createPerformanceTab()
        tabView.addTabViewItem(performanceTab)

        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = createAboutTab()
        tabView.addTabViewItem(aboutTab)

        window?.contentView?.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 20),
            tabView.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor, constant: -20)
        ])
    }

    private func createGeneralTab() -> NSView {
        let view = NSView()

        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launchAtLoginCheckbox)

        let showInDockCheckbox = NSButton(checkboxWithTitle: "Show icon in Dock", target: nil, action: nil)
        showInDockCheckbox.translatesAutoresizingMaskIntoConstraints = false
        showInDockCheckbox.isEnabled = false
        view.addSubview(showInDockCheckbox)

        NSLayoutConstraint.activate([
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            showInDockCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 10),
            showInDockCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])

        return view
    }

    private func createPerformanceTab() -> NSView {
        let view = NSView()

        let fpsLabel = NSTextField(labelWithString: "Default FPS Cap:")
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fpsLabel)

        let fpsPopup = NSPopUpButton()
        fpsPopup.translatesAutoresizingMaskIntoConstraints = false
        fpsPopup.addItems(withTitles: ["15", "30", "60"])
        fpsPopup.selectItem(at: 1)
        view.addSubview(fpsPopup)

        let lowPowerCheckbox = NSButton(checkboxWithTitle: "Respect Low Power Mode", target: nil, action: nil)
        lowPowerCheckbox.translatesAutoresizingMaskIntoConstraints = false
        lowPowerCheckbox.state = .on
        view.addSubview(lowPowerCheckbox)

        let pauseWhenOccludedCheckbox = NSButton(checkboxWithTitle: "Pause when wallpaper is not visible", target: nil, action: nil)
        pauseWhenOccludedCheckbox.translatesAutoresizingMaskIntoConstraints = false
        pauseWhenOccludedCheckbox.state = .on
        view.addSubview(pauseWhenOccludedCheckbox)

        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            fpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            fpsPopup.centerYAnchor.constraint(equalTo: fpsLabel.centerYAnchor),
            fpsPopup.leadingAnchor.constraint(equalTo: fpsLabel.trailingAnchor, constant: 10),

            lowPowerCheckbox.topAnchor.constraint(equalTo: fpsLabel.bottomAnchor, constant: 20),
            lowPowerCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            pauseWhenOccludedCheckbox.topAnchor.constraint(equalTo: lowPowerCheckbox.bottomAnchor, constant: 10),
            pauseWhenOccludedCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])

        return view
    }

    private func createAboutTab() -> NSView {
        let view = NSView()

        let appNameLabel = NSTextField(labelWithString: "AetherDesk")
        appNameLabel.font = NSFont.boldSystemFont(ofSize: 24)
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appNameLabel)

        let versionLabel = NSTextField(labelWithString: "Version 1.0.0")
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(versionLabel)

        let descriptionLabel = NSTextField(wrappingLabelWithString: "A native macOS live wallpaper host for Lively-style wallpapers.")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descriptionLabel)

        NSLayoutConstraint.activate([
            appNameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            appNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 5),
            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            descriptionLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 20),
            descriptionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])

        return view
    }
}
