# ÆtherDesk Security & Optimization Audit — Round 2

Generated: 2026-06-17
Scope: All Swift sources, entitlements, plists, and bundled resources in the current `main` branch.
Method: Static review focused on changes since the 2026-04-23 audit (`SECURITY-OPTIMIZATION-AUDIT-REVIEW.md`). That prior document’s Phase 1–3 fixes are assumed complete and are not duplicated here.

---

## Executive Summary

The previous audit resolved the most obvious surface-level risks. This pass focuses on newer code paths that either did not exist then or were introduced in subsequent work (WeatherKit bridge, App Store build conditionals, per-display identity, preferences rewrite). It surfaced **8 high-severity**, **6 medium-severity**, and **5 low-severity** new issues.

High-severity items are concentrated in three areas:
- The self-updater still trusts external data and command-line arguments.
- The web wallpaper runtime has multiple ways to bypass `NetworkPolicy` (redirects, WebSockets, `file://` and HTTP navigations, shared origin).
- The bundle scheme handler can serve files outside the bundle via symlinks.

This document is structured by severity. Each item includes the exact file/line reference, the risk, and a concrete fix.

---

## Security Findings

### Critical

None.

### High

#### ~~H1: Update download and hash verification have no size cap~~ **FIXED**

- **Files/lines:** `Core/UpdateManager.swift:51` (asset size available but ignored); `295–299` (download); `548` (`Data(contentsOf: fileURL)`)

- **Files/lines:** `Core/UpdateManager.swift:51` (asset size available but ignored); `295–299` (download); `548` (`Data(contentsOf: fileURL)`)
- **Issue:** The GitHub release asset includes a `size` field, but `downloadAndInstall(_:)` ignores it. Then `verifySHA256(ofFileAt:againstHashFile:)` reads the entire downloaded zip into memory with `Data(contentsOf: fileURL)`. A malicious or unusually large release archive can exhaust RAM or disk before any integrity check runs.
- **Fix:**
  1. Compare `asset.size` against a hard cap (e.g. 200 MB) before starting `downloadAndInstall`.
  2. Stream-compute the SHA-256 via `FileHandle` and `update(data:)` instead of loading the whole file into `Data`.
  3. Delete partial/in-flight downloads on rejection.

#### ~~H2: Updater child process trusts command-line paths~~ **FIXED**

- **Files/lines:** `Core/UpdateManager.swift:519–521` (argument construction); `App/main.swift:34–50` (updater dispatch)
- **Issue:** `UpdateManager` spawns the current executable with `--aetherdesk-updater <pid> <oldAppPath> <newAppPath> <tempDir>`. `main.swift` then removes `oldAppPath` and moves `newAppPath` onto it with no validation. Any caller who can launch the app binary can pass arbitrary paths, resulting in arbitrary file deletion/renaming as the app process.
- **Fix:** In `main.swift`, validate before accepting the update:
  - `oldAppPath` must equal `Bundle.main.bundlePath`.
  - `tempDir` must be rooted under `NSTemporaryDirectory()`.
  - `newAppPath` must be a child of `tempDir`.
  - `pid` must be positive.

#### ~~H3: All web wallpapers share the same origin~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:49` (`bundleScheme`); `250–252` (base URL assembly)
- **Issue:** Every web wallpaper loads under `aetherwall://wallpaper/`. WebKit treats this as a single origin across all bundles, so localStorage, cookies, and IndexedDB are shared. A malicious imported wallpaper can read or poison data stored by another.
- **Fix:** Use a unique host per bundle, e.g. `aetherwall://<bundleID>/`, and update `BundleSchemeHandler` to resolve the bundle from the requested host. This keeps each wallpaper isolated.

#### ~~H4: Bundle scheme handler does not resolve symlinks~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:1016–1023`; `Import/WallpaperImporter.swift:238–245`
- **Issue:** `standardizedFileURL` canonicalizes the URL but does **not** resolve symbolic links. An imported bundle can contain a symlink with an allowed extension that points outside the bundle (or anywhere on disk), and the scheme handler will serve the target file. The import-time sanitizer uses `.skipsSubdirectoryDescendants`, so nested symlinks are never removed.
- **Fix:** In `BundleSchemeHandler`, call `resolvingSymlinksInPath()` before the path-prefix check and reject any resolved path that exits the bundle. Also make `WallpaperImporter` recursively enumerate and reject all symlinks during extraction/validation.

#### ~~H5: HTTP(S) navigations bypass `NetworkPolicy`~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:854–866`
- **Issue:** `shouldAllowNavigation(to:)` only checks the per-minute network budget for `http`/`https`. It never calls `networkPolicy.validate(url:)`, so a wallpaper can navigate to raw public IPs, private LANs, or cloud metadata endpoints that are normally blocked.
- **Fix:** Route every `http`/`https` navigation URL through the same validation pipeline as `performNativeFetch`, including DNS rebinding checks and LAN/raw-IP blocks.

#### ~~H6: Native fetch follows redirects without re-validation~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:409–441`
- **Issue:** `performNativeFetch` uses `URLSession.shared.downloadTask(_:completionHandler:)`, which follows HTTP redirects automatically. An initial allowed URL can redirect to a blocked host, raw IP, or metadata endpoint, bypassing `NetworkPolicy` and the 5 MB response-size cap.
- **Fix:** Use a custom `URLSession` delegate and either:
  - Re-run `NetworkPolicy` validation on every redirect URL, or
  - Reject all redirects by calling `completionHandler(nil)`.

#### ~~H7: FQDN WebSockets bypass network policy and budget~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:723–745`
- **Issue:** The JS `WebSocket` wrapper only rejects raw IP and bracketed IPv6 forms. A wallpaper can open a WebSocket to an arbitrary FQDN, exfiltrate data, or maintain a persistent command channel. This bypasses the per-minute network budget, DNS rebinding checks, and the `blockExternalNetwork` content rule list.
- **Fix:** Route WebSocket creation through the same policy as native fetch: validate the URL with `networkPolicy.validate(url:)` and `validateResolvedAddresses(for:)`, and optionally enforce the per-minute network budget on connections.

#### ~~H8: `file://` navigation is allowed~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:857`
- **Issue:** `shouldAllowNavigation(to:)` allows the `file` scheme, so a wallpaper can navigate to `file:///etc/passwd` or any other local file. In the unsandboxed OSS build this reads arbitrary user files inside the webview.
- **Fix:** `file://` navigation is now restricted to files inside the current bundle directory after symlink resolution.

### Medium

#### ~~M1: Preferences wallpaper editor leaks child view controllers~~ **FIXED**

- **Files/lines:** `UI/PreferencesWindowController.swift:499–521`
- **Issue:** `installEditor(for:)` calls `addChild(editor)` each time a new wallpaper is selected, but it never calls `removeFromParent()` on the previous editor. The parent strongly retains every child controller, leaking view controllers, their views, and any observers they hold.
- **Fix:** Store `currentEditor` as a strong reference, then call `currentEditor?.removeFromParent()` and `currentEditor?.view.removeFromSuperview()` before creating and adding the new editor.

#### ~~M2: Pop-up property editor sends a string instead of the underlying value~~ **FIXED**

- **Files/lines:** `UI/PropertyEditorViewController.swift:227–230`
- **Issue:** `popupChanged` dispatches `titleOfSelectedItem ?? indexOfSelectedItem` as the new property value. If `LivelyProperties.json` declared a `Bool` or `Int` for the option, the running wallpaper receives a `String`, which can break type-sensitive JS logic.
- **Fix:** Persist the original `prop.items` values in `ControlTarget` and dispatch the actual underlying value (`items[index].value.value`) instead of the displayed title.

#### ~~M3: WeatherKit fallback bypasses size and policy controls~~ **FIXED**

- **Files/lines:** `Core/WeatherKitBridge.swift:96–106`
- **Issue:** When WeatherKit is unavailable, the bridge falls back to `URLSession.shared.dataTask(with: url)`. This path has no 5 MB cap, no per-minute network budget, and no `NetworkPolicy`/DNS-rebinding check, unlike the normal native fetch path.
- **Fix:** Route the fallback through the existing `performNativeFetch` pipeline, or replicate the same download-to-file, size-cap, and policy checks in the bridge.

#### ~~M4: `XMLHttpRequest` is not routed through the native policy layer~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:636–649`
- **Issue:** The XHR override only enforces the JS-side network budget; the underlying `XMLHttpRequest` still uses WebKit’s network stack and never runs through `NetworkPolicy`. It can reach raw IPs, private LAN hosts, and metadata endpoints that the `fetch()` path cannot.
- **Fix:** Either route `XMLHttpRequest` through `performNativeFetch` (mirroring the `fetch()` override) or call `networkPolicy.validate(url:)` inside the `open` override before allowing the request to proceed.

#### ~~M5: Update archive size is not bounded before extraction~~ **FIXED** (H1)

- **Files/lines:** `Core/UpdateManager.swift:51`, `273–299`
- **Issue:** The GitHub asset `size` is available but ignored. A huge zip can fill the temp volume before `verifySHA256` or signature checks run, even if the final extraction is bounded later.
- **Fix:** Compare `asset.size` against a hard cap before starting the download; also inspect the final downloaded file size before extraction.

#### ~~M6: `ContentRuleListManager` sets shared lists from unprotected queues~~ **FIXED**

- **Files/lines:** `Core/ContentRuleListManager.swift:152–179`
- **Issue:** `compileOrLoadRuleList` callbacks run on an unspecified WebKit queue and mutate `ruleList`, `externalNetworkBlockRuleList`, and `rawIPWebSocketRuleList`. These writes are unsynchronized with the main queue and with any readers. If any other code reads the properties before `prepare` finishes, it races.
- **Fix:** Dispatch all property assignments (`self.ruleList = …`, etc.) to the main queue inside the completion handlers.

### Low

#### ~~L1: `memoryWarningThresholdMB` is unused~~ **FIXED**

- **Files/lines:** `App/Constants.swift:42`
- **Issue:** A memory-warning threshold is defined but never referenced. It is dead configuration unless wired up.
- **Fix:** Either implement a `didReceiveMemoryPressureNotification` handler in `WallpaperManager` that pauses runtimes when memory pressure is reported, or remove the constant.

#### ~~L2: Crash-recovery loop can run indefinitely~~ **FIXED**

- **Files/lines:** `WallpaperTypes/WebWallpaperRuntime.swift:812–827`
- **Issue:** A web content process that crashes every 11 seconds resets `rapidTerminationCount` and is retried forever, wasting CPU in a crash/relaunch loop.
- **Fix:** Track the total number of crashes per `start()` and demote to safe mode after a fixed crash count (e.g., 5), regardless of timing.

#### ~~L3: Weather-source UI is keyed by folder name~~ **FIXED**

- **Files/lines:** `UI/PreferencesWindowController.swift:551`
- **Issue:** The weather-source picker only appears when `bundle.baseURL.lastPathComponent == "WeatherAether"`. Renaming the bundle folder hides the control.
- **Fix:** Use a stable bundle ID or a manifest flag in `LivelyInfo.json` instead of the folder name.

#### ~~L4: `DisplayManager` can use a stale display count~~ **FIXED**

- **Files/lines:** `Core/DisplayManager.swift:29–35`
- **Issue:** `CGGetActiveDisplayList` is called twice. If the display set changes between the two calls, the second call may write past the allocated buffer or miss displays.
- **Fix:** Loop until the count returned by the first call matches the second, or use a single `CGGetActiveDisplayList` call with retry logic.

#### ~~L5: `PropertyStore` sanitize has no recursion-depth limit~~ **FIXED**

- **Files/lines:** `Persistence/PropertyStore.swift:69–94`
- **Issue:** Nested collection sizes are capped at 100, but there is no depth limit. A deliberately nested dictionary can still exhaust the stack or fail to serialize into `UserDefaults`.
- **Fix:** Add a recursive helper that tracks and rejects values beyond a small maximum depth (e.g., 5 levels).

---

## Optimization / Cleanup Findings

No separate optimization-only items this time. The medium/low findings above that fix leaks, redundant work, and dead configuration also improve performance/correctness.

---

## Implementation Roadmap

### Phase 1 — High-Severity Security Fixes

1. **H1** — Cap update archive size and stream-compute SHA-256.
2. **H2** — Validate updater command-line paths before replacing the app.
3. **H3** — Isolate web wallpaper origins by bundle ID.
4. **H4** — Resolve/reject symlinks in the bundle scheme handler and import sanitizer.
5. **H5** — Run HTTP(S) navigations through `NetworkPolicy`.
6. **H6** — Re-validate or block redirects in `performNativeFetch`.
7. **H7** — Route WebSocket creation through `NetworkPolicy`.
8. **H8** — Block or scope `file://` navigation.

### Phase 2 — Medium-Severity Fixes ✅ COMPLETE

9. ✅ **M1** — Remove previous child editor in `PreferencesWindowController`.
10. ✅ **M2** — Preserve option value types in `PropertyEditorViewController`.
11. ✅ **M3** — Apply native fetch guards to the WeatherKit fallback.
12. ✅ **M4** — Route `XMLHttpRequest` through the same policy as `fetch`.
13. ✅ **M5** — Enforce update archive size cap from GitHub asset metadata.
14. ✅ **M6** — Serialize `ContentRuleListManager` assignments on the main queue.

### Phase 3 — Low-Severity / Cleanup

15. **L1** — Wire up or remove `memoryWarningThresholdMB`.
16. **L2** — Cap total web content process crash count before safe-mode demotion.
17. **L3** — Identify the weather-source picker by bundle ID, not folder name.
18. **L4** — Harden `DisplayManager` against display-count changes.
19. **L5** — Add recursion-depth limit to `PropertyStore` sanitization.

---

## Verification Checklist

After implementing the fixes, the following manual smoke tests should pass:

- [x] **H4** Import a bundle containing a symlink pointing to `/etc/passwd` — the symlink is either removed or the file cannot be served. (manual)
- [x] **H5** Trigger a `window.location = "http://169.254.169.254/latest/meta-data/"` from a web wallpaper — navigation is blocked. (manual)
- [x] **H6** Trigger a `fetch()` to a URL that 302-redirects to a raw IP — the redirect is blocked. (manual)
- [x] **H7** Open a WebSocket to `wss://<external>` from a web wallpaper — the connection is either blocked or counted against the budget. (manual)
- [x] **H8** Open `file:///etc/passwd` via `window.location` — navigation is blocked or scoped. (manual)
- [x] **M1** Select multiple wallpapers in Preferences — child view controllers are released (Instruments/Deinit test). (manual)
- [x] **M2** Set a Lively property whose items are `Bool` values via popup — the native side sends the actual `Bool`, not the string title. (manual)
- [x] **L2** Crash a web wallpaper repeatedly — after the configured crash count it stops retrying and falls back to safe mode. (manual)
- [x] **L4** Verify changing display topology mid-session does not produce stale display counts or buffer overruns. (manual/main logic verified)
- [x] **Build** Full Xcode build with no warnings or errors. (automated)

---

*End of audit.*
