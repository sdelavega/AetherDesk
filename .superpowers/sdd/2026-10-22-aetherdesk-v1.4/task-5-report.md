# Task 5 report — reconciler integration and geometry cache

Status: DONE_WITH_CONCERNS

## Implementation

- Added `DisplayChangeCoalescer`, its `Cancellable` protocol, and `DispatchWorkItem` conformance. The default trailing delay is 0.25 seconds; rescheduling cancels previous work and rejects obsolete callbacks. Pending work is cancelled at deinitialization.
- Added a lock-protected `DisplayGeometryCache` with shared access, replacement updates, lookup, and invalidation.
- `WallpaperManager` now keeps bundles by `DisplayIdentity` and active `DisplaySnapshot` values. Startup establishes the initial snapshots and geometry before creating hosts, preventing the first unchanged notification from recreating them.
- Screen-change notifications signal the main-queue coalescer. Its callback refreshes hardware snapshots and cached AppKit geometry, runs `DisplayReconciler`, applies all action cases in order, and posts the existing display-configuration notification.
- Disconnects remove runtimes, hosts, occlusion state, and pending restoration requests while retaining session bundles by identity. Reframes use `DisplayManager.screen(for:)` and `NSScreen.frame`, then notify the runtime. Quartz snapshot/action frames are never used to place windows.
- Persisted restoration keeps directory scanning and `loadAssignments` on a background queue, then applies a saved bundle or the fallback on main. Per-host request tokens and identity/running checks prevent an obsolete result from replacing a newer assignment or a different host.
- Session restoration resolves the action's bundle ID through the current identity's session bundle. Updated property routing, safe-mode restoration, wake handling, and deletion handling for the new dictionary key.
- Added `WallpaperRuntime.displayGeometryDidChange()` with a no-op protocol extension. Web runtimes reinject the environment. PropertyBridge and image startup use cached geometry and consult NSScreen only on a cache miss.
- Registered both Core files in the app and AetherDeskTests, with the new test files in AetherDeskTests only. Existing `DisplayManager.hardwareInfo()` was reused unchanged.

## TDD evidence

RED command, before either helper existed:

```sh
xcodebuild test -project ÆtherDesk.xcodeproj -scheme AetherDesk -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/gate -only-testing:AetherDeskTests/DisplayChangeCoalescerTests -only-testing:AetherDeskTests/DisplayGeometryCacheTests
```

Exit 65; captured output in `/tmp/aetherdesk-task5-red.log`:

```text
Testing failed:
    Cannot find 'DisplayGeometryCache' in scope
    Testing cancelled because the build failed.
** TEST FAILED **
```

GREEN command:

```sh
xcodebuild test -project ÆtherDesk.xcodeproj -scheme AetherDesk -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/gate -only-testing:AetherDeskTests/DisplayChangeCoalescerTests -only-testing:AetherDeskTests/DisplayGeometryCacheTests -only-testing:AetherDeskTests/DisplayReconcilerTests
```

Exit 0; captured output in `/tmp/aetherdesk-task5-green.log`:

```text
Test run with 14 tests in 3 suites passed after 0.004 seconds.
** TEST SUCCEEDED **
```

The first GREEN attempt exposed a Swift Testing macro compilation issue with an `allSatisfy` key-path argument. Replacing it with an explicit closure fixed it before the passing run.

Tests cover five signals at 0/50/100/150/200 ms producing exactly one fire at 450 ms, no early fire, a subsequent independent burst, pending cancellation at deinit, geometry round trips, invalidation, and removal of disconnected cache entries. Existing reconciler tests cover unchanged displays, unplug/replug, reused IDs, geometry changes, swapped identical displays, and deterministic action ordering.

## Build and manual launch

```sh
xcodebuild build -project ÆtherDesk.xcodeproj -scheme AetherDesk -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/gate
```

Exit 0, `** BUILD SUCCEEDED **`; log: `/tmp/aetherdesk-task5-build.log`.

Launched the resulting OSS executable directly. The task build ran as PID 9795. CGWindow inspection found its on-screen desktop host (window 4028, layer -2147483623) with bounds x=0, y=0, width=1920, height=1243. NSScreen reported exactly one connected display (ID 1), frame 1920×1243, scale 2. Thus a host appeared for every display attached during this check.

Captured and inspected `/tmp/aetherdesk-task5-launch.png` and the isolated host capture `/tmp/aetherdesk-task5-wallpaper.png`. The desktop was covered by existing application windows; the isolated host capture was black. Host creation is confirmed, but successful wallpaper imagery is not visually confirmed. Runtime logs contained WebKit/system service errors; no wallpaper-start failure was observed in the collected output. Those system messages do not establish the cause of the black capture. Artifacts remain under `/tmp` and are not committed.

Requested termination through NSRunningApplication for PID 9795, which returned true. The pre-existing installed application at PID 25557 was left running.

## Final gate

Final build/test check after manual launch and quit:

```sh
scripts/test-gate.sh
```

Exit 0. Output in `build/gate.log` and `/tmp/aetherdesk-task5-final-gate.log`:

```text
Test run with 130 tests in 15 suites passed after 0.378 seconds.
** TEST SUCCEEDED **
```

`git diff --cached --check` also passed.

## Graph checks and self-review

Used exact Gortex worktree reads and edits. Ran impact before changes, proposed-protocol verification, post-change detection, tests, guards, and contract checks. No configured guard violations; proposed protocol verification was clean. Graph contract reports a broad behavioral-risk warning. Reviewed the impacted app startup, runtime lifecycle, coordinate systems, and asynchronous restore path; VideoWallpaperRuntime relies on the required no-op default and needs no change. Graph test discovery did not consistently resolve coverage; the actual Swift Testing runs above are the verification evidence.

## Files changed

- `Core/DisplayChangeCoalescer.swift`
- `Core/DisplayGeometryCache.swift`
- `Core/WallpaperManager.swift`
- `Core/WallpaperRuntime.swift`
- `LivelyCompatibility/PropertyBridge.swift`
- `WallpaperTypes/ImageWallpaperRuntime.swift`
- `WallpaperTypes/WebWallpaperRuntime.swift`
- `Tests/DisplayChangeCoalescerTests.swift`
- `Tests/DisplayGeometryCacheTests.swift`
- `ÆtherDesk.xcodeproj/project.pbxproj`
- `.superpowers/sdd/2026-10-22-aetherdesk-v1.4/task-5-report.md`

## Decisions

- Cache AppKit screen frames for consumers while retaining Quartz bounds exclusively for the reconciler's hardware snapshots.
- Route wake lifecycle changes through the reconciler as well, avoiding a competing display-ID restoration path.
- Preserve an in-flight persisted restore across unchanged reconciles, but invalidate it on teardown, explicit wallpaper selection, or stop.
- No new runtime dependency and no change to the existing hardwareInfo API.

## Concerns

- Manual verification confirmed hosts on the one available display; the isolated host image was black. Wallpaper rendering and physical multi-display hotplug behavior remain unverified by this manual run. This is the reason for DONE_WITH_CONCERNS.

## Commit

Requested subject: `Drive display changes through reconciler with coalescing`.
Co-author trailer follows the implementer contract.
