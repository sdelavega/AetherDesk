# AetherDesk Optimization Profile

## High Priority

### 1. Property Update Batching (CPU/JS Bridge)
**Files:** `PropertyBridge.swift:62-81`
**Issue:** Every slider adjustment fires a separate `evaluateJavaScript()` call — full IIFE construction, JSON encoding, and WebKit bridge round-trip. With 4+ properties changing simultaneously, this is 4+ JS evals per frame.
**Fix:** Collect updates for ~100ms, then send a single batched JS eval. Expected: **90% fewer JS bridge calls** when multiple properties change.

### 2. WKWebView Configuration (GPU)
**Files:** `WebWallpaperRuntime.swift:58-94`
**Issue:** No explicit GPU optimization on `WKWebViewConfiguration`. Missing security/perf flags. No native-side FPS cap enforcement — relies entirely on wallpaper JS.
**Fix:**
- `config.preferences.isElementFullscreenEnabled = false`
- Inject a JS shim enforcing fpsCap via `requestAnimationFrame` throttling
- Disable clipboard, media autoplay, element fullscreen
- Expected: **20-40% GPU power reduction** on web wallpapers.

### 3. WKWebView Deallocation on Stop (Memory)
**Files:** `WebWallpaperRuntime.swift:133-137`
**Issue:** `stop()` hides the webView but the JS VM and layout trees remain in memory until dealloc.
**Fix:** After `loadHTMLString("", baseURL: nil)`, nil out the webView. Create lazily on next `start()`. Expected: **50-100 MB freed per wallpaper switch**.

### 4. Per-Display WKWebView Instances (Memory, Multi-Display)
**Files:** `WallpaperManager.swift:20-22`
**Issue:** Each display gets its own full WebKit VM + JS context. 4 displays = 4 VMs = 500 MB+.
**Fix (short-term):** Memory monitor that pauses secondary displays if usage exceeds threshold.
**Fix (long-term):** Shared offscreen WKWebView with per-display snapshots. Expected: **300-500 MB savings** on 4-display systems.

### 5. Defer Startup I/O (Startup)
**Files:** `AppDelegate.swift:21-24`, `WallpaperManager.swift:30,44`
**Issue:** On launch, wallpaper directory scans and display list updates happen synchronously on the main thread before any UI appears. `DisplayManager.updateDisplayList()` is called multiple times.
**Fix:** Show menu bar icon immediately. Move `listWallpapers()` to a background queue. Call `updateDisplayList()` once in init, re-scan only on display config change notification. Expected: **~500ms faster startup**.

---

## Medium Priority

### 6. PropertyStore/WallpaperStore Caching (I/O)
**Files:** `PropertyStore.swift:8-37`, `WallpaperStore.swift:32-69`
**Issue:** Every single property save loads the entire JSON dict from UserDefaults, modifies it, re-encodes, and writes back. Same for display assignments.
**Fix:** Cache decoded dictionaries in memory. Use debounced writes (flush after 100ms of no changes).

### 7. Menu Rebuild Caching (CPU)
**Files:** `MenuBarController.swift:212-218`
**Issue:** Every menu open triggers `listWallpapers()` (full directory scan) and rebuilds all menu items.
**Fix:** Cache the submenu. Rebuild only when `wallpaperDidChange` fires. Use a "Loading..." placeholder if async scan isn't ready.

### 8. Watchdog Heartbeat Interval (Energy)
**Files:** `Constants.swift:14`, `WebWallpaperRuntime.swift:184-191`
**Issue:** 2-second heartbeat forces JS event loop wakeup every 2s even when idle. With a 30s timeout, this is overly aggressive.
**Fix:** Increase to 5-10s. Pause entirely during low-power mode or display sleep.

### 9. Thumbnail Cache Validation (I/O)
**Files:** `ThumbnailRenderer.swift:85-103`
**Issue:** Every thumbnail load does 3 filesystem calls (exists, cache mtime, bundle mtime) even for cache hits.
**Fix:** Cache bundle modification dates in memory for the session. Only recompute on FSEvents or explicit invalidation.

### 10. Battery-Aware Throttling (Energy)
**Files:** `AppDelegate.swift:243-253`
**Issue:** Respects low-power mode and thermal state but doesn't detect battery vs plugged-in.
**Fix:** Monitor power source via IOKit. Auto-reduce FPS and pause secondary displays on battery.

### 11. Thumbnail WebView Pool (Memory)
**Files:** `ThumbnailRenderer.swift:210-292`
**Issue:** Each thumbnail render creates a new offscreen WKWebView. Rapid scrolling in the picker can spike to multiple simultaneous VMs.
**Fix:** Pool of 2-3 reusable offscreen WKWebViews. Expected: **200-300 MB lower peak** during bulk thumbnail generation.

### 12. Web Wallpapers Continue During Pause (Energy)
**Files:** `WebWallpaperRuntime.swift:111-121`
**Issue:** `pause()` hides the view and sends a visibility notification, but if the wallpaper ignores it, JS timers and animations keep running.
**Fix:** Inject a JS shim on pause that suspends all setTimeout/setInterval timers. Resume on unpause.

---

## Low Priority

### 13. NSScreen.screens Cached per Runtime (CPU)
**Files:** `PropertyBridge.swift:86-91`
Cache the NSScreen reference at runtime init instead of querying `NSScreen.screens` on every `injectEnvironment()`.

### 14. Thumbnail Disk Cache Pruning (I/O)
**Files:** `ThumbnailRenderer.swift:36-42`
Orphaned caches for deleted bundles accumulate. Add once-per-launch pruning.

### 15. DisplayManager Single-Pass (CPU)
**Files:** `DisplayManager.swift:13-36`
Collapse the fallback logic into a single `NSScreen.screens` iteration instead of multiple passes.

### 16. Notification Deduplication (CPU)
**Files:** `PreferencesWindowController.swift:321-323`
Skip `updateProperty` notification if the same (key, value) is already set on a display.

### 17. Snapshot afterScreenUpdates (GPU)
**Files:** `ThumbnailRenderer.swift:268-279`
Change `afterScreenUpdates` to `false` for thumbnail snapshots — previous-frame quality is acceptable.

---

## Summary Table

| # | Category | Impact | Estimated Gain |
|---|----------|--------|----------------|
| 1 | JS bridge batching | HIGH | -90% JS evals |
| 2 | WKWebView GPU config | HIGH | -20-40% GPU |
| 3 | WebView dealloc on stop | HIGH | -50-100 MB/switch |
| 4 | Multi-display WebViews | HIGH | -300-500 MB (4 displays) |
| 5 | Defer startup I/O | HIGH | -500ms launch |
| 6 | Store caching | MEDIUM | -15% UserDefaults I/O |
| 7 | Menu rebuild cache | MEDIUM | -80% main thread blocks |
| 8 | Watchdog interval | MEDIUM | -50-80% JS wakeups |
| 9 | Thumbnail mtime cache | MEDIUM | -60% file I/O |
| 10 | Battery throttling | MEDIUM | -5-10% battery |
| 11 | Thumbnail WebView pool | MEDIUM | -200-300 MB peak |
| 12 | Pause JS suspension | MEDIUM | CPU savings on pause |
| 13-17 | Various low-priority | LOW | Incremental gains |
