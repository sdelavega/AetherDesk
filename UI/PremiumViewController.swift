// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

#if AETHERDESK_STORE
import AppKit
import StoreKit

/// Preferences > Premium. Sells and restores ÆtherDesk Premium (Apple
/// Weather for WeatherAether). Includes the disclosures App Review requires
/// for an auto-renewing subscription: title, period, price, and working links
/// to the Terms of Use and Privacy Policy.
final class PremiumViewController: NSViewController {

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL = URL(string: "https://sdelavega.github.io/AetherDesk/privacy.html")!
    private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let buyStack = NSStackView()
    private let unavailableLabel = NSTextField(wrappingLabelWithString:
        "Purchases are unavailable right now. Check your internet connection and try again.")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Purchases", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage Subscription…", target: nil, action: nil)
    private let disclosureLabel = NSTextField(wrappingLabelWithString: "")
    private var isBusy = false

    override func loadView() {
        view = NSView()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let title = NSTextField(labelWithString: "ÆtherDesk Premium")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        let body = NSTextField(wrappingLabelWithString:
            "Premium unlocks Apple Weather for the Weather Aether wallpaper: " +
            "forecasts from Apple's WeatherKit service. Without Premium, " +
            "Weather Aether uses Open-Meteo, which is free.")
        body.textColor = .secondaryLabelColor

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        buyStack.orientation = .vertical
        buyStack.alignment = .leading
        buyStack.spacing = 6

        unavailableLabel.textColor = .secondaryLabelColor
        retryButton.target = self
        retryButton.action = #selector(retryLoad)

        restoreButton.target = self
        restoreButton.action = #selector(restorePurchases)
        manageButton.target = self
        manageButton.action = #selector(manageSubscription)
        let accountRow = NSStackView(views: [restoreButton, manageButton])
        accountRow.spacing = 8

        disclosureLabel.font = NSFont.systemFont(ofSize: 11)
        disclosureLabel.textColor = .secondaryLabelColor

        let terms = linkButton("Terms of Use (EULA)", action: #selector(openTerms))
        let privacy = linkButton("Privacy Policy", action: #selector(openPrivacy))
        let linkRow = NSStackView(views: [terms, privacy])
        linkRow.spacing = 12

        for v in [title, body, statusLabel, buyStack, unavailableLabel, retryButton,
                  accountRow, disclosureLabel, linkRow] as [NSView] {
            stack.addArrangedSubview(v)
        }
        stack.setCustomSpacing(16, after: statusLabel)
        stack.setCustomSpacing(16, after: retryButton)
        stack.setCustomSpacing(16, after: accountRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            unavailableLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            disclosureLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: PremiumStore.didChange, object: nil)
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Pick up products the launch-time load didn't get (offline, or a
        // product that only became available in App Store Connect since).
        if PremiumStore.shared.products.count < PremiumStore.ProductID.all.count {
            Task { await PremiumStore.shared.loadProducts() }
        }
    }

    // MARK: - State

    @objc private func storeChanged() { refresh() }

    private func refresh() {
        let store = PremiumStore.shared
        let entitled = store.isEntitled
        let products = store.products

        statusLabel.stringValue = entitled
            ? "Premium is active. Weather Aether uses Apple Weather."
            : "Premium is not active. Weather Aether uses Open-Meteo."
        statusLabel.textColor = entitled ? .systemGreen : .labelColor

        buyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !entitled {
            for product in products {
                let button = NSButton(title: buyTitle(for: product), target: self, action: #selector(buy(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(product.id)
                button.bezelStyle = .push
                if product.id == PremiumStore.ProductID.lifetime { button.keyEquivalent = "\r" }
                button.isEnabled = !isBusy
                buyStack.addArrangedSubview(button)
            }
        }
        buyStack.isHidden = entitled || products.isEmpty
        unavailableLabel.isHidden = entitled || !products.isEmpty
        retryButton.isHidden = unavailableLabel.isHidden
        restoreButton.isEnabled = !isBusy
        manageButton.isHidden = !entitled

        // Only describe the subscription when it's actually offered, so the
        // terms always quote its real price.
        if let yearly = products.first(where: { $0.id == PremiumStore.ProductID.yearly }) {
            disclosureLabel.stringValue =
                "Premium Yearly is an auto-renewing subscription. Payment is charged to your " +
                "Apple Account at confirmation of purchase. It renews automatically at \(yearly.displayPrice) " +
                "per year unless cancelled at least 24 hours before the end of the current period. " +
                "Manage or cancel it in your App Store account settings. Premium Lifetime is a " +
                "one-time purchase."
        } else {
            disclosureLabel.stringValue = "Premium Lifetime is a one-time purchase."
        }
    }

    private func buyTitle(for product: Product) -> String {
        if product.id == PremiumStore.ProductID.yearly {
            return "Subscribe Yearly — \(product.displayPrice)/year"
        }
        return "Buy Lifetime — \(product.displayPrice)"
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = NSFont.systemFont(ofSize: 11)
        return button
    }

    // MARK: - Actions

    @objc private func buy(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let product = PremiumStore.shared.products.first(where: { $0.id == id }) else { return }
        setBusy(true)
        Task { @MainActor in
            defer { setBusy(false) }
            do {
                switch try await PremiumStore.shared.purchase(product, from: view.window) {
                case .purchased, .cancelled:
                    break
                case .pending:
                    showAlert("Purchase Pending",
                              "Your purchase is awaiting approval. Premium will unlock automatically once it's approved.")
                }
            } catch {
                showAlert("Purchase Failed", error.localizedDescription)
            }
        }
    }

    @objc private func restorePurchases() {
        setBusy(true)
        Task { @MainActor in
            defer { setBusy(false) }
            do {
                try await PremiumStore.shared.restore()
                if !PremiumStore.shared.isEntitled {
                    showAlert("No Purchases Found",
                              "There's no ÆtherDesk Premium purchase on this Apple Account.")
                }
            } catch StoreKitError.userCancelled {
                // The user dismissed the App Store sign-in; nothing to report.
            } catch {
                showAlert("Restore Failed", error.localizedDescription)
            }
        }
    }

    @objc private func retryLoad() {
        Task { await PremiumStore.shared.loadProducts() }
    }

    @objc private func manageSubscription() { NSWorkspace.shared.open(Self.manageSubscriptionsURL) }
    @objc private func openTerms() { NSWorkspace.shared.open(Self.termsURL) }
    @objc private func openPrivacy() { NSWorkspace.shared.open(Self.privacyURL) }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        refresh()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
#endif
