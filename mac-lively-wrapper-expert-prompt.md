# Prompt: Build a Mac-native Lively-style live wallpaper host for macOS

You are an expert macOS engineer. Design and implement a production-quality macOS app that can run a curated, performant subset of Lively Wallpaper content natively on macOS.

## Mission

Build a **menu bar only**, **dockless** macOS app that hosts live wallpapers on the desktop, with a strong bias toward:
- native Mac behavior
- excellent performance
- reliability
- graceful degradation
- support for Lively-style **web/HTML wallpapers** and their property model

This is not meant to be a sloppy wallpaper toy. It should feel like a serious Mac app with taste.

## Primary goals

1. Run a curated subset of Lively wallpapers on macOS.
2. Support included/default Lively wallpapers for testing, especially HTML/JS ones.
3. Support wallpaper property editing based on each wallpaper's built-in parameter schema.
4. Live only in the **menu bar**, not the Dock.
5. Render as desktop wallpaper, effectively taking over the desktop background presentation layer as far as practical on macOS.
6. Aggressively screen out or constrain resource hogs.
7. Allow optional networked wallpapers, but require graceful offline/failure behavior.
8. Be architected for long-term maintainability and user modification.

## Hard product constraints

- **No Dock presence**. Menu bar app is fine.
- Must support **multiple displays**.
- Must support **per-wallpaper parameter editing** from Lively-style metadata.
- Must be able to import and run a **supported subset** of Lively wallpapers.
- Must reject or restrict wallpapers that are likely to behave like resource hogs.
- Must permit wallpapers that use APIs or RSS feeds for weather/news/etc, but these must fail gracefully when offline or rate-limited.
- Must prefer **performance and reliability over maximal compatibility**.

## Important scope constraint: supported Lively subset

Do **not** pretend all Lively wallpapers are directly portable.

### v1 supported wallpaper classes
Support these classes first:
1. **Web / HTML wallpapers**
   - HTML/CSS/JS
   - Canvas 2D
   - WebGL/WebGL2 where supported by WKWebView/WebKit on macOS
2. **Video wallpapers**
   - mp4/mov/webm/gif/webp, if straightforward and performant
3. **Image wallpapers**
   - static or dynamic image sets
4. **Lively property model**
   - import and expose controls from `LivelyProperties.json`

### explicitly out of scope for v1
- Windows executables
- Unity/Godot/CEF app wallpapers that require Windows-specific runtime behavior
- arbitrary external applications as wallpapers
- anything requiring unsupported Windows APIs

## Recommended platform/stack

Use **Swift + AppKit**, optionally with SwiftUI for settings UI where appropriate.

Likely building blocks:
- AppKit for desktop-window behavior and screen management
- WKWebView for HTML/JS wallpapers
- AVFoundation for video playback if video wallpapers are included in v1
- SwiftUI or AppKit settings/preferences UI
- MenuBarExtra or NSStatusItem for menu bar presence

## App behavior requirements

### 1. Menu bar only
- App must run as a **menu bar app**.
- It must **not appear in Dock**.
- It should be available from the menu bar with controls for:
  - wallpaper selection
  - per-display assignment
  - enable/disable
  - settings
  - safe mode / fallback mode
  - reload current wallpaper
  - quit

### 2. Desktop wallpaper host windows
Create one wallpaper host per display.

Requirements:
- borderless
- desktop-level behavior
- behind regular app windows
- should feel like wallpaper, not like a foreground app window
- should survive Spaces / Mission Control / display reconfiguration sensibly
- should not steal focus
- should ignore mouse/keyboard unless explicitly put into an interaction/debug mode

Investigate the best practical AppKit/CoreGraphics approach to place content at the desktop layer on macOS.

### 3. Wallpaper import model
Support importing wallpaper bundles from folders and/or archives.

At minimum support Lively-like web wallpaper bundles containing files such as:
- `LivelyInfo.json`
- `LivelyProperties.json`
- `index.html`
- related JS/CSS/assets

Also design an internal normalized bundle format if helpful, but preserve compatibility with Lively web wallpapers whenever possible.

## Property system

The app must read built-in wallpaper parameter definitions and generate native controls.

Requirements:
- Parse `LivelyProperties.json` or equivalent metadata
- Expose controls in a native settings/panel UI
- Push updates live into the wallpaper runtime
- Persist property values per wallpaper and optionally per display

Support at least common property types such as:
- slider/range
- checkbox/toggle
- select/dropdown
- color
- text if needed

### JS bridge compatibility
Implement a compatibility bridge for web wallpapers.

Goals:
- emulate the useful subset of Lively property update behavior
- allow property updates from native UI into JS runtime
- surface environment info to wallpapers, such as:
  - display size
  - scale factor
  - display id
  - low power mode
  - visibility/occlusion if available
  - online/offline state
  - fps cap / quality mode

## Performance and reliability philosophy

This app is for a Mac. It should be pretty, but it must earn its keep.

### Admission rule
A wallpaper is allowed only if it behaves like wallpaper.
If it acts like a needy foreground app, reject it or constrain it.

### Import-time screening / validation
On import, inspect wallpapers and classify them as:
- Allowed
- Allowed with limits
- Rejected

Validation should consider:
- wallpaper type
- asset sizes
- likely unsupported APIs
- obvious external network dependency
- suspicious JS patterns
- timers/workers intensity
- signs of runaway rendering loops
- external scripts / trackers / ads
- estimated risk profile

Provide a human-readable import report explaining why a wallpaper was accepted, limited, or rejected.

### Runtime guardrails
Implement strong safeguards:
- default FPS cap, e.g. **30 FPS**
- optional higher cap, but conservative by default
- pause or reduce work when:
  - display sleeps
  - system locks
  - wallpaper becomes non-visible/occluded if detectable
  - app enters safe mode
- respect low power mode
- provide per-wallpaper quality presets
- watchdog for hung or misbehaving wallpaper runtime
- automatic fallback to last known good or static fallback on crash/failure

### Safe mode / fallback mode
Include a safe mode that:
- disables animation or reduces effects
- falls back to a static image or minimal mode when needed
- lets the app recover from bad wallpapers without becoming unstable

## Networked wallpapers policy

Network use is allowed, but only in civilized form.

### Allowed
- weather APIs
- news APIs
- RSS/Atom feeds
- lightweight read-only remote data sources

### Not acceptable
- constant high-frequency polling
- trackers / ads / analytics sludge
- blocking initial render on network success
- hard failure when offline
- chatty background behavior

### Required behavior for networked wallpapers
Any wallpaper using network data must:
- start and render without network
- fail gracefully on:
  - offline state
  - DNS failure
  - timeout
  - HTTP errors
  - malformed feeds
  - rate limits
- cache last good data
- use stale data quietly if needed
- back off intelligently on retries
- declare or configure refresh interval metadata
- never spin or crash because connectivity is absent

If needed, design host-level policies that can help enforce this, for example:
- timeout limits
- network request budget
- online/offline signaling to wallpaper runtime
- optional sandboxing or mediation strategy

## UX requirements

### Core UI
Provide a clean Mac-native experience:
- menu bar dropdown
- wallpaper picker/library
- settings/preferences window
- property editor for selected wallpaper
- per-display assignment UI
- diagnostics/import report UI

### Nice-to-have
- preview thumbnails
- current resource profile badge (light/balanced/heavy)
- one-click reload current wallpaper
- easy access to wallpaper folder

### About System Settings integration
If there is a robust official way to integrate meaningfully with macOS System Settings or Wallpaper behavior, document it and use it. If not, do not fake brittle integration.
A normal native Settings window is acceptable and preferred over hacks.

## Testing targets
Use included/default Lively wallpapers for testing, especially:
- simple HTML wallpapers
- matrix-style wallpapers using canvas/WebGL where possible
- at least one procedural HTML canvas wallpaper with multiple tunable parameters
- at least one video wallpaper if video support is included in v1

Build a compatibility matrix showing:
- wallpaper tested
- type
- status: works / works with limits / rejected
- performance notes
- missing features if any

## Deliverables

Produce the following:

1. **Architecture/design document**
   - app structure
   - windowing strategy
   - wallpaper runtime model
   - import/validation pipeline
   - property bridge
   - performance policy
   - failure recovery model

2. **Implementation plan**
   - phased milestones
   - risks and unknowns
   - recommended sequence for building and testing

3. **Working macOS project**
   - builds cleanly
   - includes menu bar app behavior
   - includes at least one functional wallpaper host
   - supports at least HTML Lively wallpapers in v1

4. **Compatibility layer**
   - parse Lively metadata for supported wallpaper subset
   - property editing and persistence

5. **Validation framework**
   - import screening
   - reject/allow/limit classification
   - report output

6. **Documentation**
   - supported wallpaper types
   - limitations
   - how to import wallpapers
   - how to add custom wallpapers
   - performance expectations

## Engineering attitude

Be opinionated.
Do not optimize for maximum compatibility at the expense of Mac performance or reliability.
Prefer a smaller supported subset that works beautifully.

The result should feel like:
- a Mac-native app
- a serious desktop component
- moddable and understandable
- hostile to sloppy, wasteful wallpapers
- graceful under failure

## Additional guidance

- Think carefully about desktop window placement on macOS and choose the most reliable practical approach.
- Keep the wallpaper runtime isolated enough that a single bad wallpaper does not destabilize the whole app.
- Treat import validation as a first-class feature, not an afterthought.
- Where macOS limitations make a requirement impossible or unreliable, say so clearly and propose the best practical alternative.
- When uncertain, bias toward reliability and performance.

## Output requested from you

Please return:
1. A proposed architecture
2. A compatibility and risk analysis
3. A phased implementation plan
4. The actual code/project skeleton or implementation
5. Notes on any macOS limitations that affect the wallpaper-hosting approach

Do not hand-wave. Be concrete, technical, and pragmatic.
