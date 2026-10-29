// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega.
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

import Testing
import AppKit
import StoreKit
import StoreKitTest

/// Drives PremiumStore against AetherDesk.storekit through StoreKit Test.
/// StoreKit needs a real app process, so this target is hosted by the App
/// Store build of the app. Serialized: an SKTestSession is process-wide state.
@Suite("PremiumStore", .serialized) @MainActor
final class PremiumStoreTests {

    let session: SKTestSession
    let defaults: UserDefaults
    let store: PremiumStore

    init() throws {
        let url = try #require(Bundle(for: Self.self).url(forResource: "AetherDesk", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defaults = UserDefaults(suiteName: "AetherDeskStoreTests.\(UUID().uuidString)")!
        store = PremiumStore(userDefaults: defaults)
    }

    deinit {
        session.clearTransactions()
    }

    @Test func loadsBothProductsLifetimeFirst() async {
        await store.loadProducts()
        #expect(store.products.map(\.id) == [PremiumStore.ProductID.lifetime, PremiumStore.ProductID.yearly])
        let yearly = store.products.last
        #expect(yearly?.type == .autoRenewable)
        #expect(yearly?.subscription?.subscriptionPeriod.unit == .year)
        #expect(store.products.first?.type == .nonConsumable)
    }

    @Test func notEntitledWithoutPurchase() async {
        await store.refreshEntitlement()
        #expect(!store.isEntitled)
    }

    @Test func lifetimePurchaseThroughPurchaseFlowEntitles() async throws {
        await store.loadProducts()
        let lifetime = try #require(store.products.first { $0.id == PremiumStore.ProductID.lifetime })
        // macOS 15.2+ requires a window to anchor the purchase confirmation.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns this window; closing must not release it a second time.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let outcome = try await store.purchase(lifetime, from: window)
        #expect(outcome == .purchased)
        #expect(store.isEntitled)
    }

    @Test func yearlySubscriptionArrivingOnUpdatesEntitles() async throws {
        // A purchase made outside the app (another device, Ask to Buy
        // approval) reaches us only through Transaction.updates.
        store.start()
        _ = try await session.buyProduct(identifier: PremiumStore.ProductID.yearly)
        #expect(await waitUntil { self.store.isEntitled })
    }

    // Refunds and expiry: SKTestSession.refundTransaction / expireSubscription
    // report success but change nothing in a hosted command-line test run
    // (verified: no update is emitted and latest(for:) is unchanged), so the
    // rule they feed is tested on plain values. Exercise the live path with
    // Xcode > Debug > StoreKit > Manage Transactions.

    @Test func lifetimeGrants() {
        #expect(PremiumStore.grantsPremium(productID: PremiumStore.ProductID.lifetime,
                                           revocationDate: nil, expirationDate: nil))
    }

    @Test func refundedLifetimeDoesNotGrant() {
        #expect(!PremiumStore.grantsPremium(productID: PremiumStore.ProductID.lifetime,
                                            revocationDate: Date(), expirationDate: nil))
    }

    @Test func activeSubscriptionGrants() {
        let now = Date()
        #expect(PremiumStore.grantsPremium(productID: PremiumStore.ProductID.yearly,
                                           revocationDate: nil,
                                           expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    @Test func expiredSubscriptionDoesNotGrant() {
        let now = Date()
        #expect(!PremiumStore.grantsPremium(productID: PremiumStore.ProductID.yearly,
                                            revocationDate: nil,
                                            expirationDate: now.addingTimeInterval(-1), now: now))
    }

    @Test func refundedSubscriptionDoesNotGrant() {
        let now = Date()
        #expect(!PremiumStore.grantsPremium(productID: PremiumStore.ProductID.yearly,
                                            revocationDate: now,
                                            expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    @Test func unrelatedProductDoesNotGrant() {
        #expect(!PremiumStore.grantsPremium(productID: "com.sdelavega.AetherDesk.tip",
                                            revocationDate: nil, expirationDate: nil))
    }

    @Test func entitlementHintSurvivesRelaunchUntilVerified() async throws {
        _ = try await session.buyProduct(identifier: PremiumStore.ProductID.lifetime)
        await store.refreshEntitlement()

        // A fresh instance (next launch) starts from the persisted hint...
        let relaunched = PremiumStore(userDefaults: defaults)
        #expect(relaunched.isEntitled)

        // ...and the verified answer replaces it once StoreKit responds.
        session.clearTransactions()
        await relaunched.refreshEntitlement()
        #expect(!relaunched.isEntitled)
        #expect(!PremiumStore(userDefaults: defaults).isEntitled)
    }

    @Test func entitlementChangePostsNotification() async throws {
        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: PremiumStore.didChange, object: store, queue: .main) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await session.buyProduct(identifier: PremiumStore.ProductID.lifetime)
        await store.refreshEntitlement()
        // didChange is delivered asynchronously on the main queue.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(posted == 1)
    }

    @Test func premiumLegalLinksStayInsideClickableTabArea() async throws {
        // Use real StoreKit prices and the same tab geometry as Preferences:
        // a 720×520 content view, 16 pt tab margins, then NSTabView.contentRect.
        await PremiumStore.shared.loadProducts()
        await PremiumStore.shared.refreshEntitlement()
        #expect(PremiumStore.shared.products.count == 2)
        #expect(!PremiumStore.shared.isEntitled)

        for size in [NSSize(width: 720, height: 520), NSSize(width: 600, height: 378)] {
            let controller = PremiumViewController()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            let root = try #require(window.contentView)
            let tabs = NSTabView(frame: root.bounds.insetBy(dx: 16, dy: 16))
            root.addSubview(tabs)
            let item = NSTabViewItem(identifier: "premium")
            item.label = "Premium"
            item.view = controller.view
            tabs.addTabViewItem(item)
            tabs.selectTabViewItem(item)
            root.layoutSubtreeIfNeeded()

            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { descendants($0) }
            }
            let controls = descendants(controller.view)
            let legalLinks = controls.compactMap { $0 as? NSButton }.filter {
                $0.title == "Terms of Use (EULA)" || $0.title == "Privacy Policy"
            }
            #expect(legalLinks.count == 2)
            let scroll = try #require(controls.compactMap { $0 as? NSScrollView }.first)
            let document = try #require(scroll.documentView)
            #expect(document.isFlipped)
            #expect(!scroll.hasHorizontalScroller)
            #expect(controller.view.bounds.contains(scroll.frame))
            let disclosure = try #require(controls.compactMap { $0 as? NSTextField }.first {
                $0.stringValue.hasPrefix("Premium Yearly is an auto-renewing")
            })
            let originalDisclosure = disclosure.stringValue

            for longText in [false, true] {
                if longText {
                    disclosure.stringValue = Array(repeating: originalDisclosure, count: 8).joined(separator: " ")
                    // A long localized title/price must stay within the form width.
                    for button in controls.compactMap({ $0 as? NSButton })
                    where button.identifier?.rawValue == PremiumStore.ProductID.yearly {
                        button.title = Array(repeating: "Subscribe Yearly — 1.234.567,89 € / year", count: 3).joined(separator: " ")
                    }
                }
                root.layoutSubtreeIfNeeded()
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                #expect(disclosure.bounds.height > disclosure.font!.pointSize)
                if longText {
                    #expect(document.bounds.height > scroll.contentView.bounds.height)
                }

                // Every visible control remains reachable after scrolling, even
                // when its row starts below the viewport. In particular, drawing
                // a legal button outside an ancestor's bounds must never pass.
                for control in controls where (control is NSButton || control is NSTextField)
                    && !control.isHiddenOrHasHiddenAncestor {
                    control.scrollToVisible(control.bounds)
                    root.layoutSubtreeIfNeeded()
                    let inDocument = control.convert(control.bounds, to: document)
                    #expect(document.bounds.contains(inDocument))
                    if control is NSButton {
                        let inView = control.convert(control.bounds, to: controller.view)
                        #expect(controller.view.bounds.contains(inView))
                    }
                }
                for button in legalLinks {
                    #expect(button.target === controller)
                    let expectedAction = button.title == "Privacy Policy" ? "openPrivacy" : "openTerms"
                    #expect(button.action == NSSelectorFromString(expectedAction))
                    #expect(controller.responds(to: try #require(button.action)))
                    #expect(button.contentTintColor == NSColor.linkColor)
                    button.scrollToVisible(button.bounds.insetBy(dx: -4, dy: -4))
                    root.layoutSubtreeIfNeeded()
                    #expect(scroll.documentVisibleRect.contains(button.convert(button.bounds, to: document)))
                    let frame = button.convert(button.bounds, to: controller.view)
                    #expect(controller.view.bounds.contains(frame))
                    let centre = NSPoint(x: frame.midX, y: frame.midY)
                    let hitPoint = controller.view.convert(centre, to: controller.view.superview)
                    #expect(controller.view.hitTest(hitPoint) === button)
                }
                if !longText && size.width == 720 {
                    root.wantsLayer = true
                    window.orderFront(nil)
                    // Let AppKit commit the layer-backed labels before caching.
                    try await Task.sleep(nanoseconds: 100_000_000)
                    window.display()
                    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                    try #require(root.layer).render(in: context.cgContext)
                    let image = NSImage(size: root.bounds.size)
                    image.addRepresentation(bitmap)
                    Attachment.record(image, named: "premium-fixed.png", as: .png)
                }
            }
        }
    }

    /// Polls `condition` until it holds or `timeout` passes. Entitlement
    /// changes arrive asynchronously from StoreKit.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
