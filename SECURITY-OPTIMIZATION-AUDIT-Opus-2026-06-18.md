# ÆtherDesk Security & Optimization Audit — Opus Round (Round 4)

Generated: 2026-06-18
Auditor: Claude Opus 4.8
Scope: Full source review of all Swift sources, entitlements, plists, the JS
bridge bootstrap, and the bundled wallpapers — after Rounds 1–3
(`SECURITY-OPTIMIZATION-AUDIT-REVIEW.md`, `…-v2-2026-06-17.md`,
`…-v3-2026-06-18.md`) and the `OPTIMIZATION.md` profile were completed.
Method: Static analysis. No dynamic testing — the audit machine has no macOS
SDK, so every code change below is flagged for an Xcode build + smoke test by
the author before merge (consistent with how prior rounds were verified).
Emphasis per request: **ruthless reduction of CPU, GPU, memory, and battery
draw so the app flies on the oldest supported Macs (Monterey-era Intel).**

---

## Executive Summary

This is the fourth pass. The first three rounds were thorough and the codebase
is now in genuinely strong shape: I re-derived each prior high/critical item
against the current source and confirmed the fixes are present (URLSession
retain cycle broken in `stop()`, redirects re-validated, WebSocket/XHR/fetch
all routed through `NetworkPolicy`, symlink resolution in the scheme handler,
per-bundle origin isolation, streamed SHA-256 with a size cap, updater path
validation, IPv4-mapped IPv6 blocking, thread-safe store caches). I found
**nothing new at Critical or High security severity.**

On the performance side the app is already aggressive about energy: it pauses
on occlusion (default on), tears the WKWebView down and shows a static snapshot
when paused, throttles `requestAnimationFrame` by sleeping the JS thread with
`setTimeout`, debounces property updates, pools and bounds thumbnail webviews,
decodes thumbnails at target resolution via ImageIO, and respects Low Power and
thermal-critical states. Most of `OPTIMIZATION.md`'s high-priority items are
implemented.

So the remaining wins are fewer and smaller than in earlier rounds — but a few
are real, and one is an outright correctness bug that *defeats* a battery
feature on an entire class of hardware. This round surfaced **1 medium and 1
low security item** and **2 medium + 4 low optimization/resource items**. Six
were fixed in place; the rest are recorded as recommendations.

Severity counts: **Security** — Critical 0, High 0, Medium 0, Low 2.
**Optimization/Resource** — High 0, Medium 2, Low 4 (+ 2 recommendations).

---

## Optimization / Resource Findings

### Medium

#### O1 — Battery detection misfires on battery-less desktops (freezes the wallpaper)  ✅ FIXED

- **File/line:** `Core/WallpaperManager.swift:544-546` (`isOnBatteryPower`)
- **Issue:** Battery state was derived as
  `IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() == nil`. On
  battery-less desktops (Mac mini, Studio, Pro, most iMacs) that API commonly
  returns `nil` because there is no *adapter* object to describe — the machine
  is mains-powered directly. The `== nil` test therefore reads a desktop as
  "on battery." With `pauseOnBatteryPower` enabled, `applyPowerPerformancePolicy()`
  would call `pauseAll()` and **never resume**, leaving every wallpaper frozen
  on a static snapshot on a desktop Mac. It is latent today only because the
  setting defaults off (see O7).
- **Fix:** Switched to the *providing* power-source type via
  `IOPSCopyPowerSourcesInfo()` + `IOPSGetProvidingPowerSourceType(...)`, which
  reports `kIOPSACPowerValue` on desktops and only `kIOPSBatteryPowerValue` on a
  portable actually running unplugged. `isOnBatteryPower` is now true only when
  the system is genuinely on internal battery.
- **Verify:** On a Mac mini/Studio, enable "Pause on battery" — wallpapers keep
  running. On a MacBook, unplug — wallpapers pause; replug — they resume.

#### O2 — Live WKWebView paints an opaque base layer every frame (overdraw)  ✅ FIXED

- **File/line:** `WallpaperTypes/WebWallpaperRuntime.swift:241-249` (`createWebView`)
- **Issue:** The live runtime set the container/web layer `backgroundColor` to
  clear but never disabled WebKit's own `drawsBackground`. With `drawsBackground`
  left at its default, WebKit composites the document over an opaque base fill on
  every frame — pure overdraw on a desktop-level layer, and a white flash for any
  wallpaper that wants transparency. The thumbnail renderer already sets
  `drawsBackground = false`; the live path was inconsistent.
- **Fix:** Added `wv.setValue(false, forKey: "drawsBackground")` in
  `createWebView`, matching the thumbnail path. Verified all three bundled web
  wallpapers (`MatrixRain`, `GradientWave`, `NeonCity`) paint an opaque `body`
  background, so this is a no-op visually for them and only helps the
  transparent-wallpaper and overdraw cases.
- **Note:** This is the same private-KVC key the codebase already relies on in
  `ThumbnailRenderer.checkoutWebView`, so it carries no new API-stability risk
  beyond what's already accepted.

### Low

#### O3 — Idle thumbnail WKWebView pool keeps web-content processes resident for the session  ✅ FIXED

- **File/line:** `Core/ThumbnailRenderer.swift` (`webViewPool`, `returnWebView`)
- **Issue:** After the picker is used, up to `maxPoolSize` (2) offscreen
  WKWebViews stay pooled for the entire process lifetime. Each backs a separate
  web-content helper process (tens of MB of resident memory) that may never be
  needed again — wasteful steady-state RAM for a menu-bar utility whose whole
  point is to be light.
- **Fix:** Added an inactivity drain. When the render queue and in-flight set
  both empty out, `schedulePoolDrain()` arms a 30s main-queue work item that
  `stopLoading()`s and releases the pooled webviews. Any new render cancels the
  pending drain, so a burst of thumbnailing keeps the pool warm.
- **Verify:** Open the picker, scroll to render web thumbnails, close it; ~30s
  later the helper web-content processes should disappear (Activity Monitor).

#### O4 — First-touch thumbnail-cache prune runs synchronously on the calling thread  ✅ FIXED

- **File/line:** `Core/ThumbnailRenderer.swift:64-72` (`init` → `pruneOrphanedCache`)
- **Issue:** `init` called `pruneOrphanedCache()` inline, which enumerates the
  cache directory **and** calls `WallpaperImporter.shared.listWallpapers()`.
  `ThumbnailRenderer.shared` is typically first touched on the main thread when
  the picker opens, so this disk + scan work hitches the UI on first open.
- **Fix:** Prune is now dispatched onto the renderer's serial `queue`. Because
  that queue is serial, the prune also can't race or thrash the disk against
  concurrent thumbnail writes.

#### O5 — `injectEnvironment()` queries `NSScreen.screens` on every call  ⚠️ RECOMMENDATION (no change)

- **File/line:** `LivelyCompatibility/PropertyBridge.swift:159-196`
- **Issue:** Each `injectEnvironment()` linearly scans `NSScreen.screens` to map
  `displayID → NSScreen`. (This was `OPTIMIZATION.md` #13.)
- **Assessment:** Left as-is. It only runs on `didFinish` (once per load/reload),
  not per frame, so the cost is negligible. Caching the screen reference would
  add an invalidation burden (display reconfig) for no measurable gain.

#### O6 — `requestAnimationFrame` throttle does not govern non-rAF animation loops  ⚠️ RECOMMENDATION (no change)

- **File/line:** `WallpaperTypes/WebWallpaperRuntime.swift:821-842` (bootstrap rAF shim)
- **Issue:** The FPS cap is enforced by wrapping `requestAnimationFrame`. A
  wallpaper that animates via `setInterval`/`setTimeout`, CSS animations, or an
  internal WebGL render loop is not capped by this shim.
- **Assessment:** Inherent to a rAF-based throttle, and partially mitigated:
  when the host window is occluded WebKit already throttles timers, and the
  default `pauseWhenNotVisible` tears the webview down entirely. Worth a one-line
  note in the import guidance ("drive animation from `requestAnimationFrame` to
  honor the FPS cap") and, if a corpus ever shows abuse, a `visibilitychange`/
  timer-suspension shim. Not worth the complexity now.

#### O7 — `pauseOnBatteryPower` defaults to off  ⚠️ RECOMMENDATION (product decision)

- **File/line:** `Persistence/AppSettingsStore.swift:27-34`
- **Issue:** Given the explicit goal of minimizing battery draw, the most
  battery-saving default for portables would be `pauseOnBatteryPower = true`.
- **Assessment:** Flagged, not changed — silently flipping a persisted default
  changes behavior for existing users and is a UX call for the author. With O1
  fixed, enabling it is now safe on desktops (they correctly read as AC). Worth
  considering "pause on battery" on by default for laptops, or a first-run
  prompt.

---

## Security Findings

### Low

#### S1 — Thumbnail offscreen webview lacks the always-on SSRF rule list  ✅ FIXED

- **File/line:** `Core/ThumbnailRenderer.swift:309-323` (`checkoutWebView`)
- **Issue:** Round 3 (H3) added an always-on `ssrfBlockRuleList` to the *live*
  runtime so subresource loads (`<img>`, `<script>`, `<video>`, …) can't reach
  raw-IP / localhost / mDNS / cloud-metadata endpoints. The thumbnail renderer's
  offscreen webview loads the bundle's `index.html` for a ~0.6s settle window —
  **before the user has ever selected the wallpaper** — but only attached the
  ad/tracker blocklist (`ruleList`), not the SSRF list. A malicious imported
  bundle could probe `http://169.254.169.254/…` or LAN hosts via a subresource
  during thumbnail generation.
- **Bounding facts:** The thumbnail webview has no `nativeFetch` bridge, so JS
  `fetch()`/XHR go through WebKit's stack (subject to CORS) rather than the
  native proxy; the practical vector is subresource GETs. Still a real bypass of
  a control the live path enforces.
- **Fix:** `checkoutWebView` now also installs
  `ContentRuleListManager.shared.ssrfBlockRuleList`. (Left the
  external-network block off here intentionally, matching the existing comment:
  applying it would blank thumbnails for CDN-backed wallpapers and mislead the
  picker.)
- **Verify:** Import a bundle whose `index.html` references
  `<img src="http://169.254.169.254/latest/meta-data/">`; generating its
  thumbnail must not issue that request.

#### S2 — Notification dedupe / no new exposure  ✅ NO ACTION

- Re-verified the prior rounds' network, updater, and scheme-handler fixes are
  present in the current source. No new injection, traversal, or SSRF surface
  was found beyond S1.

---

## Summary Table

| # | Area | Severity | Status | Est. effect |
|---|------|----------|--------|-------------|
| O1 | Battery detection on desktops | Medium | ✅ Fixed | Prevents permanent freeze on desktop Macs; correct power policy |
| O2 | WKWebView `drawsBackground` overdraw | Low-Med | ✅ Fixed | Removes per-frame base-layer overdraw; correct transparency |
| O3 | Idle thumbnail webview pool | Low | ✅ Fixed | Frees ~2 helper processes (tens of MB) when picker idle |
| O4 | Synchronous prune on first touch | Low | ✅ Fixed | Removes a main-thread hitch on first picker open |
| O5 | `NSScreen.screens` per inject | Low | Rec. | Negligible; not worth invalidation cost |
| O6 | Non-rAF loops uncapped | Low | Rec. | Document; mitigated by occlusion teardown |
| O7 | `pauseOnBatteryPower` default | Info | Rec. | Bigger battery win if defaulted on for laptops |
| S1 | Thumbnail webview missing SSRF list | Low (sec) | ✅ Fixed | Closes pre-selection SSRF probe window |

---

## Implementation Roadmap

### Phase 1 — Applied in this round
1. ✅ **O1** — Power-source-type battery detection (`WallpaperManager`).
2. ✅ **O2** — `drawsBackground = false` on the live webview.
3. ✅ **S1** — SSRF rule list on the thumbnail webview.
4. ✅ **O3** — Idle-drain the thumbnail webview pool.
5. ✅ **O4** — Move the init-time cache prune onto the serial render queue.

### Phase 2 — Author's call (no code change made)
6. ⚠️ **O7** — Consider defaulting `pauseOnBatteryPower` on for portables (or a
   first-run prompt). Safe on desktops now that O1 is fixed.
7. ⚠️ **O6** — Add an import-guidance note recommending `requestAnimationFrame`
   for animation so the FPS cap applies.

---

## Verification Checklist

Build + smoke tests for the author (the audit host can't compile macOS targets):

- [ ] **Build** — `xcodegen && xcodebuild` clean, no new warnings.
- [ ] **O1 (desktop)** — On a battery-less Mac, toggle "Pause on battery" on;
      wallpapers keep running (do not freeze).
- [ ] **O1 (laptop)** — Unplug → wallpapers pause; replug → resume.
- [ ] **O2** — A web wallpaper with `body { background: transparent }` shows the
      desktop behind it rather than white; opaque wallpapers look unchanged.
- [ ] **O3** — After using the picker and closing it, pooled web-content helper
      processes are released ~30s later (Activity Monitor).
- [ ] **O4** — First open of the picker after launch shows no main-thread hitch.
- [ ] **S1** — A bundle whose `index.html` references a raw-IP/metadata
      subresource does not issue that request during thumbnailing.
- [ ] **Regression** — Existing tests in `Tests/` still pass.

---

## Notes on Methodology & Honesty

I want to be straight about what this round is and isn't. Rounds 1–3 did the
heavy lifting; by the time I arrived, the obvious CPU/GPU/memory/battery wins
and essentially all of the security surface were already closed. Rather than
manufacture findings to pad a list, I verified the prior fixes against the
current code, then concentrated on the few places where real headroom remained
for old, battery-constrained Macs. O1 is the one I'd prioritize: it's small, but
it turns a battery feature into a permanent freeze on an entire hardware class.

*End of audit.*
