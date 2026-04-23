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

#### S-H01: Synchronous DNS resolution blocks the main thread
**Files:** `Core/NetworkPolicy.swift:178-201`, `WallpaperTypes/WebWallpaperRuntime.swift:275-298`
**Issue:** `performNativeFetch` calls `networkPolicy.validateResolvedAddresses(for:)` on the main thread (it runs inside the `ScriptMessageHandler` callback). That method calls `resolveHost`, which uses `getaddrinfo` synchronously. On a slow or unreachable DNS server this blocks the main thread for multiple seconds, freezing the menu bar and any host-window updates.
**Fix:** Move `validateResolvedAddresses` onto a background queue inside `performNativeFetch`. The result can be dispatched back to main for the actual `URLSession` call.
**Risk:** Denial of service (UI freeze) from a wallpaper requesting a domain with slow DNS.

#### S-H02: Native fetch proxy has no response size limit
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:281-290`
**Issue:** `URLSession.shared.dataTask` receives the full response body into memory. A malicious or compromised endpoint can stream an unbounded amount of data, exhausting RAM and potentially crashing the app.
**Fix:** Use `URLSessionConfiguration` with a small `httpMaximumConnectionsPerHost`, or better, switch to `URLSessionDownloadTask` and cap the downloaded file size. Reject bodies over a reasonable threshold (e.g., 5 MB for wallpaper API responses).
**Risk:** Memory exhaustion / app crash from a malicious native fetch response.

#### S-H03: No file size cap in BundleSchemeHandler
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:845-865`
**Issue:** The streaming path reads files in 512 KB chunks with no upper bound. A wallpaper bundle can include a multi-gigabyte file (e.g., renamed `.mp4` or raw data) and request it via a relative path. The chunking prevents a single huge `Data` allocation, but WebKit will keep asking for more data, causing sustained high disk I/O and CPU.
**Fix:** Add a hard cap (e.g., 100 MB) in `BundleSchemeHandler.webView(_:start:)`. Reject requests for files larger than the cap.
**Risk:** Disk/CPU denial of service from a malicious bundle.

#### S-H04: Shell command injection in auto-updater install path
**Files:** `Core/UpdateManager.swift:410-420`
**Issue:** `performInstall` interpolates `currentAppPath`, `newAppPath`, `tempDir.path`, and `pid` directly into a bash script string. If the app is ever installed in a path containing double quotes, backticks, or dollar-sign expressions, the script syntax breaks or becomes injectable. While the current app path is typically `/Applications/AetherDesk.app`, this is a latent vulnerability.
**Fix:** Do not generate a shell script. Launch a small Swift helper binary (or use `Process` with `Process.launchPath` and arguments array) to perform the swap. If you must use a script, pass the paths as environment variables and quote them with a proper escaping routine.
**Risk:** Arbitrary command execution during update if the app path is attacker-controlled.

#### S-H05: Update zip is not integrity-checked before extraction
**Files:** `Core/UpdateManager.swift:380-407`
**Issue:** After downloading the zip, `ditto` extracts it immediately. There is no checksum or signature verification of the archive itself—only the extracted `.app` is verified afterwards. A corrupted or maliciously crafted zip could exploit vulnerabilities in `ditto` or libarchive before the code-signature check runs.
**Fix:** Compute SHA-256 of the downloaded zip and verify it against a hash published in the GitHub release metadata (or at minimum verify the code signature *before* moving the new app into place, which you already do—just ensure extraction happens in a tightly bounded temporary area).
**Risk:** Supply-chain compromise via malicious archive payload.

#### S-H06: Wallpaper can override the native FPS cap in JavaScript
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:462-479`
**Issue:** The `requestAnimationFrame` throttle reads `window.aetherDesk.system.fpsCap` at runtime. A wallpaper can simply reassign that property to 60 (or 120) and bypass the cap entirely. The native side never re-injects the cap after startup.
**Fix:** Either (a) make `fpsCap` a read-only non-configurable property via `Object.defineProperty`, or (b) store the cap in a closure variable that the wallpaper cannot access, or (c) have the native side re-inject the cap periodically.
**Risk:** Battery drain and thermal issues when a wallpaper bypasses the performance cap.

#### S-H07: `javascript:` navigation is not explicitly blocked
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:653-663`
**Issue:** `shouldAllowNavigation` falls through to `default: return false` for unknown schemes, which does block `javascript:` URLs in practice. However, relying on a negative default is brittle—an explicit `case "javascript": return false` is safer and self-documenting.
**Fix:** Add an explicit `case "javascript"` to the switch.
**Risk:** Low (currently mitigated by default), but a future refactor could accidentally change the default.

---

### Medium

#### S-M01: Main-thread directory scan on display hot-plug
**Files:** `Core/WallpaperManager.swift:345`
**Issue:** When a new display is connected, `displayConfigurationDidChange` calls `WallpaperImporter.shared.listWallpapers()` on the main thread. This enumerates directories and parses JSON for every bundle. On systems with many imported wallpapers this causes a visible UI hitch.
**Fix:** Inject a pre-built bundle list into `WallpaperManager` (it already receives one at launch) or dispatch the lookup to a background queue and apply the result on main.
**Risk:** UI jank when connecting external monitors.

#### S-M02: Unbounded domain log growth in NetworkPolicy
**Files:** `Core/NetworkPolicy.swift:31-32, 91-102`
**Issue:** `domainLogs` is a static `[UUID: Set<String>]` that accumulates every unique domain contacted by every wallpaper, forever. There is no eviction, pruning, or size cap. Over a long session with many wallpapers this grows without bound.
**Fix:** Cap each bundle's domain set (e.g., max 100 entries) and drop oldest/LRU. Also clear the log when a wallpaper is deleted.
**Risk:** Unbounded memory growth; mild information leakage (domain history persists for deleted bundles).

#### S-M03: No rate limiting on the native fetch bridge
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:269-299`
**Issue:** The JS-side network budget (`networkBudgetPerMinute`) is enforced in the injected shim, but a wallpaper could bypass it by calling the native bridge directly via `webkit.messageHandlers.aetherDesk.postMessage({action:"nativeFetch"...})`. The native `performNativeFetch` does not enforce its own rate limit.
**Fix:** Add a per-runtime request counter in `WebWallpaperRuntime` (mirroring the JS budget) and reject native fetch calls that exceed it.
**Risk:** Data exfiltration or network abuse if a wallpaper bypasses the JS shim.

#### S-M04: Geolocation permissions are not cleaned up when a wallpaper is deleted
**Files:** `Persistence/GeolocationPermissionStore.swift`, `Import/WallpaperImporter.swift:146-161`
**Issue:** `deleteWallpaper` removes the bundle from disk and deletes its runtime policy, but `GeolocationPermissionStore` and `PropertyStore` entries are never purged. Over time the UserDefaults payload accumulates orphaned keys.
**Fix:** In `deleteWallpaper`, also call `GeolocationPermissionStore.shared.delete(for:)` and `PropertyStore.shared.delete(for:)`.
**Risk:** Privacy hygiene (stale consent records) and UserDefaults bloat.

#### S-M05: No pruning of thumbnail disk cache
**Files:** `Core/ThumbnailRenderer.swift:22-54`
**Issue:** Thumbnails are written to `~/Library/Caches/.../thumbnails/` but never deleted. If the user imports and deletes many wallpapers, orphaned PNGs accumulate indefinitely.
**Fix:** On launch (or when cache size exceeds a threshold), enumerate the thumbnail directory and remove entries whose bundle ID no longer exists in `WallpaperImporter.shared.listWallpapers()`.
**Risk:** Disk space leakage.

#### S-M06: `UpdateManager.state` is not thread-safe
**Files:** `Core/UpdateManager.swift:65, 120-150, 222-270`
**Issue:** `state` is a `var` read and written from both the background `queue` and the main queue without a lock or atomic operations. Race conditions could cause duplicate downloads, missed UI updates, or inconsistent state reporting.
**Fix:** Guard `state` with a private `NSLock` or serialize all state mutations onto a single queue.
**Risk:** Logic bugs in the updater; possible duplicate downloads.

#### S-M07: Update temporary directories not always cleaned up on failure
**Files:** `Core/UpdateManager.swift:354-442`
**Issue:** Several early-exit paths in `performInstall` (e.g., `ditto` failure, `.app` not found) do not remove `tempDir`. The stable download URL is moved into `tempDir` and would be orphaned.
**Fix:** Wrap the install logic in a `defer { try? fm.removeItem(at: tempDir) }` or use a `withTemporaryDirectory` helper.
**Risk:** Disk space leakage from repeated failed updates.

#### S-M08: `NSAlert.runModal()` blocks the main thread during geolocation consent
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:728-747`
**Issue:** `LocationProxy.promptForConsent` displays an alert modally. If multiple wallpapers request geolocation simultaneously, the alerts stack and block all user interaction until dismissed.
**Fix:** Use a single shared geolocation consent queue: if an alert is already showing for a bundle, queue the request ID and resolve them all with the same answer.
**Risk:** UI blocking; poor user experience with stacked modals.

#### S-M09: `MenuBarController` wallpaper import is not serialized
**Files:** `UI/MenuBarController.swift:273-307`
**Issue:** The user can trigger the import panel, dismiss it, and trigger it again rapidly. Each import runs asynchronously on a background queue with no mutex. Concurrent imports of the same source could race on filesystem operations.
**Fix:** Add an `isImporting` flag or use an `NSLock` to prevent concurrent imports.
**Risk:** File-system race conditions; potential duplicate bundles.

#### S-M10: Subdomain stripping is incorrect for multi-part TLDs
**Files:** `Core/NetworkPolicy.swift:104-110`
**Issue:** `stripSubdomain` takes the last two dot-separated components. For `api.example.co.uk` this returns `co.uk`, which is not useful for domain logging.
**Fix:** Use the Public Suffix List (or at least a small hard-coded list of common ccTLDs like `.co.uk`) to determine the effective eTLD+1.
**Risk:** Misleading domain logs; not a direct security issue.

#### S-M11: `Info.plist` lacks `NSAppTransportSecurity` policy
**Files:** `Resources/Info.plist`
**Issue:** The plist does not define an `NSAppTransportSecurity` dictionary. By default ATS is enabled, which is good, but there is no explicit enforcement. Because the app is unsandboxed and uses `URLSession.shared`, this is acceptable, but an explicit `NSAllowsArbitraryLoads = false` would document the intent.
**Fix:** Add `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = false`. (The native fetch proxy already handles HTTP URLs; if wallpapers need HTTP endpoints, the proxy can allow them individually.)
**Risk:** Low—ATS is enabled by default, but explicit policy is better documentation.

---

### Low

#### S-L01: No App Sandbox enabled
**Files:** `Resources/AetherDesk.entitlements`
**Issue:** The entitlements file is an empty dict. The app has unrestricted filesystem and network access. `SandboxSupport` scaffolding exists but is inert.
**Fix:** Enable App Sandbox in v1.1 as previously planned. This is marked low because it is a known deferred decision with scaffolding in place.
**Risk:** Broad attack surface; mitigated by the other controls in this audit.

#### S-L02: `WatchdogTimer.start()` allocates a new `DispatchSourceTimer` on every resume
**Files:** `Core/WatchdogTimer.swift:40-58`, `WallpaperTypes/WebWallpaperRuntime.swift:241`
**Issue:** `resume()` calls `watchdog.start()`, which cancels the old source and allocates a new one. This is wasteful and slightly increases the chance of a race between cancellation and the new timer.
**Fix:** In `WatchdogTimer`, add an `isRunning` flag and make `start()` idempotent (or make `resume()` call `heartbeat()` instead of `start()` if the timer is already armed).
**Risk:** Resource churn; negligible security impact.

#### S-L03: `WallpaperBundle` JSON parsing is not cached across listings
**Files:** `Import/WallpaperBundle.swift:27-78`, `Import/WallpaperImporter.swift:106-113`
**Issue:** Every call to `listWallpapers()` (after a cache invalidation) re-parses `LivelyInfo.json` and `LivelyProperties.json` for every bundle. With 20+ bundles this is noticeable.
**Fix:** Cache parsed bundle metadata on disk (e.g., a `bundles.json` manifest in Application Support) and only re-parse when the bundle directory mtime changes.
**Risk:** Performance only.

#### S-L04: Content rule list compilation is sequential
**Files:** `Core/ContentRuleListManager.swift:95-120`
**Issue:** The three rule lists compile/load one after another in nested callbacks. They are independent and could be parallelized with a `DispatchGroup`.
**Fix:** Use `DispatchGroup` to compile all three lists concurrently.
**Risk:** Startup delay on first launch; minor.

#### S-L05: Bundle scheme handler doesn't send `Content-Length`
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:835-843`
**Issue:** The HTTPURLResponse doesn't include a `Content-Length` header. WebKit may make suboptimal loading decisions.
**Fix:** Add `Content-Length` using the already-queried `fileSize`.
**Risk:** Performance only.

#### S-L06: `ThumbnailRenderer` streaming loop lacks `autoreleasepool`
**Files:** `Core/ThumbnailRenderer.swift:859-864`
**Issue:** The `while` loop that reads file chunks may accumulate autoreleased `Data` objects in the current autorelease pool, causing a memory spike for very large files.
**Fix:** Wrap the loop body in `autoreleasepool { ... }`.
**Risk:** Transient memory spike; minor.

---

## Optimization Findings

### High

#### O-H01: Move DNS resolution off the main thread
**Files:** `Core/NetworkPolicy.swift:178-201`, `WallpaperTypes/WebWallpaperRuntime.swift:275-298`
**Issue:** Same as S-H01. Synchronous `getaddrinfo` on the main thread.
**Expected gain:** Eliminates main-thread freezes during external API calls.
**Implementation:** ~10 lines: wrap `validateResolvedAddresses` in `DispatchQueue.global().async`.

#### O-H02: Cap native fetch response size
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:281-290`
**Issue:** Same as S-H02. Unbounded `Data` accumulation.
**Expected gain:** Prevents memory exhaustion from rogue endpoints.
**Implementation:** Use `URLSessionDownloadTask` or check `data.count` in the completion handler and truncate/reject.

#### O-H03: Parallelize content rule list compilation
**Files:** `Core/ContentRuleListManager.swift:95-120`
**Issue:** Sequential compilation triples the first-launch delay.
**Expected gain:** ~2-3× faster first-launch content blocker setup.
**Implementation:** Replace nested callbacks with `DispatchGroup`.

#### O-H04: Cache bundle metadata across process launches
**Files:** `Import/WallpaperBundle.swift`, `Import/WallpaperImporter.swift`
**Issue:** Every launch re-parses all JSON for every bundle.
**Expected gain:** Faster startup with many imported wallpapers.
**Implementation:** Write a `bundles-manifest.json` on import/delete; load it at startup and only validate mtimes.

---

### Medium

#### O-M01: Thumbnail cache pruning
**Files:** `Core/ThumbnailRenderer.swift`
**Issue:** Same as S-M05. Orphaned thumbnails accumulate.
**Expected gain:** Reclaim disk space.
**Implementation:** On app launch, iterate the thumbnail directory and delete entries whose bundle ID is not in the current wallpaper list.

#### O-M02: Serialize or deduplicate wallpaper imports
**Files:** `UI/MenuBarController.swift:273-307`
**Issue:** Same as S-M09. Concurrent imports possible.
**Expected gain:** Prevent race conditions and duplicate bundles.
**Implementation:** Add a serial `OperationQueue` or `isImporting` flag.

#### O-M03: Coalesce geolocation consent alerts
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:728-747`
**Issue:** Same as S-M08. Stacked modal alerts block the UI.
**Expected gain:** Smoother UX; no main-thread blocking.
**Implementation:** Use a shared alert queue or a non-modal permissions panel.

#### O-M04: Avoid re-creating `DispatchSourceTimer` on every resume
**Files:** `Core/WatchdogTimer.swift`, `WallpaperTypes/WebWallpaperRuntime.swift:241`
**Issue:** Same as S-L02. Timer churn.
**Expected gain:** Reduced dispatch overhead; cleaner lifecycle.
**Implementation:** Add `isArmed` check in `start()` or use `heartbeat()` in `resume()`.

#### O-M05: Add `Content-Length` to scheme handler responses
**Files:** `WallpaperTypes/WebWallpaperRuntime.swift:835-843`
**Issue:** Same as S-L05.
**Expected gain:** Faster sub-resource loading in WebKit.
**Implementation:** One-line header addition.

#### O-M06: `DisplayManager.updateDisplayList` is called redundantly on wake
**Files:** `Core/WallpaperManager.swift:310-366`, `Core/DisplayManager.swift:13-37`
**Issue:** `screenDidWake` calls `updateDisplayList()`, then iterates displays. The `displayConfigurationDidChange` notification may also fire, causing a second update.
**Expected gain:** Eliminate duplicate work on wake.
**Implementation:** Add a small debounce (e.g., 0.2s) or early-exit if the display set hasn't changed.

#### O-M07: `autoreleasepool` in file streaming loop
**Files:** `Core/ThumbnailRenderer.swift:859-864`, `WallpaperTypes/WebWallpaperRuntime.swift:859-864`
**Issue:** Same as S-L06. Large file streaming accumulates autoreleased objects.
**Expected gain:** Lower peak memory during large file reads.
**Implementation:** Wrap loop bodies.

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

### Phase 1 — Safety & Stability (Do First)

These fix crashes, hangs, or resource exhaustion:

1. **S-H01 / O-H01** — Move DNS resolution off the main thread.
2. **S-H02** — Cap native fetch response size.
3. **S-H03** — Add file size cap to `BundleSchemeHandler`.
4. **S-H04** — Replace shell-script updater with `Process`-based helper.
5. **S-H05** — Verify zip checksum before extraction.
6. **S-H06** — Make `fpsCap` read-only in the JS bridge.
7. **S-H07** — Explicitly block `javascript:` navigation.

### Phase 2 — Cleanup & Hygiene

8. **S-M01** — Background-queue the wallpaper list lookup in `displayConfigurationDidChange`.
9. **S-M02** — Cap and prune `NetworkPolicy.domainLogs`.
10. **S-M03** — Enforce native fetch rate limit on the Swift side.
11. **S-M04** — Clean up `GeolocationPermissionStore` and `PropertyStore` on wallpaper deletion.
12. **S-M05 / O-M01** — Prune orphaned thumbnail cache entries.
13. **S-M06** — Thread-safe `UpdateManager.state`.
14. **S-M07** — Ensure `tempDir` is always removed on update failure.
15. **S-M08 / O-M03** — Coalesce geolocation consent alerts.

### Phase 3 — Performance Polish

16. **O-H03** — Parallelize content rule list compilation.
17. **O-H04** — Cache bundle metadata across launches.
18. **O-M04 / S-L02** — Fix `WatchdogTimer` churn.
19. **O-M05 / S-L05** — Add `Content-Length` to scheme handler.
20. **O-M06** — Debounce `DisplayManager` updates.
21. **O-M07 / S-L06** — Add `autoreleasepool` to streaming loops.

### Phase 4 — Strategic

22. **S-L01** — Enable App Sandbox (v1.1 scope, as previously planned).

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
