# ÆtherDesk Comprehensive Security & Optimization Audit

Generated: 2026-04-23
Scope: Full source review of the AetherDesk macOS app — all Swift files, entitlements, plists, and bundled resources.
Method: Static code analysis against the current HEAD. No dynamic testing was performed.

---

## Executive Summary

The codebase is in significantly better shape than the baseline described in the original `SECURITY-OPTIMIZATION-AUDIT.md`. Most of the critical and high-severity items from that audit have been implemented: path traversal in the custom scheme handler is blocked, zip-slip is sanitized, update signature verification is enforced, network policy restricts LAN/raw-IP/metadata access, and the property store sanitizes injected values.

That said, a fresh end-to-end review surfaced **new security issues** (synchronous DNS on the main thread, missing response size limits on the native fetch proxy, shell-injection surface in the auto-updater, and several denial-of-service vectors) and **new optimization opportunities** (main-thread directory scans on hot-plug, wasted timer allocations on every resume, and unbounded cache growth).

This document is structured so you can read top-to-bottom by severity and stop when the remaining risk is acceptable.

---

## Security Findings

### Critical

None. The app no longer has any single vulnerability that would allow arbitrary code execution or sandbox escape by an unprivileged attacker.

---

### High

#### ~~S-H01: Synchronous DNS resolution blocks the main thread~~ **FIXED**
**Files:** `Core/NetworkPolicy.swift:178-201`, `WallpaperTypes/WebWallpaperRuntime.swift:275-298`
**Issue:** `performNativeFetch` calls `networkPolicy.validateResolvedAddresses(for:)` on the main thread (it runs inside the `ScriptMessageHandler` callback). That method calls `resolveHost`, which uses `getaddrinfo` synchronously. On a slow or unreachable DNS server this blocks the main thread for multiple seconds, freezing the menu bar and any host-window updates.
**Fix:** `validateResolvedAddresses` is now dispatched to a background queue inside `performNativeFetch`. The result is dispatched back to main for the actual `URLSession` call.

#### ~~S-H02: Native fetch proxy has no response size limit~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:281-290`
**Issue:** `URLSession.shared.dataTask` receives the full response body into memory. A malicious or compromised endpoint can stream an unbounded amount of data, exhausting RAM and potentially crashing the app.
**Fix:** Switched to `URLSessionDownloadTask` with a 5 MB cap (`Constants.Defaults.maxNativeFetchResponseBytes`). The response body is written to a temp file first; the file size is checked before reading into memory.

#### ~~S-H03: No file size cap in BundleSchemeHandler~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:845-865`
**Issue:** The streaming path reads files in 512 KB chunks with no upper bound. A wallpaper bundle can include a multi-gigabyte file (e.g., renamed `.mp4` or raw data) and request it via a relative path. The chunking prevents a single huge `Data` allocation, but WebKit will keep asking for more data, causing sustained high disk I/O and CPU.
**Fix:** Added a 100 MB hard cap (`maxSchemeHandlerFileSize`) in `BundleSchemeHandler`. Requests for files larger than the cap are rejected with `resourceUnavailable`.

#### ~~S-H04: Shell command injection in auto-updater install path~~ **FIXED**
**Files:** `Core/UpdateManager.swift:410-420`
**Issue:** `performInstall` interpolates `currentAppPath`, `newAppPath`, `tempDir.path`, and `pid` directly into a bash script string. If the app is ever installed in a path containing double quotes, backticks, or dollar-sign expressions, the script syntax breaks or becomes injectable. While the current app path is typically `/Applications/AetherDesk.app`, this is a latent vulnerability.
**Fix:** The shell script is gone. The app now relaunches itself with `--aetherdesk-updater <pid> <oldAppPath> <newAppPath> <tempDir>`. `main.swift` detects this flag and performs the swap via `FileManager` APIs. Zero string interpolation, zero shell involvement.

#### ~~S-H05: Update zip is not integrity-checked before extraction~~ **FIXED**
**Files:** `Core/UpdateManager.swift:380-407`
**Issue:** After downloading the zip, `ditto` extracts it immediately. There is no checksum or signature verification of the archive itself—only the extracted `.app` is verified afterwards. A corrupted or maliciously crafted zip could exploit vulnerabilities in `ditto` or libarchive before the code-signature check runs.
**Fix:** The updater now downloads the `.sha256` sidecar alongside the zip (if published in the release). It verifies the zip's SHA-256 hash before running `ditto`. The entire install flow uses `defer` to guarantee `tempDir` cleanup even on early-exit failure paths.

#### ~~S-H06: Wallpaper can override the native FPS cap in JavaScript~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:462-479`
**Issue:** The `requestAnimationFrame` throttle reads `window.aetherDesk.system.fpsCap` at runtime. A wallpaper can simply reassign that property to 60 (or 120) and bypass the cap entirely. The native side never re-injects the cap after startup.
**Fix:** The JS bridge bootstrap now defines `fpsCap` via `Object.defineProperty` with `writable: false, configurable: false`. Wallpaper JS can no longer override the native FPS cap.

#### ~~S-H07: `javascript:` navigation is not explicitly blocked~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:653-663`
**Issue:** `shouldAllowNavigation` falls through to `default: return false` for unknown schemes, which does block `javascript:` URLs in practice. However, relying on a negative default is brittle—an explicit `case "javascript": return false` is safer and self-documenting.
**Fix:** Added an explicit `case "javascript": return false` to the switch.

---

### Medium

#### ~~S-M01: Main-thread directory scan on display hot-plug~~ **FIXED**
**Files:** `Core/WallpaperManager.swift:345`
**Issue:** When a new display is connected, `displayConfigurationDidChange` calls `WallpaperImporter.shared.listWallpapers()` on the main thread. This enumerates directories and parses JSON for every bundle. On systems with many imported wallpapers this causes a visible UI hitch.
**Fix:** `displayConfigurationDidChange` now dispatches the directory scan to a background queue and applies the wallpaper assignment on main.

#### ~~S-M02: Unbounded domain log growth in NetworkPolicy~~ **FIXED**
**Files:** `Core/NetworkPolicy.swift:31-32, 91-102`
**Issue:** `domainLogs` is a static `[UUID: Set<String>]` that accumulates every unique domain contacted by every wallpaper, forever. There is no eviction, pruning, or size cap. Over a long session with many wallpapers this grows without bound.
**Fix:** Domain logs now use an ordered array capped at 100 entries per bundle with FIFO eviction.

#### ~~S-M03: No rate limiting on the native fetch bridge~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:269-299`
**Issue:** The JS-side network budget (`networkBudgetPerMinute`) is enforced in the injected shim, but a wallpaper could bypass it by calling the native bridge directly via `webkit.messageHandlers.aetherDesk.postMessage({action:"nativeFetch"...})`. The native `performNativeFetch` does not enforce its own rate limit.
**Fix:** `WebWallpaperRuntime` now enforces the same per-minute network budget on the native fetch path via `consumeNativeFetchBudget()`.

#### ~~S-M04: Geolocation permissions are not cleaned up when a wallpaper is deleted~~ **FIXED**
**Files:** `Persistence/GeolocationPermissionStore.swift`, `Import/WallpaperImporter.swift:146-161`
**Issue:** `deleteWallpaper` removes the bundle from disk and deletes its runtime policy, but `GeolocationPermissionStore` and `PropertyStore` entries are never purged. Over time the UserDefaults payload accumulates orphaned keys.
**Fix:** `deleteWallpaper` now also calls `GeolocationPermissionStore.shared.delete(for:)` and `PropertyStore.shared.delete(for:)`.

#### ~~S-M05: No pruning of thumbnail disk cache~~ **FIXED**
**Files:** `Core/ThumbnailRenderer.swift:22-54`
**Issue:** Thumbnails are written to `~/Library/Caches/.../thumbnails/` but never deleted. If the user imports and deletes many wallpapers, orphaned PNGs accumulate indefinitely.
**Fix:** `ThumbnailRenderer` now calls `pruneOrphanedCache()` at init, deleting any PNG whose bundle UUID no longer matches an installed wallpaper.

#### ~~S-M06: `UpdateManager.state` is not thread-safe~~ **FIXED**
**Files:** `Core/UpdateManager.swift:65, 120-150, 222-270`
**Issue:** `state` is a `var` read and written from both the background `queue` and the main queue without a lock or atomic operations. Race conditions could cause duplicate downloads, missed UI updates, or inconsistent state reporting.
**Fix:** `UpdateManager.state` is now guarded by an `NSLock` with private `setState(_:)` and `currentState` accessors.

#### ~~S-M07: Update temporary directories not always cleaned up on failure~~ **FIXED**
**Files:** `Core/UpdateManager.swift:354-442`
**Issue:** Several early-exit paths in `performInstall` (e.g., `ditto` failure, `.app` not found) do not remove `tempDir`. The stable download URL is moved into `tempDir` and would be orphaned.
**Fix:** Resolved by the S-H04/S-H05 refactor: `performInstall` now uses `defer` to guarantee `tempDir` and the downloaded zip are always removed.

#### ~~S-M08: `NSAlert.runModal()` blocks the main thread during geolocation consent~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:728-747`
**Issue:** `LocationProxy.promptForConsent` displays an alert modally. If multiple wallpapers request geolocation simultaneously, the alerts stack and block all user interaction until dismissed.
**Fix:** `LocationProxy` now maintains a static per-bundle queue. If a wallpaper requests geolocation while its consent alert is already showing, the new request ID is queued and resolved with the same answer when the alert closes.

#### ~~S-M09: `MenuBarController` wallpaper import is not serialized~~ **FIXED**
**Files:** `UI/MenuBarController.swift:273-307`
**Issue:** The user can trigger the import panel, dismiss it, and trigger it again rapidly. Each import runs asynchronously on a background queue with no mutex. Concurrent imports of the same source could race on filesystem operations.
**Fix:** Added an `isImporting` flag to `MenuBarController` to prevent concurrent imports.

#### ~~S-M10: Subdomain stripping is incorrect for multi-part TLDs~~ **FIXED**
**Files:** `Core/NetworkPolicy.swift:104-110`
**Issue:** `stripSubdomain` takes the last two dot-separated components. For `api.example.co.uk` this returns `co.uk`, which is not useful for domain logging.
**Fix:** Dropped subdomain stripping entirely. `NetworkPolicy` now logs full hostnames, giving users more granular visibility into which domains wallpapers contact.

#### ~~S-M11: `Info.plist` lacks `NSAppTransportSecurity` policy~~ **FIXED**
**Files:** `Resources/Info.plist`
**Issue:** The plist does not define an `NSAppTransportSecurity` dictionary. By default ATS is enabled, which is good, but there is no explicit enforcement. Because the app is unsandboxed and uses `URLSession.shared`, this is acceptable, but an explicit `NSAllowsArbitraryLoads = false` would document the intent.
**Fix:** Added `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = false`.

---

### Low

#### S-L01: No App Sandbox enabled
**Files:** `Resources/AetherDesk.entitlements`
**Issue:** The entitlements file is an empty dict. The app has unrestricted filesystem and network access. `SandboxSupport` scaffolding exists but is inert.
**Fix:** Enable App Sandbox in v1.1 as previously planned. This is marked low because it is a known deferred decision with scaffolding in place.
**Risk:** Broad attack surface; mitigated by the other controls in this audit.

#### ~~S-L02: `WatchdogTimer.start()` allocates a new `DispatchSourceTimer` on every resume~~ **FIXED**
**Files:** `Core/WatchdogTimer.swift:40-58`, `WallpaperTypes/WebWallpaperRuntime.swift:241`
**Issue:** `resume()` calls `watchdog.start()`, which cancels the old source and allocates a new one. This is wasteful and slightly increases the chance of a race between cancellation and the new timer.
**Fix:** `WatchdogTimer.start()` now checks `isArmed` and reschedules the existing source instead of cancelling and recreating it.

#### ~~S-L03: `WallpaperBundle` JSON parsing is not cached across listings~~ **FIXED**
**Files:** `Import/WallpaperBundle.swift:27-78`, `Import/WallpaperImporter.swift:106-113`
**Issue:** Every call to `listWallpapers()` (after a cache invalidation) re-parses `LivelyInfo.json` and `LivelyProperties.json` for every bundle. With 20+ bundles this is noticeable.
**Fix:** `LivelyInfoParser` and `LivelyPropertiesParser` now maintain a static cache keyed by file URL and modification date. Repeated listings skip JSON decoding when the files haven't changed.

#### ~~S-L04: Content rule list compilation is sequential~~ **FIXED**
**Files:** `Core/ContentRuleListManager.swift:95-120`
**Issue:** The three rule lists compile/load one after another in nested callbacks. They are independent and could be parallelized with a `DispatchGroup`.
**Fix:** The three `WKContentRuleList` compilations now run concurrently via `DispatchGroup` instead of sequentially in nested callbacks.

#### ~~S-L05: Bundle scheme handler doesn't send `Content-Length`~~ **FIXED**
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:835-843`
**Issue:** The HTTPURLResponse doesn't include a `Content-Length` header. WebKit may make suboptimal loading decisions.
**Fix:** `BundleSchemeHandler` now includes `Content-Length` in responses using the already-queried `fileSize`.

#### ~~S-L06: `ThumbnailRenderer` streaming loop lacks `autoreleasepool`~~ **FIXED**
**Files:** `Core/ThumbnailRenderer.swift:859-864`
**Issue:** The `while` loop that reads file chunks may accumulate autoreleased `Data` objects in the current autorelease pool, causing a memory spike for very large files.
**Fix:** The scheme handler's 512 KB chunking loop now wraps each iteration in `autoreleasepool`, preventing transient memory spikes from accumulated `Data` objects.

---

## Optimization Findings

### High

#### ~~O-H01: Move DNS resolution off the main thread~~ **FIXED** (S-H01)
**Files:** `Core/NetworkPolicy.swift:178-201`, `WallpaperTypes/WebWallpaperRuntime.swift:275-298`
**Issue:** Same as S-H01. Synchronous `getaddrinfo` on the main thread.
**Fix:** `validateResolvedAddresses` is now dispatched to a background queue inside `performNativeFetch`.

#### ~~O-H02: Cap native fetch response size~~ **FIXED** (S-H02)
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:281-290`
**Issue:** Same as S-H02. Unbounded `Data` accumulation.
**Fix:** Switched to `URLSessionDownloadTask` with a 5 MB cap.

#### ~~O-H03: Parallelize content rule list compilation~~ **FIXED** (S-L04)
**Files:** `Core/ContentRuleListManager.swift:95-120`
**Issue:** Sequential compilation triples the first-launch delay.
**Fix:** The three `WKContentRuleList` compilations now run concurrently via `DispatchGroup`.

#### ~~O-H04: Cache bundle metadata across process launches~~ **FIXED** (S-L03)
**Files:** `Import/WallpaperBundle.swift`, `Import/WallpaperImporter.swift`
**Issue:** Every launch re-parses all JSON for every bundle.
**Fix:** `LivelyInfoParser` and `LivelyPropertiesParser` now cache parsed results keyed by file URL + mtime.

---

### Medium

#### ~~O-M01: Thumbnail cache pruning~~ **FIXED** (S-M05)
**Files:** `Core/ThumbnailRenderer.swift`
**Issue:** Same as S-M05. Orphaned thumbnails accumulate.
**Fix:** `ThumbnailRenderer` now calls `pruneOrphanedCache()` at init.

#### ~~O-M02: Serialize or deduplicate wallpaper imports~~ **FIXED** (S-M09)
**Files:** `UI/MenuBarController.swift:273-307`
**Issue:** Same as S-M09. Concurrent imports possible.
**Fix:** Added an `isImporting` flag to `MenuBarController`.

#### ~~O-M03: Coalesce geolocation consent alerts~~ **FIXED** (S-M08)
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:728-747`
**Issue:** Same as S-M08. Stacked modal alerts block the UI.
**Fix:** `LocationProxy` now maintains a static per-bundle queue for consent alerts.

#### ~~O-M04: Avoid re-creating `DispatchSourceTimer` on every resume~~ **FIXED** (S-L02)
**Files:** `Core/WatchdogTimer.swift`, `WallpaperTypes/WebWallpaperRuntime.swift:241`
**Issue:** Same as S-L02. Timer churn.
**Fix:** `WatchdogTimer.start()` now checks `isArmed` and reschedules the existing source.

#### ~~O-M05: Add `Content-Length` to scheme handler responses~~ **FIXED** (S-L05)
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:835-843`
**Issue:** Same as S-L05.
**Fix:** `BundleSchemeHandler` now includes `Content-Length` in responses.

#### ~~O-M06: `DisplayManager.updateDisplayList` is called redundantly on wake~~ **FIXED**
**Files:** `Core/WallpaperManager.swift:310-366`, `Core/DisplayManager.swift:13-37`
**Issue:** `screenDidWake` calls `updateDisplayList()`, then iterates displays. The `displayConfigurationDidChange` notification may also fire, causing a second update.
**Fix:** `displayConfigurationDidChange` now snapshots the last known display set. If the display IDs haven't changed, the expensive add/remove logic is skipped and only frame re-alignment runs.

#### ~~O-M07: `autoreleasepool` in file streaming loop~~ **FIXED** (S-L06)
**Files:** `Core/ThumbnailRenderer.swift:859-864`, `WallpaperTypes/WebWallpaperRuntime.swift:859-864`
**Issue:** Same as S-L06. Large file streaming accumulates autoreleased objects.
**Fix:** The scheme handler's chunking loop now wraps each iteration in `autoreleasepool`.

---

### Low

#### O-L01: Empty entitlements should document the sandbox posture
**Files:** `Resources/AetherDesk.entitlements`
**Issue:** The file is a bare `<dict/>`. It's unclear to a reader whether sandbox was intentionally disabled or accidentally omitted.
**Fix:** Add a comment plist key or a README note. (Not critical since `SandboxSupport.swift` documents the plan.)

#### O-L02: `UpdateManager` could use `OSLog` instead of `NSLog`
**Files:** `Core/UpdateManager.swift` (and others)
**Issue:** `NSLog` is legacy and slower. `Logger` (os.log) is the modern replacement on macOS 12+.
**Fix:** Gradual migration; low priority.

#### O-L03: `WallpaperValidator` hard-codes magic numbers
**Files:** `Import/WallpaperValidator.swift:45-48`
**Issue:** Bundle size limit (50 MB) and network budget (5 req/min) are inline constants.
**Fix:** Move to `Constants.swift` for discoverability.

---

## Implementation Roadmap

### ~~Phase 1 — Safety & Stability~~ ✅ COMPLETE

These fix crashes, hangs, or resource exhaustion:

1. ✅ **S-H01 / O-H01** — Move DNS resolution off the main thread.
2. ✅ **S-H02** — Cap native fetch response size.
3. ✅ **S-H03** — Add file size cap to `BundleSchemeHandler`.
4. ✅ **S-H04** — Replace shell-script updater with pure Swift self-relaunch.
5. ✅ **S-H05** — Verify zip checksum before extraction.
6. ✅ **S-H06** — Make `fpsCap` read-only in the JS bridge.
7. ✅ **S-H07** — Explicitly block `javascript:` navigation.

### ~~Phase 2 — Cleanup & Hygiene~~ ✅ COMPLETE

8. ✅ **S-M01** — Background-queue the wallpaper list lookup in `displayConfigurationDidChange`.
9. ✅ **S-M02** — Cap and prune `NetworkPolicy.domainLogs`.
10. ✅ **S-M03** — Enforce native fetch rate limit on the Swift side.
11. ✅ **S-M04** — Clean up `GeolocationPermissionStore` and `PropertyStore` on wallpaper deletion.
12. ✅ **S-M05 / O-M01** — Prune orphaned thumbnail cache entries.
13. ✅ **S-M06** — Thread-safe `UpdateManager.state`.
14. ✅ **S-M07** — Ensure `tempDir` is always removed on update failure.
15. ✅ **S-M08 / O-M03** — Coalesce geolocation consent alerts.
16. ✅ **S-M09 / O-M02** — Serialize wallpaper imports.
17. ✅ **S-M10** — Log full hostnames, drop subdomain stripping.
18. ✅ **S-M11** — Add explicit `NSAppTransportSecurity` policy.

### ~~Phase 3 — Performance Polish~~ ✅ COMPLETE

19. ✅ **O-H03 / S-L04** — Parallelize content rule list compilation.
20. ✅ **O-H04 / S-L03** — Cache bundle metadata across launches.
21. ✅ **O-M04 / S-L02** — Fix `WatchdogTimer` churn.
22. ✅ **O-M05 / S-L05** — Add `Content-Length` to scheme handler.
23. ✅ **O-M06** — Debounce `DisplayManager` updates.
24. ✅ **O-M07 / S-L06** — Add `autoreleasepool` to streaming loops.

### Phase 4 — Strategic (Deferred)

25. ⏸️ **S-L01** — Enable App Sandbox (v1.1 scope, as previously planned).

---

## Metrics & Verification

After implementing Phase 1, the app should pass the following manual smoke tests:

- [ ] Import a wallpaper that calls `fetch()` to a slow DNS domain — UI remains responsive.
- [ ] Import a wallpaper with a 200 MB file in its bundle — `BundleSchemeHandler` rejects requests for that file.
- [ ] Trigger a native fetch to an endpoint that returns 50 MB — response is truncated/rejected.
- [ ] Install the app in a path with spaces and quotes — auto-update still succeeds.
- [ ] Set FPS cap to 15 in preferences — web wallpaper cannot exceed 15 fps by mutating `window.aetherDesk.system.fpsCap`.
- [ ] Attempt `location.href = "javascript:alert(1)"` from wallpaper JS — navigation is cancelled.

---

*End of audit.*
