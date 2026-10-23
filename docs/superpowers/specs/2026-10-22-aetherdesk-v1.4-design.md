# ÆtherDesk v1.4 — Design

Status: draft for review · 2026-10-22 · branch `v1.4` (cut from `main` at 9fbe20a)

## Intent

Bring ÆtherDesk to the discipline Tesserae received: reliable display
handling with real tests, the Digital Window shipped as the headline
feature, and a distribution pipeline (Sparkle, Homebrew, rebuilt release
script) at parity with Tesserae — in one release, v1.4.

**Success means:**

- Parts C, B and A are implemented on the `v1.4` branch, in that order.
- Every task has been reviewed; the full test gate (below) passes.
- A v1.3 user can update to v1.4 through the existing updater and
  thereafter receives updates through Sparkle.
- The App Store / TestFlight build keeps working, contains no Sparkle,
  and Premium behaves exactly as in v1.3.
- Nothing is merged, pushed, published or made public without the
  user's explicit go-ahead.

**Assumptions** (stated by the coordinator, accepted in brainstorming):
the App Store build stays in scope; v1.4 requires macOS 14.

## Current state (2026-10-22)

- v1.3 (build 40) shipped 2026-10-06 as a Developer ID-signed, notarized
  GitHub release (`AetherDesk.zip` + `AetherDesk.zip.sha256`), built by
  `./release`. App Store build is in TestFlight with Premium IAP.
- Baseline: `xcodebuild test -scheme AetherDesk` (unsigned) passes —
  106 Swift Testing tests in 10 suites (XCTest count reads 0; the gate
  must parse the Swift Testing summary, not the XCTest line).
- No open GitHub issues. Audit rounds 1–4 are fixed except O5–O7
  (recommendations).
- `codex/threejs-atmosphere`: 23 unmerged commits (+5.6k lines, last
  2026-08-10) — Three.js Digital Window renderer. `main` has moved 5
  commits since the merge base (`weather.js`, `atmosphere.js`,
  `WeatherKitBridge.swift`).
- `project.yml` was deliberately untracked in 6427303 (2026-05-12); the
  committed `ÆtherDesk.xcodeproj` is the source of truth. `./release`
  nevertheless still runs `xcodegen` from an untracked local file — a
  fresh clone cannot release.
- Base `MACOSX_DEPLOYMENT_TARGET` is 12.0; every target overrides to 14.0.
- 52 tracked files carry "All rights reserved" in their GPL header.

## Global decisions

- **Order:** C → B → A. C builds the test harness B and A lean on; A
  decides how v1.4 ships and must be exercised against a build containing
  C and B.
- **Project file:** the committed `.xcodeproj` remains the source of
  truth, honouring 6427303. All project changes are made to it directly.
  `./release` stops invoking `xcodegen`; version bumps edit the build
  settings in the project file.
- **Deployment target:** 14.0 everywhere, base included.
- **No new runtime dependencies** other than Sparkle (OSS build only).
  Node is a development tool for JS tests and the existing Three.js
  vendoring script; nothing at runtime requires it.
- **Lively compatibility is preserved** for every bundled wallpaper
  (`docs/TRUTH.md`).

---

## Part C — Reliability

### C1. Display reconciliation

Extract a pure `DisplayReconciler` from
`WallpaperManager.displayConfigurationDidChange`.

- **Inputs:** previous `DisplaySnapshot` set, current `DisplaySnapshot`
  set (each: `CGDirectDisplayID`, `DisplayIdentity`, frame), persisted
  assignments keyed by identity.
- **Output:** an ordered list of `DisplayAction`s — `createHost`,
  `tearDownHost`, `restoreAssignment`, `reframeHost`.
- `WallpaperManager` applies actions; it no longer computes diffs.
- Screen-parameter notifications are coalesced (≈250 ms debounce) into
  one reconcile.
- Resolution / arrangement change → `reframeHost` + geometry push to the
  running runtime; no runtime restart.
- A returning display is matched by identity, never by raw ID, and gets
  its persisted wallpaper.
- After `screensDidWake` or a lid-open reconcile, each live runtime gets
  a health check; a display demoted to safe mode gets exactly one
  restart attempt.

### C2. Display identity

- Primary key: the ColorSync display UUID
  (`CGDisplayCreateUUIDFromDisplayID`, ColorSync, macOS 10.4+ — confirmed
  in the installed SDK). Its stability across unplug/replug and reboot
  must be measured on real hardware during implementation; if it proves
  unstable, the plan records the evidence and falls back to the next key.
- Fallbacks, in order: `vendor:model:serial`, `vendor:model` + ordinal by
  frame origin (for identical serial-0 monitors), legacy `cgdisplay:<id>`.
- One-time migration maps existing persisted keys (`display:…`,
  `display:…:cgd:…`, `cgdisplay:…`, legacy numeric) to the new keys
  without losing assignments.

### C3. Defaults and audit cleanup

- `pauseOnBatteryPower` becomes a registered default of **true**; stored
  values are untouched (existing users keep their choice).
- **O5:** cache screen geometry for `injectEnvironment()`; the reconciler
  invalidates it. **O6** stays a documented recommendation.

### C4. Test backlog

- Synthetic fixtures under `Tests/Fixtures/` (no third-party content):
  web bundle with custom `FileName`, video, image, `.zip`, `.lively`;
  hostile: path traversal in `FileName`/`Preview`, symlink escape,
  zip bomb, malformed JSON.
- Tests: Lively parsers, resource resolution, import validator, property
  persistence, property-editor routing, identity migration, reconciler
  (hot-plug, wake, duplicate monitors, arrangement change, burst
  coalescing).

### C5. Manual verification (user)

A short checklist at the end of Part C: unplug/replug, lid close/open,
sleep/wake, resolution change, arrangement change. The coordinator cannot
perform these.

---

## Part B — Digital Window

### B1. Integrate the branch

- Rebase `codex/threejs-atmosphere` onto `v1.4` after Part C. Conflicts in
  `weather.js`, `atmosphere.js`, `WeatherKitBridge.swift` resolve to
  `main`'s behaviour (v1.3 forecast-day, location-race and conditions
  fixes), with the branch's renderer work layered on top.
- The renderer consumes the atmospheric state only
  (`docs/TRUTH.md` boundary); the shared condition matrix
  (`docs/WEATHER-CONDITION-MATRIX.md`) is the contract.

### B2. Fallback ladder

Three.js/WebGL → existing 2D Canvas renderer → static CSS gradient keyed
to the atmospheric state. WebGL init failure or runtime context loss
falls back immediately; Canvas failure falls to static. No path ends in
a black screen.

New `LivelyProperties` option **Renderer: Auto / Classic** (Auto = Three.js
when available; Classic forces Canvas).

### B3. Performance budget

- A measurement script drives the preview tool in a `WKWebView` through
  all nine states, day and night, sampling the web-content process's CPU
  and memory.
- **Budget (absolute, per quality tier; revised 2026-10-23 at the user's
  decision — the earlier "≤ 1.5 × Canvas" rule forced 8 fps rain and 0.45
  resolution):** on the reference Mac at the 30 fps cap, per state and
  phase, web-content CPU as % of one core and GPU utilisation:
  - **Balanced** (mains power): mean CPU ≤ 6%, p95 ≤ 10%, GPU mean ≤ 15%,
    with full-quality motion — precipitation and general motion at the
    30 fps cap, render scale ≥ 0.75. Only states over budget are trimmed,
    by particle count or cloud steps, never by motion cadence.
  - **Eco** (battery or Low Power Mode): mean CPU ≤ 3%, GPU mean ≤ 8%;
    reduced cadences allowed.
  - Memory flat (no monotonic growth) over a 10-minute soak.
  - The host bridge reports `system.onBattery` and sets `qualityMode` to
    `eco` on battery or Low Power Mode, `balanced` otherwise, updated live.
- Attempt to shrink the 522 KB vendored subset via tree-shaking; keep any
  reduction only if visual and behavioural tests still pass.

### B4. Tests

- `node:test` (no packages) for pure JS: every Open-Meteo WMO code and
  every WeatherKit condition maps to the right one of the nine states;
  intensity/intermittency are parameters, never states; renderer
  selection and fallback with a stubbed WebGL.
- Swift portability test: bundled WeatherAether has no remote
  script/style/font references, ships `vendor/THREE-LICENSE.txt`, and
  passes the app's own import validator.

### B5. Visual sign-off (user gate)

Before Part B is complete the user reviews all nine states, day and
night, in the preview build and approves or lists fixes. No reviewer
model substitutes for this.

### B6. NeonCity v3 (added 2026-10-22 at the user's request)

A ground-up rework of the bundled NeonCity wallpaper. The ÆtherDesk copy is
the source of truth; `~/src/NeonCityWallpaper` is out of scope.

- **Scene:** a seeded procedural 3D city (unique per machine, stable across
  launches). The camera drifts slowly at mid-height down a tower canyon
  toward the horizon. Three depth bands — near hero towers, mid city, far
  silhouettes in atmospheric haze.
- **Life, restrained:** spinner traffic on splines at several heights and
  ground light streams; signs that flicker, cycle, and occasionally have a
  dead tube; lit windows that thin out through the night; steam vents,
  sweeping searchlights, an occasional advertising blimp. No constant-speed
  decorative motion.
- **Time: Live / Always night.** Live follows the local clock — neon-dominant
  night, amber smog at dusk/dawn, grey wet day with neon dimmed but lit.
  Always night pins the scene at 03:00.
- **Weather: Live / Drifting (default) / Fixed.** Fixed uses the rain and fog
  sliders. Drifting is a seeded slow schedule over six states — clear,
  drizzle, rain, downpour, fog, snow — with multi-minute transitions and no
  network; snow occurs in Drifting only in December–February, and rarely.
  Live uses Open-Meteo through a copy of WeatherAether's location/weather
  code (including the `ipGeolocation` capability gate) and maps conditions
  onto the six states; snow codes show as snow.
- **Architecture:** time + weather → city-atmosphere state → renderer. Shared
  weather/location code is copied (wallpapers stay self-contained); a test
  fails if the copies diverge. Fallback ladder: Three.js → today's Canvas
  NeonCity retained as the Classic renderer → static image. Renderer:
  Auto / Classic property.
- **Properties:** time mode, weather mode, rain and fog (Fixed), neon
  brightness, traffic density, renderer, location mode / manual location
  (Live).
- **Licence:** NeonCity stays MIT. Veles is the user's own agent, so the user
  holds copyright of both NeonCity and the copied WeatherAether code; copied
  files carry an MIT header with the user's copyright line.
- **Look reference:** `docs/superpowers/references/neoncity-v3-mockup.html`
  (throwaway mock-up approved by the user 2026-10-22: "exactly what I was
  envisioning"). Neon blade signs, warm varied windows, amber-smog dusk,
  visible snow. It loads Three.js from a CDN and is never shipped. Known gap
  to fix in the real build: tower bodies need rim light so façades read at
  night.
- **Power (user requirement: "make sure it doesn't kill anyone's battery"):**
  - Glow uses additive sprites and emissive materials only — no full-screen
    post-processing passes.
  - Normal tier: ≤ 30 fps, render scale 0.75 of device pixels.
  - Saver tier, used on battery power or in Low Power Mode (when the app's
    pause-on-battery default is turned off): 15 fps, render scale 0.5,
    particle and traffic counts × 0.4, life events halved.
  - Adaptive: if the 95th-percentile frame time exceeds 20 ms over 10 s,
    step render scale down (0.75 → 0.6 → 0.5); step back up only after 60 s
    under 12 ms.
  - Host: uses the bridge's `system.onBattery` / `qualityMode` from B3
    (`eco` selects the saver tier).
  - Budget: the B3 absolute per-tier budget — normal tier as Balanced
    (CPU mean ≤ 6%, p95 ≤ 10%, GPU ≤ 15%), saver tier as Eco (CPU ≤ 3%,
    GPU ≤ 8%), memory flat over 10 minutes.
- **Tabled (not in v1.4):** police presence (patrol spinners, light bars)
  that scales with real local police activity. Recorded at the user's
  request 2026-10-22; needs a data-source and privacy design first.
- **Gates:** node tests for the time/weather state machine, the copy-drift
  test and the Lively portability test; the B3 performance harness extended
  with GPU sampling, enforcing the power budget above;
  user visual sign-off of night, dusk, day and Always night in each weather
  state, after a throwaway mock-up review.

---

## Part A — Distribution

### A1. Sparkle (OSS build only)

- Split the app into two targets sharing sources: **`AetherDesk`** (OSS)
  and **`AetherDesk-AppStore`**. Only the OSS target depends on Sparkle 2
  (SPM). The `AETHERDESK_STORE` condition remains for source-level
  differences.
- A check script runs on every App Store build: no `Sparkle.framework`
  in the bundle, no Sparkle in `otool -L`.
- In the OSS build, `SPUStandardUpdaterController` replaces
  `UpdateManager`'s download / codesign / swap / relaunch path, which is
  deleted. "Check for Updates…" calls Sparkle.
- One-time migration: `automaticallyCheckForUpdates` →
  Sparkle automatic checks; `automaticallyInstallUpdates` → Sparkle
  automatic download/install. `UpdateSettingsStore` is then retired.
- Appcast on GitHub Pages (`gh-pages` branch), EdDSA-signed,
  `SUPublicEDKey` in Info.plist. **The user generates and holds the key**
  (`generate_keys` writes to the login keychain).
- README and `docs/privacy.html` state what the update check sends (app
  and macOS version) and that it can be turned off.

### A2. v1.3 → v1.4 handover

- v1.3's updater installs only `AetherDesk.zip` (+ `.sha256`) from
  `releases/latest`, signed by team N5PUFD82GV. Every release keeps that
  asset; the same zip is the Sparkle enclosure. A DMG is added for manual
  download and Homebrew.
- Pre-publish proof: a test harness built from v1.3's `UpdateManager`
  source (tag `v1.3`) verifies hash, team and extraction of the v1.4 zip.
- Post-publish: a real v1.3 install updating to v1.4 is on the user's
  checklist.

### A3. Release pipeline

Split `./release` into **build** and **publish**, modelled on Tesserae's
`scripts/release.sh` / `publish.sh`.

- **build:** refuse a dirty tree; scrubbed environment; archive the OSS
  target; Developer ID sign; notarize and staple app and DMG; produce zip
  + `.sha256`; generate the appcast with pinned, checksummed Sparkle
  tools; verify the appcast signature.
- **publish:** dry-run by default, explicit confirmation; GitHub Release;
  commit appcast to `gh-pages` from a detached worktree; update the tap;
  verify served bytes.
- The App Store archive continues through Xcode.
- Secrets never printed, never committed; no home paths in tracked files.

### A4. Homebrew

`Casks/aetherdesk.rb` in `sdelavega/homebrew-tap`, generated from a
template in this repo: `auto_updates true`, `depends_on macos: :sonoma`,
`zap` paths taken from where the app actually writes (verified during
implementation, including `~/Library/Caches/com.sdelavega.ÆtherDesk`).

### A5. Licence

- Remove "All rights reserved" from all 52 headers.
- Sparkle (MIT) and Three.js (MIT) licences ship in the bundle and are
  listed in About.
- `CONTRIBUTING.md`: GPL-3 and App Store distribution coexist only
  because the author holds all copyright; outside contributions require
  agreement to that arrangement.

---

## Test gate

All must pass for the branch to be complete:

1. `xcodebuild test -scheme AetherDesk` (unsigned).
2. `node --test` over the WeatherAether JS tests.
3. App Store target builds; Sparkle-absence check passes.
4. StoreKit tests (`AetherDesk-AppStore` scheme) when the user's signing
   is available; otherwise reported as not run.
5. B3 performance budget met for WeatherAether and NeonCity (reports in the ledger).
6. Release **build** step succeeds in dry-run mode, including the v1.3
   handover harness.

User gates: C5 manual display checklist, B5 and B6 visual sign-off, Sparkle key
generation, and approval before any merge, push or publish.

## Out of scope

New wallpaper types, new Premium features, Mac App Store submission
mechanics, a homebrew-cask (core) submission, and audit O6.
