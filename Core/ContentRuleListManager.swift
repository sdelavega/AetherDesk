import WebKit
import Foundation

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
    /// failed — non-fatal; WebViews load without content filtering.
    private(set) var ruleList: WKContentRuleList?

    private static let storeIdentifier = "com.aetherdesk.WallpaperBlocklist.v1"

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

    // MARK: - Lifecycle

    private init() {}

    /// Loads the compiled rule list from WKContentRuleListStore (cache hit on
    /// subsequent launches) or compiles from the embedded JSON on first run.
    /// Always calls `completion` on the main queue, even on failure.
    func prepare(completion: @escaping () -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            NSLog("ÆtherDesk: WKContentRuleListStore unavailable — skipping content filtering")
            completion()
            return
        }
        store.lookUpContentRuleList(forIdentifier: Self.storeIdentifier) { [weak self] list, _ in
            if let list {
                // Cache hit — ready immediately.
                self?.ruleList = list
                NSLog("ÆtherDesk: content rule list loaded from cache")
                DispatchQueue.main.async { completion() }
                return
            }
            // Not cached — compile. WKContentRuleListStore persists the
            // compiled result to disk automatically.
            NSLog("ÆtherDesk: compiling content rule list…")
            store.compileContentRuleList(
                forIdentifier: Self.storeIdentifier,
                encodedContentRuleList: Self.blocklistJSON
            ) { [weak self] compiled, error in
                if let error {
                    NSLog("ÆtherDesk: content rule list compilation failed: %@",
                          error.localizedDescription)
                } else {
                    self?.ruleList = compiled
                    NSLog("ÆtherDesk: content rule list compiled and cached")
                }
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
