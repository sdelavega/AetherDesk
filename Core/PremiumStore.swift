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
import os.log

/// ÆtherDesk Premium: the in-app purchase that unlocks Apple Weather
/// (WeatherKit) for WeatherAether in App Store builds. Users without it get
/// Open-Meteo, which needs no purchase.
///
/// One entitlement, two products — a lifetime non-consumable and a yearly
/// auto-renewing subscription. Owning either unlocks Premium. Entitlement is
/// derived only from StoreKit-verified transactions (see `refreshEntitlement`);
/// refunds and renewals arrive on `Transaction.updates`.
///
/// Only compiled in `AETHERDESK_STORE` builds; the OSS build has no WeatherKit
/// and nothing to sell.
final class PremiumStore {

    static let shared = PremiumStore()

    /// Posted on the main queue whenever `isEntitled` or `products` change.
    static let didChange = Notification.Name("ÆtherDesk.premiumStoreDidChange")

    enum ProductID {
        static let lifetime = "com.sdelavega.AetherDesk.premium"
        static let yearly   = "com.sdelavega.AetherDesk.premium.yearly"
        static let all: Set<String> = [lifetime, yearly]
    }

    enum PurchaseOutcome {
        case purchased
        case pending        // Ask to Buy / SCA — completes later via Transaction.updates
        case cancelled
    }

    /// Products as returned by the App Store, lifetime first. Empty until
    /// `loadProducts()` finishes, or when the products aren't available
    /// (offline, or not yet approved in App Store Connect).
    private(set) var products: [Product] = []

    /// Readable from any thread — `WeatherKitBridge` checks it per forecast.
    var isEntitled: Bool {
        lock.withLock { entitled }
    }

    private let lock = NSLock()
    private var entitled: Bool
    private var updatesTask: Task<Void, Never>?
    private let userDefaults: UserDefaults

    /// Last known entitlement, so a paying user's first forecast after launch
    /// uses WeatherKit before StoreKit has answered. Only a hint: `start()`
    /// immediately replaces it with the verified answer.
    private let entitlementHintKey = "AetherDesk.premiumEntitlementHint.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.entitled = userDefaults.bool(forKey: entitlementHintKey)
    }

    // MARK: - Lifecycle

    /// Call once at launch. Starts listening for transactions made outside
    /// the app (renewals, refunds, Ask to Buy approvals, other devices),
    /// finishes any left unfinished, and refreshes entitlement and products.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached(priority: .utility) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task {
            for await result in Transaction.unfinished {
                await handle(result)
            }
            await refreshEntitlement()
            await loadProducts()
        }
    }

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: ProductID.all)
            let sorted = loaded.sorted { lhs, _ in lhs.id == ProductID.lifetime }
            await MainActor.run {
                self.products = sorted
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
            if loaded.isEmpty {
                Logger.app.warning("ÆtherDesk PremiumStore: App Store returned no products")
            }
        } catch {
            Logger.app.error("ÆtherDesk PremiumStore: product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Purchasing

    /// Presents the App Store purchase sheet. On macOS 15.2+ the sheet must be
    /// anchored to a window — the window-less `purchase()` throws
    /// `invalidPresentationContext` there — so fall back to any visible window
    /// when the caller has none. Earlier systems present it app-modally.
    @MainActor
    func purchase(_ product: Product, from window: NSWindow?) async throws -> PurchaseOutcome {
        let result: Product.PurchaseResult
        if #available(macOS 15.2, *),
           let anchor = window ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            result = try await product.purchase(confirmIn: anchor)
        } else {
            result = try await product.purchase()
        }
        switch result {
        case .success(let verification):
            await handle(verification)
            return isEntitled ? .purchased : .cancelled
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Restore Purchases. Rarely needed with StoreKit 2 (entitlements sync
    /// automatically), but App Review requires the button. Prompts the user
    /// to sign in to the App Store if they aren't.
    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }

    // MARK: - Entitlement

    /// Premium is active when the latest verified transaction for either
    /// product is unrevoked and, for the subscription, unexpired.
    ///
    /// Deliberately `Transaction.latest(for:)` rather than
    /// `currentEntitlements`: the latter omits a purchase until it has been
    /// finished *and* some moments after, so checking it right after a
    /// purchase reported "not entitled" (caught by PremiumStoreTests).
    /// Billing grace periods aren't honored here; enabling them in App Store
    /// Connect would need `Product.SubscriptionInfo.status` checks.
    ///
    /// `delivered` is a transaction StoreKit just handed us (purchase, refund,
    /// renewal, expiry). It's used as-is for its product because
    /// `Transaction.latest(for:)` can briefly still return the previous state.
    func refreshEntitlement(delivered: Transaction? = nil) async {
        var owned = false
        for id in ProductID.all {
            let transaction: Transaction
            if let delivered, delivered.productID == id {
                transaction = delivered
            } else if case .verified(let latest)? = await Transaction.latest(for: id) {
                transaction = latest
            } else {
                continue
            }
            if Self.grantsPremium(transaction) { owned = true }
        }
        setEntitled(owned)
    }

    static func grantsPremium(_ transaction: Transaction, now: Date = Date()) -> Bool {
        grantsPremium(productID: transaction.productID,
                      revocationDate: transaction.revocationDate,
                      expirationDate: transaction.expirationDate,
                      now: now)
    }

    /// The entitlement rule on plain values, so tests can cover refunds and
    /// expiry (StoreKit Test can't reliably produce those from a test).
    static func grantsPremium(productID: String,
                              revocationDate: Date?,
                              expirationDate: Date?,
                              now: Date = Date()) -> Bool {
        guard ProductID.all.contains(productID), revocationDate == nil else { return false }
        if let expirationDate {
            return expirationDate > now
        }
        return true
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            await refreshEntitlement(delivered: transaction)
        case .unverified(let transaction, let error):
            // Never grant on an unverified transaction, but finish it so
            // StoreKit stops redelivering it.
            Logger.app.error("ÆtherDesk PremiumStore: unverified transaction \(transaction.productID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await transaction.finish()
            await refreshEntitlement()
        }
    }

    private func setEntitled(_ value: Bool) {
        let changed: Bool = lock.withLock {
            defer { entitled = value }
            return entitled != value
        }
        userDefaults.set(value, forKey: entitlementHintKey)
        guard changed else { return }
        Logger.app.info("ÆtherDesk PremiumStore: entitlement \(value ? "granted" : "revoked", privacy: .public)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
#endif
