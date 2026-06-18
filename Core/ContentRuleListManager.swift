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

import WebKit
import Foundation
import os.log

/// Compiles and caches a WKContentRuleList that blocks known ad networks,
/// analytics trackers, and crypto miners from loading in wallpaper WebViews.
///
/// Call `prepare(completion:)` once at app launch before any WebView is
/// created. On subsequent launches the compiled list is loaded from
/// WKContentRuleListStore's disk cache — typically a few milliseconds. On
/// first launch it compiles from the embedded JSON.
///
/// To update the blocklist in a future release, bump `storeIdentifier` to v2
/// (or v3, etc.) so the new rules are compiled fresh and the old cached list
/// is superseded.
final class ContentRuleListManager {

    static let shared = ContentRuleListManager()

    /// Available after `prepare(completion:)` fires. Nil only when compilation
    /// failed — non-fatal; WebViews load without this content filtering.
    private(set) var ruleList: WKContentRuleList?
    private(set) var externalNetworkBlockRuleList: WKContentRuleList?
    private(set) var rawIPWebSocketRuleList: WKContentRuleList?
    private(set) var ssrfBlockRuleList: WKContentRuleList?

    private static let blocklistStoreIdentifier = "com.sdelavega.WallpaperBlocklist.v1"
    private static let externalNetworkStoreIdentifier = "com.sdelavega.ExternalNetworkBlock.v1"
    private static let rawIPWebSocketStoreIdentifier = "com.sdelavega.RawIPWebSocketBlock.v1"
    private static let ssrfBlockStoreIdentifier = "com.sdelavega.SSRFBlock.v1"

    // MARK: - Blocklist

    /// WebKit content blocker JSON (ICU regex url-filter).
    /// Covers ad/tracking networks and crypto miners.
    /// file:// resources are never matched by these domain patterns, so
    /// wallpaper local assets are always allowed through.
    private static let blocklistJSON = #"""
    [
      { "trigger": { "url-filter": ".*\\.google-analytics\\.com.*"   }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*analytics\\.google\\.com.*"    }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.googletagmanager\\.com.*"   }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.googletagservices\\.com.*"  }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.doubleclick\\.net.*"        }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.googleadservices\\.com.*"   }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.googlesyndication\\.com.*"  }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.adservice\\.google\\.com.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.adnxs\\.com.*"             }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.connect\\.facebook\\.net.*" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.facebook\\.net.*"           }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.hotjar\\.com.*"             }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.mixpanel\\.com.*"           }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.segment\\.io.*"             }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*api\\.segment\\.com.*"         }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.amplitude\\.com.*"          }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.sentry\\.io.*"              }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*\\.bugsnag\\.com.*"            }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*coinhive\\.com.*"              }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*crypto-loot\\.com.*"           }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*minero\\.cc.*"                 }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*jsecoin\\.com.*"               }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*monerominer\\.rocks.*"         }, "action": { "type": "block" } },
      { "trigger": { "url-filter": ".*webmr\\.eu.*"                  }, "action": { "type": "block" } }
    ]
    """#

    private static let externalNetworkBlockJSON = #"""
    [
      {
        "trigger": { "url-filter": "^https?://.*" },
        "action": { "type": "block" }
      }
    ]
    """#

    /// Blocks WebSocket (ws:// and wss://) connections to raw IPv4 and IPv6
    /// addresses. FQDN WebSocket connections are allowed through.
    private static let rawIPWebSocketBlockJSON = #"""
    [
      {
        "trigger": { "url-filter": "^wss?://\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://\\[" },
        "action": { "type": "block" }
      }
    ]
    """#

    /// Always-on SSRF defense for page-initiated subresource loads (img,
    /// script, stylesheet, XHR/fetch from the page itself). The native
    /// NetworkPolicy covers fetch/navigation/WebSocket that flow through our
    /// JS bridge, but subresources loaded directly by the page bypass it.
    ///
    /// Blocks:
    ///   - Raw IPv4 and IPv6 in http(s):// URLs (covers private ranges,
    ///     loopback, link-local, and cloud metadata IPs like 169.254.169.254)
    ///   - `localhost` and `*.localhost`
    ///   - `*.local` (mDNS — can resolve to arbitrary LAN devices)
    ///   - Cloud metadata hostnames (metadata.google.internal,
    ///     metadata.azure.com, 169.254.169.254.nip.io, etc.)
    private static let ssrfBlockJSON = #"""
    [
      { "trigger": { "url-filter": "^https?://\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://\\[" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://[^/]*localhost([/:]|$)" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://[^/]*\\.localhost([/:]|$)" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://[^/]*\\.local([/:]|$)" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://metadata\\.google\\.internal" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://metadata\\.azure\\.com" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://[^/]*\\.nip\\.io" }, "action": { "type": "block" } },
      { "trigger": { "url-filter": "^https?://[^/]*\\.sslip\\.io" }, "action": { "type": "block" } }
    ]
    """#

    // MARK: - Lifecycle

    private init() {}

    /// Loads the compiled rule list from WKContentRuleListStore (cache hit on
    /// subsequent launches) or compiles from the embedded JSON on first run.
    /// Always calls `completion` on the main queue, even on failure.
    func prepare(completion: @escaping () -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            Logger.app.info("ÆtherDesk: WKContentRuleListStore unavailable — skipping content filtering")
            completion()
            return
        }

        // The three rule lists are independent — compile/load them concurrently.
        let group = DispatchGroup()

        group.enter()
        compileOrLoadRuleList(store: store,
                              identifier: Self.blocklistStoreIdentifier,
                              encodedRuleList: Self.blocklistJSON,
                              label: "content blocklist") { [weak self] list in
            DispatchQueue.main.async {
                self?.ruleList = list
            }
            group.leave()
        }

        group.enter()
        compileOrLoadRuleList(store: store,
                              identifier: Self.externalNetworkStoreIdentifier,
                              encodedRuleList: Self.externalNetworkBlockJSON,
                              label: "external network blocklist") { [weak self] list in
            DispatchQueue.main.async {
                self?.externalNetworkBlockRuleList = list
            }
            group.leave()
        }

        group.enter()
        compileOrLoadRuleList(store: store,
                              identifier: Self.rawIPWebSocketStoreIdentifier,
                              encodedRuleList: Self.rawIPWebSocketBlockJSON,
                              label: "raw-IP WebSocket blocklist") { [weak self] list in
            DispatchQueue.main.async {
                self?.rawIPWebSocketRuleList = list
            }
            group.leave()
        }

        group.enter()
        compileOrLoadRuleList(store: store,
                              identifier: Self.ssrfBlockStoreIdentifier,
                              encodedRuleList: Self.ssrfBlockJSON,
                              label: "SSRF subresource blocklist") { [weak self] list in
            DispatchQueue.main.async {
                self?.ssrfBlockRuleList = list
            }
            group.leave()
        }

        group.notify(queue: .main) { completion() }
    }

    private func compileOrLoadRuleList(store: WKContentRuleListStore,
                                       identifier: String,
                                       encodedRuleList: String,
                                       label: String,
                                       completion: @escaping (WKContentRuleList?) -> Void) {
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                // Cache hit — ready immediately.
                Logger.app.info("ÆtherDesk: \(label) loaded from cache")
                completion(list)
                return
            }
            // Not cached — compile. WKContentRuleListStore persists the
            // compiled result to disk automatically.
            Logger.app.info("ÆtherDesk: compiling \(label)…")
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRuleList
            ) { compiled, error in
                if let error {
                    Logger.app.error("ÆtherDesk: \(label) compilation failed: \(error.localizedDescription)")
                } else {
                    Logger.app.info("ÆtherDesk: \(label) compiled and cached")
                }
                completion(compiled)
            }
        }
    }
}
