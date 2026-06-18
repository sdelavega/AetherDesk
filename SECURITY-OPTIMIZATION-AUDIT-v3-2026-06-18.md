# ÆtherDesk Security & Optimization Audit — Round 3

Generated: 2026-06-18
Scope: Full source review of the AetherDesk macOS app after Rounds 1 and 2 were completed.
Method: Static code analysis of all Swift sources, entitlements, and plists. No dynamic testing.

---

## Executive Summary

This pass surfaced **1 critical**, **3 high**, **12 medium**, and **15 low** new issues. The critical item (C1) is a URLSession retain cycle that leaks every fetch-capable WebWallpaperRuntime on wallpaper swap. The high items cover stale performance settings after reload, a path-traversal gap in `LivelyInfo.Preview` resolution, and SSRF bypass via WebKit subresource loads.

---

## Critical

### C1 — URLSession retain cycle leaks every fetch-capable WebWallpaperRuntime  ✅ FIXED

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:83-88` (session creation), `448` (task creation), `327-334` (`stop()`)
- **Issue:** `nativeFetchSession` is a `lazy var` created with `delegate: self`. `URLSession` retains its delegate until the session is explicitly invalidated. `stop()` never calls `invalidateAndCancel()` or `finishTasksAndInvalidate()`, and `deinit` never runs because of the cycle. Every wallpaper replacement leaks the old runtime — its URLSession, in-flight download tasks, containerView, pausedSnapshotView, watchdog closure, and LocationProxy — permanently for the process lifetime.
- **Fix:** In `stop()`, call `nativeFetchSession.invalidateAndCancel()`. Consider using a weak-proxy delegate pattern to break the cycle structurally.

---

## High

### H1 — Performance/network settings changes do not take effect on running wallpapers  ✅ FIXED

- **Files/lines:** `Core/WallpaperManager.swift:489-493`, `WallpaperTypes/WebWallpaperRuntime.swift:56-57, 97-121, 170-176`
- **Issue:** When performance settings change, `reloadAll()` calls `runtime.reload()` → `stop()` + `start()`. But `start()` recreates the WKWebView using `self.settings` and `self.policy` — both immutable `let` properties captured at init time. The recreated webview gets stale `blockExternalNetwork`, `allowLANAccess`, and `fpsCap`. Additionally, `allowLANAccess` changes don't trigger a reload at all.
- **Fix:** Either fully recreate runtimes via `setWallpaper(currentBundle, for:)` when these settings change, or have the runtime re-read `AppSettingsStore` / `RuntimePolicyStore` inside `start()` / `createWebView()` instead of caching in `let` properties. Add `allowLANAccess` to the reload trigger.

### H2 — Path traversal via `LivelyInfo.Preview` field  ✅ FIXED

- **Files/lines:** `Import/WallpaperBundle.swift:147-157`
- **Issue:** `previewImageURL` resolves `livelyInfo?.Preview` via `baseURL.appendingPathComponent(preview)` without `standardizedFileURL` or containment validation. A malicious `LivelyInfo.json` with `"Preview": "../../../../.ssh/id_rsa"` resolves outside the bundle. `declaredResourceURL` (for `FileName`) does this correctly — `Preview` was missed.
- **Fix:** Route `Preview` through the same containment check as `declaredResourceURL`: resolve, `standardizedFileURL`, verify `hasPrefix(basePath + "/")`.

### H3 — SSRF/budget bypass via WebKit-initiated subresource loads  ✅ FIXED

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:1057-1078`
- **Issue:** `decidePolicyFor` only covers main-frame and subframe navigations, not subresource loads (`<img>`, `<script>`, `<link>`, `<video>`, etc.). Those go through WebKit's own networking and bypass `NetworkPolicy`, the network budget, and DNS-rebinding checks. A wallpaper can probe `http://169.254.169.254/` via `<img src>` or exfiltrate data via `<script src>`.
- **Fix:** Extend the `WKContentRuleList` to block raw-IP and private-IP URL patterns for all resource types (not just WebSocket). When `blockExternalNetwork` is on, the existing rule list already blocks these; when it's off, add a complementary rule list that blocks raw IPs and metadata endpoints for subresources.

---

## Medium

### M1 — Web content process termination during pause silently resumes the wallpaper  ✅ FIXED

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:1015-1055`
- **Issue:** If the web content process terminates while `isPaused == true`, the handler schedules `DispatchQueue.main.asyncAfter { try self.start() }`. `start()` does not check `isPaused`, so it recreates the WKWebView and starts the watchdog — the wallpaper resumes despite the user having paused it.
- **Fix:** Guard the recovery path with `guard !self.isPaused else { return }`.

### M2 — In-flight native fetch tasks not cancelled on `stop()`  ✅ FIXED (by C1)

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:327-334, 396-489`
- **Issue:** `stop()` tears down the WKWebView but does not cancel in-flight `nativeFetchSession` download tasks. Each can download up to 5 MB and continues to completion after the wallpaper is gone.
- **Fix:** Call `nativeFetchSession.invalidateAndCancel()` in `stop()` (this also resolves C1).

### M3 — No bound on concurrent native fetches  ✅ FIXED

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:396-489`
- **Issue:** `performNativeFetch` creates a `URLSessionDownloadTask` for every bridge call with no cap on concurrency. Each can buffer up to 5 MB. `activeFetchCompletions` grows without limit.
- **Fix:** Enforce a concurrent-task cap (e.g. 8) using a semaphore or pending-queue pattern.

### M4 — `NetworkPolicy` does not block IPv4-mapped IPv6 addresses  ✅ FIXED

- **Files/lines:** `Core/NetworkPolicy.swift:167-186`
- **Issue:** `isPrivateIPv6` does not detect `::ffff:a.b.c.d` (IPv4-mapped IPv6). `::ffff:10.0.0.1` or `::ffff:169.254.169.254` bypass the LAN/localhost/metadata block.
- **Fix:** In `isPrivateIPv6`, detect the `::ffff:` prefix (bytes[0…9] == 0, bytes[10] == 0xFF, bytes[11] == 0xFF) and re-run the IPv4 check on the trailing 4 bytes.

### M5 — WallpaperStore / settings-store caches are not thread-safe  ✅ FIXED

- **Files/lines:** `Persistence/WallpaperStore.swift:105-128`, `Persistence/PropertyStore.swift:24-67`, `Persistence/AppSettingsStore.swift`, `Persistence/RuntimePolicyStore.swift`
- **Issue:** All stores keep in-memory `cache` properties read and written without locks. Several call sites access them off the main thread (e.g. `displayConfigurationDidChange` reads `WallpaperStore` from a background queue while the main thread may concurrently call `setAssignment`).
- **Fix:** Guard each `cache` with an `NSLock`, or route all access through the main thread.

### M6 — `LocationProxy` does not stop `CLLocationManager` on teardown  ✅ FIXED

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:1133-1207`
- **Issue:** `LocationProxy` has no `deinit` and `stop()` is not called when the runtime is torn down. `CLLocationManager` should be explicitly stopped to prevent battery drain and privacy concerns.
- **Fix:** Add `deinit { manager.stopUpdatingLocation() }` to `LocationProxy`, and call it from `WebWallpaperRuntime.stop()`.

### M7 — `UpdateManager.downloadAndInstall` is not re-entrant  ✅ FIXED

- **Files/lines:** `Core/UpdateManager.swift:273-364, 593-614`
- **Issue:** `downloadAndInstall` performs no state guard. A quiet auto-install racing with a user-triggered install can run two concurrent downloads + extractions.
- **Fix:** Guard with `guard case .idle = currentState else { return }` (or `.available`) and transition to `.downloading` atomically.

### M8 — Zip bomb: no size check before archive extraction  ✅ FIXED

- **Files/lines:** `Import/WallpaperImporter.swift:185-234`
- **Issue:** `ditto -xk` extracts the archive to a temp directory before `WallpaperValidator.bundleSize` runs. A high-ratio zip bomb expands to disk before the 50 MB limit is evaluated.
- **Fix:** Stat the archive file size before extraction and reject above a threshold (e.g. 2× `maxBundleBytes`). During `sanitizeExtractedContent`, accumulate sizes and abort once `maxBundleBytes` is exceeded.

### M9 — `WallpaperValidator` only inspects `index.html`, not linked JS files  ✅ FIXED

- **Files/lines:** `Import/WallpaperValidator.swift:78-84`
- **Issue:** All heuristic checks run against `index.html` only. A wallpaper with `<script src="main.js">` is never inspected — every heuristic (setInterval storm, tracker domains, `while(true)`, etc.) is bypassed.
- **Fix:** Walk the bundle directory, concatenate all `.js`/`.html`/`.htm` file contents (up to a per-file cap), and run `inspectJavaScript` against the concatenation.

### M10 — `SemanticVersion.compare` mishandles pre-release and build metadata  ✅ FIXED

- **Files/lines:** `Core/SemanticVersion.swift:24-40`
- **Issue:** Version strings like `1.0.0-beta` produce components (`"0-beta"`) that fail `Int(_:)` and fall through to lexicographic comparison. `"1.0.0-beta" > "1.0.0"` returns `true`, so the updater treats a pre-release as newer than the final.
- **Fix:** Strip build metadata (`+...`), split on `-` to separate pre-release. Compare numeric core first; if equal, a release with no pre-release is greater than one with a pre-release.

### M11 — `SandboxSupport.migrateIfNeeded` cannot locate the pre-sandbox library  ✅ FIXED

- **Files/lines:** `Core/SandboxSupport.swift:41-98`
- **Issue:** Both `oldBase` and `newBase` are derived from `FileManager.urls(for: .applicationSupportDirectory, ...)` — which, when sandboxed, returns the container path for both. The migration is a no-op.
- **Fix:** Access the pre-sandbox path via a security-scoped bookmark captured before sandboxing, or prompt the user via `NSOpenPanel` on first sandboxed launch.

### M12 — Update hash sidecar errors (non-404) silently skip verification  ✅ FIXED

- **Files/lines:** `Core/UpdateManager.swift:313-322`
- **Issue:** A network error (timeout, DNS failure) on the hash sidecar leaves `hashTempURL` as `nil`, so `verifySHA256` is skipped entirely. The intent was to skip only on 404, but any error has the same effect.
- **Fix:** Only skip hash verification on 404. On any other error, fail the update with `hashVerificationFailed`.

---

## Low

### L1 — Updater subprocess stderr is redirected to `/dev/null`
- **Files/lines:** `Core/UpdateManager.swift:533-534`
- **Issue:** Swap failure diagnostics from `main.swift` are lost because the parent nulls both stdout and stderr.
- **Fix:** Redirect stderr to a log file or `os_log`.

### L2 — `ContentRuleListManager` log messages are garbled
- **Files/lines:** `Core/ContentRuleListManager.swift:166, 178, 180`
- **Issue:** `"ÆtherDesk: \(label)rom cache"` produces `"content blocklistrom cache"`. Refactor consumed leading characters of suffix words.
- **Fix:** Use complete words: `"\(label) loaded from cache"`, etc.

### L3 — `NetworkPolicy.contactedDomains` not cleared on wallpaper delete
- **Files/lines:** `Import/WallpaperImporter.swift:164-181`
- **Issue:** `deleteWallpaper` clears `RuntimePolicyStore`, `GeolocationPermissionStore`, and `PropertyStore` but not `NetworkPolicy.clearDomainLog(for:)`.
- **Fix:** Add `NetworkPolicy.clearDomainLog(for: bundle.id)` to `deleteWallpaper`.

### L4 — `DisplayIdentity` collisions for identical displays reporting serial 0
- **Files/lines:** `Core/DisplayIdentity.swift:25-34`
- **Issue:** Identical external displays (same vendor/model, serial 0) produce the same identity key, causing `WallpaperStore` assignments to collide.
- **Fix:** Disambiguate by appending `CGDirectDisplayID` when two connected displays produce the same identity.

### L5 — `ImageWallpaperRuntime.stop()` does not set `isPaused`
- **Files/lines:** `WallpaperTypes/ImageWallpaperRuntime.swift:48-90`
- **Issue:** If `stop()` is called while image decode is in flight, the completion re-installs the image because `isPaused` is still false.
- **Fix:** Set `isPaused = true` in `stop()`.

### L6 — `MenuBarController.menuNeedsFullRebuild` is dead code
- **Files/lines:** `UI/MenuBarController.swift:45`
- **Issue:** Property is declared and assigned but never read.
- **Fix:** Remove it or wire it into `menuWillOpen`.

### L7 — `VideoWallpaperRuntime` AVAssetImageGenerator callback may fire twice
- **Files/lines:** `Core/ThumbnailRenderer.swift:226-242`
- **Issue:** macOS may deliver a final `.completed` callback with `cgImage == nil`, clearing the just-rendered thumbnail.
- **Fix:** Guard with a `hasCompleted` flag, or ignore invocations where `result != .succeeded`.

### L8 — `LivelyInfoParser` / `LivelyPropertiesParser` use `print` instead of `Logger`
- **Files/lines:** `LivelyCompatibility/LivelyInfoParser.swift:160`, `LivelyCompatibility/LivelyPropertiesParser.swift:100`
- **Fix:** Replace with `Logger.app.error(...)`.

### L9 — Parser static caches never pruned
- **Files/lines:** `LivelyCompatibility/LivelyInfoParser.swift:130`, `LivelyCompatibility/LivelyPropertiesParser.swift:71`
- **Fix:** Add `clearCache()` and call from `WallpaperImporter.invalidateCache()`, or cap dict size.

### L10 — `codesign --verify --deep` is deprecated
- **Files/lines:** `Core/UpdateManager.swift:374`
- **Fix:** Drop `--deep`; verify the main bundle and helpers individually.

### L11 — Adhoc-signed running app accepts any adhoc-signed update
- **Files/lines:** `Core/UpdateManager.swift:433-440`
- **Fix:** For dev builds, log a warning. For release builds, require a non-adhoc authority.

### L12 — `Info.plist` lacks `NSLocationAlwaysAndWhenInUseUsageDescription`
- **Files/lines:** `Resources/Info.plist:38-39`
- **Issue:** App Store reviewers may flag `whenInUse` as insufficient for always-on background location.
- **Fix:** Add `NSLocationAlwaysAndWhenInUseUsageDescription` and use `requestAlwaysAuthorization`.

### L13 — `WeatherKitBridge` lat/lon not range-validated
- **Files/lines:** `Core/WeatherKitBridge.swift:56-67`
- **Fix:** Validate `[-90, 90]` / `[-180, 180]` and return failure on out-of-range.

### L14 — Notification auth requested unconditionally every launch
- **Files/lines:** `UI/MenuBarController.swift:380-385`
- **Fix:** Check `authorizationStatus() == .notDetermined` before requesting.

### L15 — `BundleSchemeHandler` TOCTOU on file size
- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:1253-1300`
- **Issue:** Theoretical; bundle contents are immutable post-import.
- **Fix:** No action needed for current threat model.

---

## Implementation Roadmap

### Phase 1 — Critical & High

1. **C1** — Break URLSession retain cycle in `stop()`.
2. **H1** — Make performance settings take effect on reload.
3. **H2** — Containment-check `LivelyInfo.Preview`.
4. **H3** — Block raw-IP/private-IP subresource loads via ContentRuleList.

### Phase 2 — Medium

5. **M1** — Guard recovery path against `isPaused`.
6. **M2** — Cancel in-flight fetches on `stop()` (resolved by C1).
7. **M3** — Cap concurrent native fetches.
8. **M4** — Block IPv4-mapped IPv6 in `NetworkPolicy`.
9. **M5** — Thread-safe store caches.
10. **M6** — Stop `CLLocationManager` on teardown.
11. **M7** — Guard `downloadAndInstall` re-entrancy.
12. **M8** — Pre-extraction size check for zip imports.
13. **M9** — Walk all JS files in validator.
14. **M10** — Fix semver pre-release comparison.
15. **M11** — Fix sandbox migration path.
16. **M12** — Fail update on non-404 sidecar errors.

### Phase 3 — Low

17–31. **L1–L15** — Cleanup and hardening.

---

*End of audit.*
