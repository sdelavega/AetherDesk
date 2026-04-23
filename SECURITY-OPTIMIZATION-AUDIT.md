# ÆtherDesk Security & Optimization Audit

Generated 2026-04-23. Nothing is modified unless explicitly noted.

---

## Security Findings

### Critical

- [x] **S-01: Arbitrary file read via custom WKURLSchemeHandler**
  `WebWallpaperRuntime.swift` (BundleSchemeHandler) — The custom `aetherwall://` scheme handler resolved requested paths relative to the wallpaper bundle's base URL without checking that the resulting file URL stays within the bundle directory. A malicious `index.html` could request `../../etc/passwd` or use symlinks to read arbitrary files.
  **Fixed in dd465c9:** Resolved URLs are now standardized and checked against the bundle base path before serving. Requests that escape the bundle are rejected.

- [x] **S-02: Arbitrary file write via WallpaperImporter (zip slip)**
  `WallpaperImporter.swift:177-196` — `extractArchive()` uses `/usr/bin/ditto` to extract archives into the wallpapers directory. A crafted zip/tar archive with path entries like `../../.bash_profile` could write files outside the target directory.
  **Fixed in 7dbda68:** After extraction, `sanitizeExtractedContent(at:)` walks the tree and removes any entry whose resolved path or symlink target escapes the destination directory.

### High

- [x] **S-03: Custom URL scheme handler is a general-purpose file server**
  `WebWallpaperRuntime.swift:712-745` — Even without path traversal (fixed in S-01), the `aetherwall://` scheme handler serves any file the webview requests from the bundle directory. Wallpapers can read sibling files in the same bundle that they shouldn't necessarily access. Consider restricting to a known-allowed set of extensions or requiring an allowlist.
  **Mitigated by S-01 + S-04:** Path traversal (S-01) prevents reading outside the bundle. MIME allowlist (S-04) restricts servable types to web-safe formats only. Remaining surface — a wallpaper reading its own web assets — is intended behavior. Per-file allowlists would break real wallpapers without meaningful security gain.

- [x] **S-04: No content-type validation in BundleSchemeHandler**
  `WebWallpaperRuntime.swift:728-731` — The scheme handler infers MIME type from file extension but doesn't validate it. No `Content-Security-Policy` or restrictive headers are set on responses. A wallpaper could request executable files or other sensitive file types.
  **Fixed in 1d075c7:** mimeType(for:) returns nil for unknown extensions (rejected). Only wallpaper-relevant types served. Responses use HTTPURLResponse with X-Content-Type-Options: nosniff.

- [x] **S-05: WKWebView configuration allows full JavaScript and unrestricted network access**
  `WebWallpaperRuntime.swift` — Wallpapers can make `fetch()` / `XMLHttpRequest` requests to any network endpoint. The app is unsandboxed with no ATS restrictions. This allows data exfiltration, cryptomining, and loading of external malicious resources. The network budget partially mitigates this but is opt-in per-policy, not enforced by default.
  **Fixed in f7fc83a:** NetworkPolicy enforces (1) LAN/private IP blocking by default with opt-in, (2) FQDN-only HTTP(S) — no raw IPs, (3) cloud metadata endpoint blocking, (4) DNS rebinding guard, (5) per-wallpaper domain logging surfaced in Preferences, (6) WebSocket raw-IP blocking via JS patch + WKContentRuleList.

- [x] **S-06: UpdateManager downloads and executes code without signature verification**
  `UpdateManager.swift` — The auto-updater downloads an archive, extracts it, and replaces the app bundle. If the download endpoint is compromised or the connection is MITM'd, arbitrary code runs as the user. No code signature verification of the downloaded payload before extraction.
  **Fixed in 45d7451:** Before installation, `codesign --verify --deep --strict` confirms the extracted .app's signature is intact, then the TeamIdentifier (or Authority chain for ad-hoc builds) is compared against the currently running app. Updates signed by a different developer are rejected.

### Medium

- [x] **S-07: WallpaperValidator uses blocklist, not allowlist**
  `WallpaperValidator.swift` — The validator checks for known-bad patterns (google-analytics, doubleclick, facebook.net) in `index.html`. Easily bypassed via `eval(atob('...'))`, string concatenation, or any tracker not on the list.
  **Mitigated by S-05 (NetworkPolicy is the primary control). Improved in 254d390:** Expanded tracker blocklist (Sentry, Mixpanel, Segment, Bugsnag, Hotjar, Amplitude, Xandr, Adsrvr, Google ad subdomains). Added `atob()` and `String.fromCharCode` to obfuscation-pattern warnings (soft — results in stricter network budget, not rejection).

- [x] **S-08: No integrity check on wallpaper bundles**
  `WallpaperImporter.swift` — Imported bundles have no checksum/signature verification. A tampered bundle could contain modified JS with malicious behavior that passes the validator's regex checks.
  **Mitigated:** Bundled wallpapers are protected by the app's code signature — tampering breaks the signature and macOS refuses to launch. Imported wallpapers have no authority to verify against; checksumming is trivially bypassed by updating the checksum alongside the payload. Would require a signing infrastructure to meaningfully address for imports, which is out of scope for v1.

- [x] **S-09: LocationProxy grants geolocation without per-wallpaper consent**
  `WebWallpaperRuntime.swift:637-701` — Wallpapers can request geolocation via the JS bridge. While `CLLocationManager` triggers the system permission dialog on first use, subsequent wallpapers get location silently. No per-wallpaper consent or UI indication.
  **Fixed in 8ac455d:** Each wallpaper now requires individual consent via an NSAlert prompt on first geolocation request. The decision is persisted in GeolocationPermissionStore. A per-wallpaper "Allow geolocation" checkbox in Preferences > Wallpaper allows changing the decision.

- [x] **S-10: UserDefaults stores property overrides with no integrity check**
  `PropertyStore.swift` — Any process running as the user can modify UserDefaults values. Since these are injected into the webview as JavaScript, a malicious process could inject arbitrary JS via property values (e.g., `"); alert(document.cookie);//`).
  **Fixed in dcbc90f:** PropertyStore now sanitizes all values on load and save — only JSON-safe scalar types (String, Bool, Int, Double, Float), arrays, and dictionaries are allowed. Nested collections are recursively validated with a size cap. Non-conforming values are logged and dropped. Additionally, PropertyBridge.escapeJSONString already prevents direct JS injection from string values by properly quoting/escaping them as JSON string literals.

### Low

- [x] **S-11: FNV-1a hash is not collision-resistant** — `WallpaperBundle.swift` uses FNV-1a for generating bundle IDs from paths. Fine for identification but should not be relied on for any security purpose.
  **Not applicable:** FNV-1a is used only for stable identification, not for any security boundary. Imported bundles get UUID folder names, so the app controls the hash input.

- [ ] **S-12: No App Sandbox** — `AetherDesk.entitlements` has `com.apple.security.app-sandbox` set to `false`. Documented as a v1 decision, but the app and all wallpapers have unrestricted filesystem and network access.
  **Scaffolding added in 9063d8f:** Entitlements are prepared (sandbox key set to false, other keys commented out). `SandboxSupport` provides migration logic and security-scoped bookmark helpers, all gated behind `isSandboxed` and inert when unsandboxed. Full enablement deferred to v1.1.

- [x] **S-13: No Certificate Transparency or public-key pinning on update endpoint** — `UpdateManager.swift` makes standard URLSession requests without additional certificate validation.
  **Mitigated:** GitHub's TLS certificates are already CT-logged. Pinning would add fragility with no real gain. S-06 code signature verification is the actual safeguard — even a compromised TLS connection can't deliver a malicious update.

---

## Optimization Findings

### High

- [x] **O-01: Wallpaper import blocks main thread with `Process.waitUntilExit()`**
  `WallpaperImporter.swift:177-196` — `extractArchive()` runs `/usr/bin/ditto` synchronously and calls `waitUntilExit()`, freezing the entire UI during import of large archives. The entire import pipeline (archive extraction + file copy) should run on a background queue.
  **Fixed in ceb7743:** Added async `importWallpaper(from:completion:)` that dispatches all I/O to a background queue. Menu bar controller now uses the async path. Sync variant retained for non-UI callers.

### Medium

- [x] **O-02: WatchdogTimer deinit fails to actually cancel the timer**
  `WatchdogTimer.swift:34-36,72-77` — `deinit` calls `stop()`, which dispatches `cancelSourceLocked()` asynchronously. By the time the queue block executes, `self` is deallocated and `[weak self]` resolves to nil, so the cancel never runs. Fix: call `cancelSourceLocked()` synchronously in deinit.
  **Fixed in a1a83f7.**

- [x] **O-03: WatchdogTimer.stop() is async — timer can fire between stop() and actual cancellation**
  `WatchdogTimer.swift:72-77` — Can cause spurious `runtimeDidFail` notifications after the runtime was logically stopped. Fix: synchronously set `isArmed = false` before dispatching the source cancellation.
  **Fixed in a1a83f7:** `stop()` now uses `queue.sync` so the cancel is guaranteed complete before returning. `deinit` calls `cancelSourceLocked()` directly.

- [x] **O-04: BundleSchemeHandler reads entire files into memory**
  `WebWallpaperRuntime.swift:728-731` — `Data(contentsOf: fileURL)` loads the full file. For wallpapers bundling large video/image assets, this causes memory spikes. Should stream data in chunks for large files.
  **Fixed in 928c143:** Files under 1 MB use the fast single-read path. Larger files stream in 512 KB chunks via FileHandle.

- [x] **O-05: ImageWallpaperRuntime holds full-resolution NSImage indefinitely**
  `ImageWallpaperRuntime.swift:36` — A 4K wallpaper consumes ~33 MB of bitmap data for the entire runtime lifetime. Use `CGImageSourceCreateThumbnailAtIndex` with the display's pixel dimensions instead.
  **Fixed in dabd1cb:** Uses CGImageSourceCreateThumbnailAtIndex with ThumbnailMaxPixelSize set to the display's pixel dimensions (including backing scale). Falls back to NSImage(contentsOf:) if CGImageSource can't handle the format.

- [x] **O-06: ThumbnailRenderer.writeCache does PNG encoding + disk I/O on main thread**
  `ThumbnailRenderer.swift:75-83` — The web wallpaper render path calls `writeCache` directly in the main-queue completion closure. PNG encoding and file write should move to the background queue.
  **Fixed in 6386a53:** Cache writes are now dispatched to the thumbnail background queue. The completion callback fires on main thread immediately without waiting for the write.

- [x] **O-07: NSImage.resized(to:) uses lockFocus on background threads**
  `ThumbnailRenderer.swift:404-428` — `lockFocus()` is documented as main-thread-only. Called from background queues in `loadAndResize` and `renderVideoFrame`. Replace with `NSBitmapImageRep`/`CGContext`-based rendering.
  **Fixed in 84d30a9:** Replaced lockFocus/unlockFocus with NSBitmapImageRep + NSGraphicsContext(bitmapImageRep:), which is explicitly thread-safe.

- [x] **O-08: Startup calls listWallpapers() synchronously on main thread**
  `WallpaperImporter.swift:92-97` — Called from `applicationDidFinishLaunching`, does directory listing + JSON parsing for every bundle before any wallpaper appears. Should be dispatched to a background queue or cached on disk.
  **Fixed in bf6a865:** Wallpaper listing now runs on a global userInitiated queue. startAndRestore and update checks are dispatched back to main after the list is ready.

- [x] **O-09: ImageWallpaperRuntime.start() loads image synchronously**
  `ImageWallpaperRuntime.swift:33` — `NSImage(contentsOf:)` is synchronous I/O + image decode. For large files this causes a UI hitch. Load on a background queue and swap in on main.
  **Fixed in 99701ea:** Image decode now runs on a global userInitiated queue and the result is swapped into the image view on main. If the runtime was paused/stopped before the load completes, the image is discarded.

- [x] **O-10: Web runtime crash-recovery retry can resurrect a stopped runtime**
  `WebWallpaperRuntime.swift:582-596` — `webViewWebContentProcessDidTerminate` schedules a 1-second retry via `DispatchQueue.main.asyncAfter`. If `stop()` is called during that window, the retry fires and re-creates the WKWebView. Add a guard check in the retry block.
  **Fixed in 3b619a7:** Added `isStopped` flag set in `stop()` and cleared in `start()`. The retry block checks `isStopped` and bails out if the runtime has been stopped.

### Low

- [ ] **O-11: Property double-injection flicker** — Persisted property overrides are injected both in `didFinish` (via `injectProperties`) and again ~50ms later via the debounced `PropertyBridge.flush`. This can cause visual flicker.

- [ ] **O-12: MenuBarController rebuilds entire submenu on every open** — Acceptable at <10 wallpapers but worth noting.

- [ ] **O-13: WallpaperBundle.previewImageURL does directory listing on every access** — Should be cached.

- [ ] **O-14: WallpaperValidator creates a redundant WallpaperBundle** — Re-parses LivelyInfo/Properties JSON just to get `indexURL`.

- [ ] **O-15: pendingLock in ThumbnailRenderer is unnecessary** — All access to `pendingWebRenders` is already on the main queue. The lock adds overhead with no concurrency benefit.

- [ ] **O-16: WallpaperImporter singleton inconsistency** — `PreferencesWindowController.revealWallpaperFolder()` creates a new instance instead of using `.shared`.

---

## Priority Summary

| Priority | Item | Description |
|----------|------|-------------|
| ~~1~~ | ~~S-01~~ | ~~Path traversal in BundleSchemeHandler~~ **FIXED** |
| ~~2~~ | ~~S-02~~ | ~~Zip slip in archive extraction~~ **FIXED** |
| ~~3~~ | ~~S-06~~ | ~~No signature verification on auto-updates~~ **FIXED** |
| ~~4~~ | ~~S-05~~ | ~~Wallpapers have unrestricted network access~~ **FIXED** |
| 5 | O-01 | Import blocks main thread (most visible perf bug) |
| 6 | O-02/O-03 | WatchdogTimer lifecycle bugs (spurious failures) |
| 7 | O-07 | lockFocus on background threads (thread safety) |
| 8 | O-06/O-08/O-09 | Main-thread I/O in thumbnail cache, startup, image load |
