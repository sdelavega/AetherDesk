# ÆtherDesk v1.4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1.4: tested display reconciliation (Part C), the Three.js Digital Window with a fallback ladder (Part B), and Sparkle + Homebrew + a rebuilt release pipeline (Part A).

**Architecture:** Display handling moves into a pure `DisplayReconciler` that `WallpaperManager` executes. WeatherAether keeps the `docs/TRUTH.md` boundary (weather → atmospheric state → renderer) with Three.js → Canvas → static fallback. The app splits into OSS and App Store targets so only the OSS target links Sparkle.

**Tech Stack:** Swift 5.9, AppKit, WebKit, Swift Testing, Sparkle 2 (SPM, OSS target only), plain-script JavaScript tested with `node:test`, bash release scripts.

**Spec:** `docs/superpowers/specs/2026-10-22-aetherdesk-v1.4-design.md`

## Global Constraints

- Deployment target 14.0 for every target and the project base.
- `ÆtherDesk.xcodeproj` is the source of truth; do not reintroduce or track `project.yml`; do not run `xcodegen` against the tracked project.
- The project uses explicit file references, not synchronized folders: every new Swift file must be added to `project.pbxproj` for each target that compiles it. `AetherDeskTests` compiles `App/` (minus `main.swift`), `Core/`, `WallpaperTypes/`, `LivelyCompatibility/`, `Import/`, `UI/`, `Persistence/` directly — new files in those folders go in the app target(s) **and** `AetherDeskTests`.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Pass criterion is the line `Test run with N tests in M suites passed`; the XCTest "Executed 0 tests" line is meaningless here.
- No new runtime dependency except Sparkle 2, OSS target only. No npm packages in tests; `node:test` and `node:vm` only.
- Every bundled wallpaper stays self-contained and importable into Lively: no CDN, no remote script/style/font, no build step at runtime.
- No path may end in a black screen for WeatherAether.
- New source files start with the project's GPL-3 header **without** a restrictive copyright suffix: `// SPDX-License-Identifier: GPL-3.0-only` / `// Copyright (C) 2026 Stephen de la Vega` followed by the standard GPL notice used in existing files.
- Never print the environment, commit secrets, or commit absolute home paths. No sudo. No writes under `/Volumes/*`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Do not push, tag, publish, or create releases. Publishing steps are written and dry-run only.
- `scripts/test-gate.sh` (Task 1) must pass at the end of every task.

## Review Focus

1. **WeatherKit conditions that fall outside the nine states** (`wintryMix`→68, `sleet`→77, `strongStorms`→99, `smoky`/`haze`/`blowingDust`→4/5/7 in today's `wmoCode(for:)`). A user in sleet expects the freezing animation, not clear sky. Pinned by Task 10's matrix test.
2. **Two identical monitors that both report serial 0, unplugged and replugged in the opposite order.** The user expects each to keep its own wallpaper. Pinned by Task 3 and Task 4 tests.
3. **A display that returns with a different `CGDirectDisplayID` during the same session** (dock reconnect). The user expects the wallpaper that was there in this session, not the persisted one or the fallback. Pinned by Task 4.
4. **An existing v1.3 user's saved settings blob.** Their explicit `pauseOnBatteryPower: false` and update preferences must survive v1.4; only fresh installs get new defaults. Pinned by Tasks 1 and 16.
5. **WebGL context lost mid-session** (GPU switch, sleep). The wallpaper must keep drawing via Canvas without a reload or black frame. Pinned by Task 11.

---

## Phase C — Reliability

### Task 1: Test gate, deployment target, battery default

**Files:**
- Create: `scripts/test-gate.sh`
- Modify: `ÆtherDesk.xcodeproj/project.pbxproj` (base `MACOSX_DEPLOYMENT_TARGET` 12.0 → 14.0)
- Modify: `Persistence/AppSettingsStore.swift:27-47`
- Test: `Tests/PerformanceSettingsTests.swift`

**Interfaces:**
- Produces: `scripts/test-gate.sh [--with-js] [--with-appstore]` — exit 0 only if every enabled gate passes; later tasks add gates by appending stages, keeping flags backward-compatible.

- [ ] **Step 1: Write failing tests** in `PerformanceSettingsTests`:
  - `freshInstallPausesOnBattery`: `#expect(PerformanceSettings.defaults.pauseOnBatteryPower == true)`.
  - `blobMissingKeyPausesOnBattery`: decoding `{"fpsCap":30}` yields `pauseOnBatteryPower == true`.
  - `explicitFalseSurvives`: decoding a full v1.3 blob with `"pauseOnBatteryPower":false` yields `false`.
  - `storeWithoutDataReturnsDefaults`: `AppSettingsStore(userDefaults: UserDefaults(suiteName: <unique>)!)` → `loadPerformanceSettings().pauseOnBatteryPower == true`.
- [ ] **Step 2: Run, expect FAIL** (first two and fourth).
- [ ] **Step 3: Change the default** in `PerformanceSettings.defaults` and the `decodeIfPresent` fallback to `true`.
- [ ] **Step 4: Write `scripts/test-gate.sh`**: runs `xcodebuild test -project ÆtherDesk.xcodeproj -scheme AetherDesk -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath "${DERIVED_DATA:-build/gate}"`, tees to `build/gate.log`, fails unless the log contains `** TEST SUCCEEDED **` and a `Test run with [0-9]+ tests in [0-9]+ suites passed` line; prints that line. `set -euo pipefail`; no environment printing.
- [ ] **Step 5: Set base deployment target to 14.0** in `project.pbxproj` (every `MACOSX_DEPLOYMENT_TARGET = 12.0;`).
- [ ] **Step 6: Run `scripts/test-gate.sh`**, expect PASS with ≥110 tests.
- [ ] **Step 7: Commit** `Default pause-on-battery for fresh installs; add test gate`.

### Task 2: Display hardware info and identity candidates

**Files:**
- Modify: `Core/DisplayIdentity.swift`
- Create: `Core/DisplayHardwareInfo.swift`
- Create: `Tools/display-probe.swift` (standalone, `swift Tools/display-probe.swift`)
- Test: `Tests/DisplayIdentityTests.swift`

**Interfaces:**
- Produces:
  - `struct DisplayHardwareInfo: Equatable { let displayID: CGDirectDisplayID; let uuid: String?; let vendor: UInt32; let model: UInt32; let serial: UInt32; let frame: CGRect }`
  - `static func DisplayHardwareInfo.live(_ id: CGDirectDisplayID, frame: CGRect) -> DisplayHardwareInfo` (uses `CGDisplayCreateUUIDFromDisplayID`, ColorSync)
  - `static func DisplayIdentity.candidates(for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo]) -> [DisplayIdentity]` — most-preferred first.
  - `DisplayIdentity.primary(for:among:) -> DisplayIdentity` = `candidates(...).first!`

Candidate order (each included only when its inputs are non-zero / non-nil):
1. `uuid:<UUID>`
2. `display:<vendor>:<model>:<serial>` (serial ≠ 0)
3. `display:<vendor>:<model>:ord:<n>` — `n` = index of this display among displays with the same vendor+model, sorted by `frame.origin.x`, then `frame.origin.y`
4. `display:<vendor>:<model>:cgd:<displayID>` (legacy v1.3 form, serial = 0)
5. `cgdisplay:<displayID>` (legacy)
6. `<displayID>` (legacy numeric)

- [ ] **Step 1: Write failing tests:** UUID present → first candidate `uuid:…`; serial-0 twins at x=0 and x=1920 → ordinals 0 and 1 regardless of input array order; vendor=model=0 → candidates are exactly `[cgdisplay:<id>, <id>]` (plus `uuid:` if present); legacy `cgd:` and numeric keys always present so v1.3 data is findable.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the struct, `live`, and `candidates`. Keep `forDisplay`, `legacy`, `legacyNumeric` only if still referenced after Task 3; otherwise delete.
- [ ] **Step 4: Write `Tools/display-probe.swift`** printing, per active display: ID, UUID, vendor, model, serial, frame, and `primary` key. Used for the C5 UUID-stability measurement.
- [ ] **Step 5: Run gate, expect PASS. Commit** `Add display identity candidates with ColorSync UUID`.

### Task 3: WallpaperStore keyed by identity candidates

**Files:**
- Modify: `Persistence/WallpaperStore.swift`
- Modify: `Tests/WallpaperStoreTests.swift`

**Interfaces:**
- Consumes: `DisplayHardwareInfo`, `DisplayIdentity.candidates(for:among:)` (Task 2).
- Produces:
  - `func setAssignment(bundleID: UUID, for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo])` — writes under the primary key, removes every other candidate key for that display.
  - `func removeAssignment(for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo])`
  - `func loadAssignments(for displays: [DisplayHardwareInfo]) -> [CGDirectDisplayID: UUID]` — first matching candidate wins; a match found under a non-primary key is rewritten under the primary key (write-through migration) in the same call.
  - Storage key stays `AetherDesk.wallpaperStore.v2`.

- [ ] **Step 1: Write failing tests:** v1.3 payload with `display:1:2:cgd:5` → found and migrated to `uuid:…`; v1.3 payload with numeric `"5"` → found; twins: assign A to ord 0 and B to ord 1, then load with the two infos' displayIDs swapped but frames kept → A stays at x=0; a match is migrated exactly once (second load reads the primary key, legacy keys gone); `pruneMissing` still drops unknown bundle IDs.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; update the callers in `WallpaperManager` mechanically (behavioral rewiring is Task 5).
- [ ] **Step 4: Gate PASS. Commit** `Key wallpaper assignments by display identity candidates`.

### Task 4: DisplayReconciler

**Files:**
- Create: `Core/DisplayReconciler.swift`
- Test: `Tests/DisplayReconcilerTests.swift`

**Interfaces:**
- Consumes: `DisplayHardwareInfo`, `DisplayIdentity` (Task 2).
- Produces:

```swift
struct DisplaySnapshot: Equatable { let info: DisplayHardwareInfo; let identity: DisplayIdentity }
enum RestoreSource: Equatable { case session(UUID), persisted, fallback }
enum DisplayAction: Equatable {
    case tearDownHost(CGDirectDisplayID)
    case createHost(CGDirectDisplayID, frame: CGRect)
    case restore(CGDirectDisplayID, RestoreSource)
    case reframeHost(CGDirectDisplayID, frame: CGRect)
}
enum DisplayReconciler {
    static func reconcile(previous: [DisplaySnapshot],
                          current: [DisplaySnapshot],
                          sessionBundles: [DisplayIdentity: UUID]) -> [DisplayAction]
}
```

Rules: ordering is all `tearDownHost` (by ascending ID), then for each added display `createHost` then `restore`, then `reframeHost` for kept displays whose frame changed. A display is "kept" when the same `CGDirectDisplayID` **and** identity are in both snapshots. A display whose ID is reused with a different identity is torn down and re-created. Restore source: `.session(id)` if `sessionBundles[identity]` exists, else `.persisted`. (`.fallback` is decided by the manager when persistence has nothing.) Identical inputs → `[]`.

- [ ] **Step 1: Write failing tests:** no change → `[]`; unplug one of two → one `tearDownHost`; replug same identity, new ID, in session → `createHost` + `restore(.session)`; new display, nothing in session → `restore(.persisted)`; resolution change → only `reframeHost`; ID reused by different monitor → teardown + create; twins swapped (identities follow frames) → each identity restored from session to its own bundle; action ordering as specified.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: Gate PASS.**
- [ ] **Step 5: Commit** `Add pure display reconciler`.

### Task 5: Wire reconciler into WallpaperManager; geometry cache (O5)

**Files:**
- Create: `Core/DisplayChangeCoalescer.swift`
- Create: `Core/DisplayGeometryCache.swift`
- Modify: `Core/WallpaperManager.swift` (`displayConfigurationDidChange`, `start`, `startAndRestore`, `currentBundles`, `setWallpaper`, `updateProperty`)
- Modify: `Core/DisplayManager.swift` (expose `func hardwareInfo() -> [DisplayHardwareInfo]`)
- Modify: `Core/WallpaperRuntime.swift`, `WallpaperTypes/WebWallpaperRuntime.swift`, `WallpaperTypes/ImageWallpaperRuntime.swift`, `LivelyCompatibility/PropertyBridge.swift:160-170`
- Test: `Tests/DisplayChangeCoalescerTests.swift`, `Tests/DisplayGeometryCacheTests.swift`

**Interfaces:**
- Consumes: `DisplayReconciler.reconcile` (Task 4), `WallpaperStore.loadAssignments(for:)` (Task 3).
- Produces:
  - `final class DisplayChangeCoalescer { init(delay: TimeInterval = 0.25, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable); func signal(); var onFire: (() -> Void)? }` — N signals within `delay` of the last one → exactly one `onFire`. `protocol Cancellable { func cancel() }`.
  - `final class DisplayGeometryCache { static let shared; func geometry(for id: CGDirectDisplayID) -> (frame: CGRect, scale: CGFloat, isPrimary: Bool)?; func update(_ entries: [CGDirectDisplayID: (CGRect, CGFloat, Bool)]); func invalidate() }`
  - `WallpaperRuntime.displayGeometryDidChange()` with a protocol-extension no-op default; `WebWallpaperRuntime` re-runs `propertyBridge.injectEnvironment()`.
  - `WallpaperManager.currentBundles` becomes `[DisplayIdentity: WallpaperBundle]`; public `currentBundle(for displayID:)` keeps its signature.

- [ ] **Step 1: Write failing tests:** coalescer — 5 signals at 0/50/100/150/200 ms with a manual scheduler → one fire 250 ms after the last; geometry cache — `invalidate()` empties it; `update` then `geometry(for:)` round-trips.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement coalescer and cache.**
- [ ] **Step 4: Rewire `displayConfigurationDidChange`** to: `signal()` the coalescer; on fire, build snapshots from `displayManager.hardwareInfo()`, update the geometry cache, call `reconcile`, and apply each action (`restore(.persisted)` → background `loadAssignments` then fallback, as today). `reframeHost` calls `host.setFrame` and `runtime.displayGeometryDidChange()`. `PropertyBridge.injectEnvironment` and `ImageWallpaperRuntime` read the cache, falling back to `NSScreen.screens` only on a miss.
- [ ] **Step 5: Gate PASS.** Manually launch the OSS build once and confirm wallpapers appear on all displays.
- [ ] **Step 6: Commit** `Drive display changes through reconciler with coalescing`.

### Task 6: Wake health check, single safe-mode retry, manual checklist

**Files:**
- Create: `Core/SafeModeRetryPolicy.swift`
- Modify: `Core/WallpaperManager.swift` (`screenDidWake`, `runtimeDidFail`, `installSafeModeContent`, `setWallpaper`)
- Create: `docs/superpowers/checklists/v1.4-display-manual.md`
- Test: `Tests/SafeModeRetryPolicyTests.swift`

**Interfaces:**
- Produces: `struct SafeModeRetryPolicy { mutating func shouldRetry(_ identity: DisplayIdentity) -> Bool; mutating func recordDemotion(_ identity: DisplayIdentity); mutating func reset(_ identity: DisplayIdentity) }` — after a demotion, the first wake returns `true`, later wakes `false` until `reset` (called when the user sets a wallpaper on that display).

- [ ] **Step 1: Write failing tests:** demote → wake → `true`; wake again → `false`; `reset` → demote → wake → `true`; never-demoted → `false`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement, and wire `screenDidWake`** to signal the coalescer (no direct `ensureHost` loop), then for each demoted display where `shouldRetry` → `setWallpaper(lastBundle)`.
- [ ] **Step 4: Write the manual checklist**: unplug/replug, lid close/open, sleep/wake, resolution change, arrangement change, identical twins swap, plus "run `swift Tools/display-probe.swift` before and after replug and reboot; record whether `uuid:` keys match". Each item: action, expected result, pass/fail box.
- [ ] **Step 5: Gate PASS. Commit** `Retry demoted displays once after wake; add manual display checklist`.

### Task 7: Importer test seam and synthetic fixtures

**Files:**
- Modify: `Import/WallpaperImporter.swift:60-80` (init)
- Create: `Tests/Fixtures/` (directory bundles listed below)
- Create: `Tests/Support/Fixtures.swift`
- Test: `Tests/WallpaperImporterTests.swift`

**Interfaces:**
- Produces:
  - `init(fileManager: FileManager = .default, wallpapersDirectory: URL? = nil, bundledWallpapersDirectory: URL? = nil)` — nil keeps current behaviour; `shared` unchanged.
  - `enum Fixtures { static func url(_ name: String) -> URL; static func archive(_ name: String, as ext: String) throws -> URL }` — locates `Tests/Fixtures` via `#filePath`; `archive` zips a fixture directory with `/usr/bin/ditto -c -k --sequesterRsrc` into a temp dir and renames to `.zip`/`.lively`.
- Fixture directories: `web-custom-filename/` (`FileName: "main.html"`), `video/` (tiny generated mp4 ≤ 50 KB), `image/` (PNG ≤ 10 KB), `traversal-filename/` (`FileName: "../../etc/hosts"`), `traversal-preview/` (`Preview: "../secret.png"`), `malformed-json/` (truncated `LivelyInfo.json`). The symlink-escape and zip-bomb cases are built at test time (symlink to `/etc` inside a temp copy; 200 MB of zeros zipped), never committed.

- [ ] **Step 1: Write failing tests:** custom `FileName` imports and resolves `main.html`; `.zip` and `.lively` of `web-custom-filename` import identically; traversal `FileName` and `Preview` are rejected or resolve inside the bundle (assert the resolved URL has the bundle root as prefix); symlink escape is rejected; zip bomb is rejected with the importer's size error and leaves no files in the temp library; malformed JSON is rejected with a parse error, no crash. All imports target a temp `wallpapersDirectory`.
- [ ] **Step 2: Run, expect FAIL** (seam missing). **Step 3: Add the init seam.**
- [ ] **Step 4: Run.** Any newly exposed real bug: fix it in this task, with the test that exposed it.
- [ ] **Step 5: Gate PASS. Commit** `Add importer fixtures and hostile-input tests`.

### Task 8: Property-editor routing tests

**Files:**
- Modify: `Core/WallpaperManager.swift` (test seam only if needed: `init(displayManager:wallpaperStore:propertyStore:runtimeFactory:)`)
- Test: `Tests/PropertyRoutingTests.swift`

**Interfaces:**
- Consumes: `currentBundles` keyed by identity (Task 5).
- Produces: `typealias RuntimeFactory = (WallpaperBundle, CGDirectDisplayID) throws -> WallpaperRuntime`; default factory is today's `makeRuntime`.

- [ ] **Step 1: Write failing tests** with a fake runtime recording `updateProperty` calls: `updateProperty(_:value:forBundleID:)` reaches only displays running that bundle; `updateProperty(_:value:for:)` reaches only that display; both persist the override to `PropertyStore` for the right bundle ID; a display in safe mode receives nothing and doesn't crash.
- [ ] **Step 2: Run, expect FAIL** (no seam). **Step 3: Add the seam.** **Step 4: Gate PASS.**
- [ ] **Step 5: Commit** `Test property routing per display and per bundle`.

**Phase C exit:** coordinator gives the user `docs/superpowers/checklists/v1.4-display-manual.md`; results go in the ledger. A failed UUID-stability measurement changes Task 2's candidate order (drop `uuid:` to last) before Phase B starts.

---

## Phase B — Digital Window

### Task 9: Integrate `codex/threejs-atmosphere`

**Files:** the branch's 16 files (see `git diff --stat main...codex/threejs-atmosphere`).

- [ ] **Step 1:** `git rebase --onto v1.4 $(git merge-base main codex/threejs-atmosphere) <local copy of codex/threejs-atmosphere>` on a scratch branch `v1.4-dw`; do not modify the original branch.
- [ ] **Step 2: Resolve conflicts** in `weather.js`, `atmosphere.js`, `main.js`, `WeatherKitBridge.swift` keeping `main`'s v1.3 behaviour (location-race fix, forecast days, conditions, provider attribution) and layering the renderer changes on top. The branch's `project.pbxproj` commit is re-applied only if the vendor files aren't already covered by the `Resources/Wallpapers` folder reference.
- [ ] **Step 3:** Gate PASS. Run the OSS build with WeatherAether as the wallpaper and confirm from the app log that `reportWeatherRendererStatus` reports the Three.js renderer.
- [ ] **Step 4:** Fast-forward `v1.4` to `v1.4-dw`. Record the conflict resolutions in the ledger.

### Task 10: Condition-matrix tests (JS and Swift)

**Files:**
- Create: `Core/WeatherConditionMap.swift` (compiled in all targets)
- Modify: `Core/WeatherKitBridge.swift` (`wmoCode(for:)` delegates to the map)
- Create: `Tests/JS/harness.mjs`, `Tests/JS/atmosphere.test.mjs`
- Test: `Tests/WeatherConditionMapTests.swift`
- Modify: `scripts/test-gate.sh` (add `--with-js`: `node --test Tests/JS/`)

**Interfaces:**
- Produces:
  - `enum WeatherConditionMap { static func wmoCode(forRawCondition raw: String) -> Int }` — raw values are `WeatherCondition.rawValue` strings, verified against the SDK's WeatherKit `.swiftinterface`; unknown → 0.
  - `harness.mjs`: `export function loadWeatherAether(files: string[], stubs?: object): vm.Context` — evaluates the wallpaper's plain scripts in one `vm` context with minimal `window`/`document` stubs.

- [ ] **Step 1: Write failing JS tests:** for every WMO code in `WMO_DESC` plus 4, 5, 7, 68, `wmoBucket(code)` equals the matrix in `docs/WEATHER-CONDITION-MATRIX.md`; the result is always one of the nine states; `deriveAtmosphericState` for codes 61/63/65 yields the same state with increasing precipitation intensity (intensity is a parameter, not a state).
- [ ] **Step 2: Write failing Swift tests:** for every WeatherKit condition, `wmoCode(forRawCondition:)` returns a code whose matrix state (via the JS-pinned WMO table) is the one `docs/WEATHER-CONDITION-MATRIX.md` assigns. Specifically: `wintryMix`, `sleet` → a freezing code (56/57/66/67); `strongStorms`, `tropicalStorm`, `hurricane` → 95; `hail` → 96; `smoky`, `haze` → 45 (fog), `blowingDust` → 3 (overcast); `breezy`, `windy`, `hot`, `frigid` → 1. Update the matrix doc's fold rules to state these choices.
- [ ] **Step 3: Run, expect FAIL.** **Step 4: Implement the map; fix the mappings the tests expose.**
- [ ] **Step 5: `scripts/test-gate.sh --with-js` PASS. Commit** `Pin weather condition matrix in JS and Swift tests`.

### Task 11: Fallback ladder and Renderer property

**Files:**
- Modify: `Resources/Wallpapers/WeatherAether/js/three-renderer.js` (`initializeThreeAtmosphere`, context-loss handling)
- Modify: `Resources/Wallpapers/WeatherAether/js/bootstrap.js`, `js/renderer.js`
- Create: `Resources/Wallpapers/WeatherAether/js/static-fallback.js`
- Modify: `Resources/Wallpapers/WeatherAether/index.html`, `LivelyProperties.json`
- Test: `Tests/JS/fallback.test.mjs`

**Interfaces:**
- Produces:
  - `function selectRenderer(env: {rendererPref: 'auto'|'classic', webgl: boolean, canvas2d: boolean}) -> 'three'|'canvas'|'static'`
  - `function demoteRenderer(reason: string)` — three → canvas → static; idempotent; reported via `reportWeatherRendererStatus`.
  - `function applyStaticAtmosphere(atmosphere)` — sets a CSS gradient on `#wa-sky`'s container from the atmospheric state's colours.
  - LivelyProperties entry: `{"Name":"renderer","Description":"Renderer","Type":"dropdown","Value":"auto","Items":["auto","classic"]}`.

- [ ] **Step 1: Write failing tests:** `selectRenderer` truth table (auto+webgl → three; auto+no webgl → canvas; classic → canvas; no canvas2d → static); `webglcontextlost` on the Three canvas → `demoteRenderer` called once, the next frame draws via Canvas; Canvas `getContext('2d')` returning null → static gradient applied; changing the `renderer` property at runtime switches without reload.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** Canvas must not be torn down while Three runs, so demotion is instant.
- [ ] **Step 4: Gate (`--with-js`) PASS. Commit** `Add WeatherAether fallback ladder and renderer property`.

### Task 12: Lively portability test

**Files:**
- Test: `Tests/WeatherAetherPortabilityTests.swift`

- [ ] **Step 1: Write the test** over `Resources/Wallpapers/WeatherAether` (located via `#filePath`): no `<script src=`, `<link href=`, `@import`, or `url(` referencing `http:`, `https:` or `//`; every local `src`/`href` in `index.html` exists on disk (query strings stripped); `vendor/THREE-LICENSE.txt` exists; `WallpaperValidator().validate(at:)` is not a blocked classification.
- [ ] **Step 2: Run; it should PASS on correct code.** Prove it bites: temporarily add `<script src="https://cdn.example/x.js">` to a temp copy and assert failure in a second test using that copy.
- [ ] **Step 3: Gate PASS. Commit** `Test WeatherAether stays Lively-portable`.

### Task 12a: Host capability gate for IP geolocation; licence metadata

(Added 2026-10-22 at the user's approval, requested by the Lumenfall project, which vendors WeatherAether verbatim.)

**Files:**
- Modify: `Resources/Wallpapers/WeatherAether/js/weather.js` (`autoLocation`, `fetchIP`, `reverseGeocode`, `fallbackLoc`)
- Modify: `WallpaperTypes/WebWallpaperRuntime.swift` (bridge `system` object)
- Modify: `Resources/Wallpapers/{WeatherAether,GradientWave,MatrixRain}/LivelyInfo.json`
- Test: `Tests/JS/location.test.mjs`

**Interfaces:**
- Produces: `window.aetherDesk.system.capabilities = { ipGeolocation: true }` set by the macOS host bridge; `function hasHostCapability(name: string) -> boolean` in `weather.js` (false when `window.aetherDesk` or `capabilities` is absent).

- [ ] **Step 1: Write failing tests** (harness from Task 10): with the capability absent, auto mode tries `navigator.geolocation` → cached location → shows the notice "Set a city in this wallpaper's settings", and makes **no** request to `ipapi.co` or `api.bigdatacloud.net` (stub `fetch` records URLs); place label is the Open-Meteo geocoding name in manual mode, otherwise rounded coordinates or "Current location". With `ipGeolocation: true`, today's ipapi.co / BigDataCloud paths run unchanged.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement.** The Swift bridge's `system` literal gains `capabilities: { ipGeolocation: true }`.
- [ ] **Step 4:** Add `"License": "GPL-3.0-only"` to the three ÆtherDesk-authored `LivelyInfo.json` files (NeonCity already declares MIT; leave it).
- [ ] **Step 5: Gate (`--with-js`) PASS. Commit** `Gate IP geolocation behind host capability; declare wallpaper licences`.

### Task 13: Performance measurement and budget

**Files:**
- Create: `Tools/WeatherPerf/main.swift`, `Tools/WeatherPerf/build.sh`
- Create: `scripts/check-weather-perf.sh`

**Interfaces:**
- Produces: `Tools/WeatherPerf/build.sh` → `build/WeatherPerf`; running it with `--renderer auto|classic --seconds 30 --out <json>` loads `Tools/WeatherAetherPreview.html` in an offscreen-but-visible `WKWebView` (1920×1080, 30 fps cap via the same rAF throttle the bridge injects), steps through the nine states × day/night, and samples the newest `com.apple.WebKit.WebContent` process's CPU (`ps -o %cpu=`) and RSS once per second. JSON: `{state, phase, renderer, cpuMean, cpuP95, rssStart, rssEnd}[]`. A `--soak 600` mode holds one state and records RSS every 10 s.
- `scripts/check-weather-perf.sh` runs both renderers, fails if any state's `three.cpuMean > 1.5 × canvas.cpuMean`, or if the soak's RSS rises monotonically by more than 10% from minute 1 to minute 10; writes `build/weather-perf.md`. (Superseded by Task 13y's absolute per-tier budget.)

- [ ] **Step 1: Build and run** both renderers; record baseline numbers in the ledger.
- [ ] **Step 2:** For each over-budget state, tune (particle counts, resolution scale, shadow/draw-call reductions) inside `three-renderer.js` without changing the atmospheric-state contract. Re-run.
- [ ] **Step 3: Attempt bundle shrink:** narrow `Tools/WeatherAetherThreeEntry.js` exports to what `three-renderer.js` uses; rebuild with `Tools/build-weather-three.sh`; keep only if Tasks 10–12 tests and the perf check still pass. Record before/after size.
- [ ] **Step 4: `scripts/check-weather-perf.sh` PASS; gate PASS. Commit** `Measure and enforce WeatherAether performance budget`.

### Task 13y: Absolute per-tier budget; restore balanced motion quality

(Added 2026-10-23: the user replaced the relative 1.5 × Canvas budget with absolute per-tier budgets — spec B3.)

**Files:**
- Modify: `Resources/Wallpapers/WeatherAether/js/three-renderer.js` (quality profiles), `js/renderer.js`
- Modify: `LivelyCompatibility/PropertyBridge.swift` (`injectEnvironment`), `Core/WallpaperManager.swift` (re-inject on power changes)
- Modify: `Tools/WeatherPerf/main.swift` (GPU sampling; `--quality balanced|eco`), `scripts/check-weather-perf.sh`, `Tests/JS/weather-perf-budget.test.js`
- Test: `Tests/PowerEnvironmentTests.swift`, `Tests/JS/weather-render-cadence.test.js`

**Interfaces:**
- Produces:
  - Bridge `system.onBattery: boolean`; `system.qualityMode: 'eco'|'balanced'` — `eco` when on battery power or Low Power Mode. `static func PropertyBridge.qualityMode(onBattery: Bool, lowPower: Bool) -> String`. Re-injected into running web wallpapers when the power source or Low Power Mode changes.
  - WeatherAether picks its quality profile from `system.qualityMode` (falling back to `balanced` when absent, e.g. in Lively).
  - Harness samples GPU once per second from `ioreg -r -d 1 -c IOAccelerator` (`PerformanceStatistics` → `Device Utilization %`; no sudo) and runs each state × phase per tier.
  - `check-weather-perf.sh` budget: Balanced mean CPU ≤ 6.0, p95 ≤ 10.0, GPU mean ≤ 15.0; Eco mean CPU ≤ 3.0, GPU mean ≤ 8.0; soak RSS not rising > 10% minute 1 → 10. The Canvas run is kept as a recorded reference only, no longer a gate.

- [ ] **Step 1: Write failing tests:** `qualityMode` mapping (4 combinations); balanced profile restores render scale ≥ 0.75, precipitation and general motion at the 30 fps cap (no 8 fps rain); eco keeps Task 13's reduced cadences; WeatherAether reads `system.qualityMode`; budget script passes/fails on synthetic JSON at each threshold.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement.** Keep Task 13's efficiency wins (quiet-sky caching, independent precipitation deadline, foreground resolution scaling). Trim only over-budget Balanced states, by particle count or cloud steps — never motion cadence or render scale below 0.75.
- [ ] **Step 4: Full measurement both tiers + 10-minute soak; record tables and the reference Mac model in the ledger and report.**
- [ ] **Step 5: Gate (`--with-js`) and `scripts/check-weather-perf.sh` PASS. Commit** `Budget WeatherAether per quality tier and restore smooth motion`.

### Task 13x: Fix lower-left triangle artifact

(Reported 2026-10-22 by Lumenfall: Android WebView, 2560×1600 landscape, Three.js renderer, night, no location — a static dark-slate triangle from the bottom-left corner, ~20% of the width × ~15% of the height. Screenshot outside the repo; description is sufficient.)

**Files:** `Resources/Wallpapers/WeatherAether/js/three-renderer.js` and/or `js/renderer.js`, `Tools/WeatherPerf` (reuse its WKWebView to render a frame), Test: `Tests/JS/` or a harness snapshot check.

- [ ] **Step 1: Reproduce** at 2560×1600 and other aspect ratios (16:10, 21:9, 4:3, portrait) in both quality tiers; capture a frame and locate the cause.
- [ ] **Step 2: Write a failing regression check** that pins the cause (e.g. a geometry/viewport invariant in node:vm, or a pixel check on a captured frame's lower-left region).
- [ ] **Step 3: Fix. Step 4: Gate PASS. Commit** `Fix stray triangle in WeatherAether's lower-left corner`.

### Task 13a: NeonCity restructure and city-atmosphere state

(Tasks 13a–13e implement spec B6, added 2026-10-22.)

**Files:**
- Create: `Resources/Wallpapers/NeonCity/js/classic-renderer.js` (today's `index.html` script, moved verbatim apart from reading the new state)
- Create: `Resources/Wallpapers/NeonCity/js/city-state.js`, `js/main.js`
- Modify: `Resources/Wallpapers/NeonCity/index.html`, `LivelyProperties.json`
- Create: `Resources/Wallpapers/NeonCity/LICENSE.txt` — standard MIT text with `Copyright (c) 2026 Stephen de la Vega` (Veles is the author's own agent; requested by Lumenfall, which vendors the folder verbatim)
- Test: `Tests/JS/neoncity-state.test.mjs`

**Interfaces:**
- Produces:
  - `function deriveCityState(input: {now: Date, timeMode: 'live'|'night', weatherMode: 'live'|'drifting'|'fixed', fixed: {rain: number, fog: number}, live: {state: WeatherState, intensity: number}|null, seed: number}) -> CityState`
  - `WeatherState` = `'clear'|'drizzle'|'rain'|'downpour'|'fog'|'snow'`
  - `CityState` = `{ phase: 'night'|'dusk'|'day'|'dawn', phaseBlend: number, weather: WeatherState, rain: number /*0–1*/, fog: number /*0–1*/, neon: number /*0–1*/, windowsLit: number /*0–1*/, trafficDensity: number /*0–1*/ }`
  - `function driftingWeather(seed: number, now: Date) -> {state: WeatherState, rain: number, fog: number}` — deterministic in (seed, now); state dwell ≥ 20 min; transitions blend over ≥ 3 min; `snow` only when local month is December, January or February, with probability ≤ 10% per state change.
  - Phases for `timeMode:'live'`: night 21:00–05:00, dawn 05:00–07:00, day 07:00–18:00, dusk 18:00–21:00, local time. `timeMode:'night'` → phase `night` at 03:00 regardless of `now`.
- LivelyProperties (keeping the file's existing object format): `timeMode` dropdown [Live, Always night] default Live; `weatherMode` dropdown [Drifting, Live, Fixed] default Drifting; existing `rainIntensity`, `fogDensity`, `neonBrightness`, `vehicleCount` (renamed text "Traffic Density", same key); `renderer` dropdown [Auto, Classic] default Auto; `locationMode`/`manualLocation` as in WeatherAether.

- [ ] **Step 1: Write failing tests:** phase boundaries at 04:59/05:00/06:59/07:00/17:59/18:00/20:59/21:00; Always night at noon → `night`; `driftingWeather` deterministic for same (seed, now), never changes state within 20 min of a change, blends rain/fog continuously across a transition (no step > 0.05 per simulated second); never yields `snow` in June over 10,000 simulated draws, and yields it at least once in January; `fixed` mode passes slider values through (rain 60 → 0.5 on a 0–120 slider; fog 30 → 0.3); `windowsLit` decreases monotonically from 21:00 to 04:00.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement**; move the current scene into `classic-renderer.js` reading `CityState` for rain, fog, neon, traffic. Classic visual output in Fixed + Always night with default sliders must match today's scene.
- [ ] **Step 4: Gate (`--with-js`) PASS. Commit** `Restructure NeonCity around a city-atmosphere state`.

### Task 13b: NeonCity live weather via copied WeatherAether modules

**Files:**
- Create: `Resources/Wallpapers/NeonCity/js/weather-shared/` (copies of the WeatherAether location/weather functions NeonCity needs, MIT header)
- Create: `scripts/sync-shared-weather.sh`
- Test: `Tests/JS/shared-weather-drift.test.mjs`, `Tests/JS/neoncity-live-weather.test.mjs`

**Interfaces:**
- Produces: `function mapWmoToCityWeather(code: number, precipMm: number) -> {state: WeatherState, intensity: number}` — fog 45/48 → fog; drizzle 51–55 → drizzle; rain 61–63, 80–81 → rain; 65, 82, 95–99 → downpour; snow 71–77, 85–86 → snow; freezing 56–57, 66–67 → rain; 0–3 → clear.
- `scripts/sync-shared-weather.sh` copies the designated function bodies from WeatherAether into `weather-shared/` with the MIT header; the drift test re-derives the copies' bodies (header stripped) and fails on any difference from WeatherAether's.

- [ ] **Step 1: Write failing tests:** mapping table above for every WMO code in `WMO_DESC`; drift test fails when a copy is edited; with `weatherMode: 'live'` and the `ipGeolocation` capability absent, no request to `ipapi.co` or `api.bigdatacloud.net` (same assertions as Task 12a); network failure in Live mode falls back to Drifting without a blank frame.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement. Step 4: Gate PASS. Commit** `Add live weather to NeonCity via shared modules`.

### Task 13c: NeonCity Three.js city and fallback ladder

**Files:**
- Create: `Resources/Wallpapers/NeonCity/js/three-city.js`, `Resources/Wallpapers/NeonCity/vendor/three-city.min.js`, `vendor/THREE-LICENSE.txt`
- Create: `Tools/NeonCityThreeEntry.js`; modify `Tools/build-weather-three.sh` into `Tools/build-three-subset.sh <entry> <out>` (WeatherAether's invocation unchanged in output)
- Create: `Tools/NeonCityPreview.html` (state / phase / weather controls like WeatherAether's preview)
- Test: `Tests/JS/neoncity-fallback.test.mjs`

**Interfaces:**
- Produces:
  - `function buildCity(seed: number) -> CityModel` — deterministic: same seed → identical tower count, footprints and heights.
  - `function initializeThreeCity(canvas, model) -> boolean`, `function renderThreeCity(t, cityState)`.
  - `selectRenderer` / `demoteRenderer` with the same truth table and context-loss behaviour as WeatherAether (Task 11); demotion target is `classic-renderer.js`, then a static gradient keyed to `CityState.phase`.
  - `function qualityTier(system: {qualityMode: string, isLowPowerMode: boolean, onBattery: boolean}) -> {fps: 30|15, renderScale: number, countScale: 1|0.4, eventScale: 1|0.5}` — `saver` when `qualityMode==='eco'`, `onBattery` or `isLowPowerMode`; else normal (`30, 0.75, 1, 1`); saver = `15, 0.5, 0.4, 0.5`.
  - `function adaptRenderScale(current: number, p95FrameMs: number, msUnderBudget: number) -> number` — steps 0.75 → 0.6 → 0.5 when `p95FrameMs > 20`; steps up one notch only when `msUnderBudget ≥ 60000` with frames < 12 ms; never above the tier's renderScale.
  - Host: consumes Task 13y's `system.onBattery` / `system.qualityMode` (`'eco'` → saver tier); no Swift changes here.
  - Look reference: `docs/superpowers/references/neoncity-v3-mockup.html` (approved look; glow via additive sprites/emissive only — no post-processing passes). Add rim light so tower façades read at night.

- [ ] **Step 1: Write failing tests:** `buildCity` determinism and three depth bands present (near/mid/far counts > 0); fallback truth table; `webglcontextlost` → classic renderer draws the next frame; `qualityTier` table; `adaptRenderScale` steps and hysteresis; the scene creates no EffectComposer/post-processing pass.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement** snow as soft swaying flakes (distinct from rain streaks), and the city: instanced tower meshes per depth band, shader-lit windows driven by `windowsLit`, exponential fog colour from `phase`, camera on a slow closed spline (one loop ≥ 10 min).
- [ ] **Step 4: Gate PASS. Commit** `Render NeonCity in Three.js with classic fallback`.

### Task 13d: NeonCity life systems

**Files:**
- Create: `Resources/Wallpapers/NeonCity/js/city-life.js`
- Test: `Tests/JS/neoncity-life.test.mjs`

**Interfaces:**
- Produces: `function createLife(seed: number, model: CityModel) -> Life`; `Life.update(dt: number, cityState: CityState)`; observable state for tests: `Life.vehicles[] {lane, t, speed}`, `Life.signs[] {on: boolean, dead: boolean}`, `Life.events[]` (searchlight sweeps, blimp passes, steam bursts).
- Rules: vehicle speed varies ±30% around lane speed and eases at lane ends (no constant-speed loops); vehicle count = `round(trafficDensity × 20)`; 2–5% of signs are dead tubes; blimp passes at most once per 15 min; everything scaled down at `phase:'day'`.

- [ ] **Step 1: Write failing tests** for each rule above, using simulated time.
- [ ] **Step 2: Run, expect FAIL. Step 3: Implement and render in `three-city.js`** (the classic renderer keeps its own simpler life). **Step 4: Gate PASS. Commit** `Bring NeonCity's traffic, signs and events to life`.

### Task 13e: NeonCity performance and portability

**Files:**
- Modify: `Tools/WeatherPerf/main.swift` → takes `--wallpaper weather|neoncity` (NeonCity drives `Tools/NeonCityPreview.html` through 4 phases × 6 weather states)
- Modify: `scripts/check-weather-perf.sh` → also runs NeonCity; baseline renderer = Classic
- Modify: `Tests/WeatherAetherPortabilityTests.swift` → parameterized over WeatherAether and NeonCity

- [ ] **Step 1:** Run the harness (GPU sampling from Task 13y) for NeonCity in both tiers. Record baselines in the ledger. **Step 2:** Tune until the B3 per-tier budget holds: normal (Balanced) CPU mean ≤ 6%, p95 ≤ 10%, GPU ≤ 15%; saver (Eco) CPU ≤ 3%, GPU ≤ 8%; RSS flat over the 10-minute soak. **Step 3:** Portability test passes for both wallpapers.
- [ ] **Step 4: Gate PASS, perf check PASS. Commit** `Enforce performance and portability for NeonCity`.

**Phase B exit — user gates (B5, B6):** coordinator builds the OSS app and gives the user the WeatherAether preview (nine states, day and night) and the NeonCity preview (night, dusk, day and Always night × six weather states). Fix list → new tasks; approval recorded in the ledger.

---

## Phase A — Distribution

### Task 14: Licence headers, contributing, acknowledgements

**Files:**
- Modify: the live tracked-file list from `git grep -l "All[ ]rights reserved"`
- Create: `CONTRIBUTING.md`
- Modify: `UI/PreferencesWindowController.swift` (About tab: acknowledgements list)
- Create: `Resources/Acknowledgements.txt`

- [ ] **Step 1:** Remove the restrictive copyright suffix from each header line; `git grep -n "All[ ]rights reserved"` returns nothing.
- [ ] **Step 2: `CONTRIBUTING.md`:** GPL-3; the author distributes through the Mac App Store as sole copyright holder, so contributions are accepted only with the contributor's written agreement that the author may also distribute them under the App Store's terms; how to file issues; how to run `scripts/test-gate.sh`.
- [ ] **Step 3: Acknowledgements:** `Resources/Acknowledgements.txt` contains Three.js MIT licence (copied from `vendor/THREE-LICENSE.txt`) and, from Task 16 on, Sparkle's licence; the About tab shows an "Acknowledgements…" button opening it in a scrollable text view.
- [ ] **Step 4: Gate PASS. Commit** the licence cleanup, contributing guide and acknowledgements.

### Task 15: Split OSS and App Store targets

**Files:**
- Modify: `ÆtherDesk.xcodeproj/project.pbxproj`, both `xcshareddata/xcschemes/*.xcscheme`
- Create: `scripts/check-appstore-build.sh`
- Modify: `scripts/test-gate.sh` (add `--with-appstore`)

**Interfaces:**
- Produces: targets `AetherDesk` (OSS; configs Debug/Release) and `AetherDeskAppStore` (product `ÆtherDesk.app`, configs Debug/Release with `AETHERDESK_STORE`, `AetherDeskAppStore.entitlements`, `-weak_framework WeatherKit`, same bundle ID and version settings). The `AppStore` build configuration is removed. Scheme `AetherDesk-AppStore` builds/runs/archives `AetherDeskAppStore`, keeps `AetherDesk.storekit`, and tests `AetherDeskTests` + `AetherDeskStoreTests` (whose `TEST_HOST` now points at the App Store target's product).
- `scripts/check-appstore-build.sh`: builds `AetherDeskAppStore` Release unsigned into a temp derived-data dir; fails if `Contents/Frameworks/Sparkle.framework` exists or `otool -L` on the executable mentions `Sparkle`; also fails if the binary contains the symbol string `UpdateManager`.

- [ ] **Step 1:** Make the split (by hand or by generating once from a throwaway spec outside the repo and committing only the resulting `.xcodeproj`). Every source file in the old target is a member of both app targets.
- [ ] **Step 2: Verify:** `xcodebuild -list` shows both targets; `scripts/test-gate.sh --with-js --with-appstore` PASS; OSS build's executable still links nothing new.
- [ ] **Step 3: Commit** `Split OSS and App Store app targets`.

### Task 16: Sparkle in the OSS target; retire UpdateManager

**Files:**
- Modify: `project.pbxproj` (SPM `https://github.com/sparkle-project/Sparkle`, `upToNextMinorVersion` from the latest 2.x release verified on GitHub at implementation time — record version in the ledger; linked to `AetherDesk` only)
- Create: `Core/SoftwareUpdater.swift` (`#if !AETHERDESK_STORE`)
- Create: `Persistence/UpdateSettingsMigration.swift`
- Delete: `Core/UpdateManager.swift`, `Persistence/UpdateSettingsStore.swift`, `Tests/UpdateSettingsStoreTests.swift`
- Modify: `App/AppDelegate.swift:63`, `UI/MenuBarController.swift:355-366`, `UI/PreferencesWindowController.swift:230-255`, `App/Constants.swift:76-77`, `Resources/Info.plist`, `README.md`, `docs/privacy.html`, `Resources/Acknowledgements.txt`
- Test: `Tests/UpdateSettingsMigrationTests.swift`

**Interfaces:**
- Produces:
  - `final class SoftwareUpdater { static let shared; func start(); func checkForUpdates(); var automaticallyChecks: Bool { get set }; var automaticallyDownloads: Bool { get set } }` — wraps `SPUStandardUpdaterController(startingUpdater: false, …)`.
  - `protocol UpdaterPreferences: AnyObject { var automaticallyChecks: Bool { get set }; var automaticallyDownloads: Bool { get set } }` — `SoftwareUpdater` conforms; tests use a fake.
  - `enum UpdateSettingsMigration { static func migrate(defaults: UserDefaults, into prefs: UpdaterPreferences) }` — reads the v1.3 `UpdateSettingsStore` key (copy the key string and payload shape from the deleted file), applies `automaticallyCheckForUpdates` → `automaticallyChecks`, `automaticallyInstallUpdates` → `automaticallyDownloads`, removes the old key, sets `AetherDesk.updateSettingsMigrated = true`; no-op when already migrated or no old data.
  - Info.plist: `SUFeedURL = https://sdelavega.github.io/AetherDesk/appcast.xml`, `SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`, `SUEnableSystemProfiling = false`. `SPARKLE_PUBLIC_ED_KEY` is a build setting on the OSS target; until the user supplies the real public key it holds the placeholder `REPLACE_WITH_AETHERDESK_PUBLIC_KEY`, which Task 18's build refuses.

- [ ] **Step 1: Write failing migration tests:** v1.3 data with checks on / install off → prefs `true`/`false`, old key removed, flag set; second run changes nothing; no old data → prefs untouched, flag set.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement migration and `SoftwareUpdater`; wire launch (migrate, then `start()`), menu "Check for Updates…", Preferences toggles; delete the old updater and its notification constant.**
- [ ] **Step 4: Docs:** README "Get It" mentions Homebrew (`brew install --cask sdelavega/tap/aetherdesk`) and Sparkle updates; README and `docs/privacy.html` state the update check sends app version and macOS version to `sdelavega.github.io`, nothing else, and can be disabled in Preferences › General.
- [ ] **Step 5: Gate (`--with-js --with-appstore`) PASS.** Launch the OSS build; "Check for Updates…" opens Sparkle's UI (a feed error is expected until the appcast exists).
- [ ] **Step 6: Commit** `Replace custom updater with Sparkle in the OSS build`.

**User gate:** the user runs Sparkle's `generate_keys --account AetherDesk` (separate key from Tesserae, stored in their login keychain) and gives the coordinator the **public** key, which is committed as `SPARKLE_PUBLIC_ED_KEY`.

### Task 17: v1.3 handover harness

**Files:**
- Create: `scripts/check-v13-handover.sh`, `Tools/V13Handover/shim.swift`

**Interfaces:**
- Produces: `scripts/check-v13-handover.sh <AetherDesk.zip>` — extracts `Core/UpdateManager.swift` from tag `v1.3` with `git show v1.3:…` into a temp dir, makes its private verification/extraction helpers callable from the shim (mechanical `private`→`internal` rewrite of that temp copy only), compiles with the shim, and runs: sha256 verification against `<zip>.sha256`, extraction, `codesign` TeamIdentifier check against `N5PUFD82GV`. Exit 0 and prints `v1.3 handover: OK (<version>)` on success.

- [ ] **Step 1:** Run against a zip of the current OSS build signed ad hoc → expect FAIL on team ID (proves the check bites).
- [ ] **Step 2:** Implement until the script is correct; the PASS run happens in Task 18 against a Developer ID-signed build.
- [ ] **Step 3: Commit** `Add v1.3 updater handover check`.

### Task 18: Release build and publish scripts

**Files:**
- Create: `scripts/release-lib.sh`, `scripts/release-build.sh`, `scripts/release-publish.sh`, `scripts/make-dmg.sh`, `scripts/sparkle-tools.sha256`
- Create: `packaging/aetherdesk.rb.template`
- Delete: `release`
- Modify: `README.md` (Building/Releasing section), `.gitignore` (`dist/`)

**Interfaces:**
- `scripts/release-build.sh <X.Y.Z> <build>`:
  1. Refuses a dirty tree, a non-`v1.4`/`main` branch, or a placeholder `SPARKLE_PUBLIC_ED_KEY`.
  2. Child tools get only `PATH HOME TMPDIR LANG LC_* USER DEVELOPER_DIR`.
  3. Sets `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.pbxproj` for both app targets (verified by `xcodebuild -showBuildSettings`).
  4. Runs `scripts/test-gate.sh --with-js --with-appstore`.
  5. Archives `AetherDesk` Release, exports with `ExportOptions.plist` (Developer ID).
  6. Notarizes and staples the app (`NOTARIZE_KEYCHAIN_PROFILE`, default `AetherDesk`).
  7. Creates `dist/<ver>/AetherDesk.zip` (`ditto -c -k --keepParent`) + `AetherDesk.zip.sha256` in v1.3's expected format; creates, notarizes and staples `dist/<ver>/AetherDesk-<ver>.dmg`.
  8. Runs `scripts/check-v13-handover.sh` on the zip.
  9. Verifies pinned `generate_appcast`/`sign_update` against `scripts/sparkle-tools.sha256`; generates `dist/<ver>/appcast.xml` from the zip in an isolated directory, with the EdDSA key read from the keychain by Sparkle's tool (never printed), and verifies the enclosure signature.
  10. Writes `dist/<ver>/manifest.txt` (file names, sizes, sha256).
- `scripts/release-publish.sh <X.Y.Z> [--execute]`: without `--execute` prints every action and exits 0. With it, asks for typed confirmation of the version, then: `gh release create vX.Y.Z` with zip, sha256, DMG; commits `appcast.xml` to `gh-pages` from a detached worktree; renders `packaging/aetherdesk.rb.template` into `../homebrew-tap/Casks/aetherdesk.rb` and commits it there; fetches the served appcast and release assets and compares sha256 to the manifest.
- Cask template: `auto_updates true`, `depends_on macos: :sonoma`, `app "ÆtherDesk.app"`, `zap` covering `~/Library/Application Support/ÆtherDesk`, `~/Library/Caches/com.sdelavega.ÆtherDesk`, `~/Library/Preferences/com.sdelavega.AetherDesk.plist`, `~/Library/Saved Application State/com.sdelavega.AetherDesk.savedState`, `~/Library/Containers/com.sdelavega.AetherDesk` (verify each path against a running build; drop any the app never writes).

- [ ] **Step 1:** Write the scripts. `shellcheck` clean.
- [ ] **Step 2: Dry run:** `scripts/release-build.sh 1.4.0 41` on a clean tree → produces `dist/1.4.0/*`, handover check prints OK, appcast signature verifies. (Requires the user's keychain profiles; the coordinator runs this with the user present.)
- [ ] **Step 3:** `scripts/release-publish.sh 1.4.0` (no `--execute`) prints the plan and touches nothing — `git status` in this repo and `../homebrew-tap` unchanged.
- [ ] **Step 4: Gate PASS. Commit** `Rebuild release pipeline with Sparkle appcast, DMG and Homebrew cask`.

---

## Final review (coordinator)

- `scripts/test-gate.sh --with-js --with-appstore` PASS; StoreKit tests run with the user's signing or are reported as not run.
- `scripts/check-weather-perf.sh` PASS, report in the ledger.
- Whole-branch review of `main...v1.4`.
- Ask the user before any merge, push, tag, release, or tap commit.
