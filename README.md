# ÆtherDesk

**Live wallpapers for macOS — powered by HTML, video, and images.**

ÆtherDesk is a lightweight menu-bar app that renders animated wallpapers behind your desktop icons on every connected display. Drop in any HTML5 canvas/WebGL page, a looping video, or a static image and ÆtherDesk takes care of the rest.

It ships with full [Lively Wallpaper](https://www.rocksdanister.com/lively/) compatibility, so thousands of community-made wallpapers work out of the box.

---

## Features

- **Web, Video, and Image wallpapers** — anything from a hand-crafted Three.js scene to a simple `.mp4` loop
- **Per-display wallpaper assignment** — different wallpaper on each monitor, remembered across reboots
- **Lively Wallpaper compatible** — reads `LivelyInfo.json` and `LivelyProperties.json` natively; import `.zip` bundles directly
- **Real-time property controls** — tweak colors, speeds, densities, and any custom slider the wallpaper author exposes, live from the Preferences panel
- **Menu-bar only** — no Dock icon, no windows cluttering your Cmd+Tab; everything lives in the status bar
- **Launch at Login** — optional, toggle from Preferences
- **Smart resource management**
  - Configurable FPS cap (15–60, default 30)
  - Pause/resume from the menu bar or automatically when the display sleeps
  - Safe Mode fallback if a wallpaper misbehaves
  - Watchdog timer catches hung web content and recovers gracefully
- **Sandboxed WebViews** — each wallpaper runs in its own WKWebView process; ad networks, analytics trackers, and crypto miners are blocked via a compiled content rule list; `file://` access is scoped to the wallpaper's own bundle
- **Import validation** — bundles are screened on import for excessive size, suspicious scripts, and resource abuse before they ever run

## Getting Started

### Download

Grab the latest signed and notarized `.app` from the [Releases](https://github.com/sdelavega/AetherDesk/releases) page. Unzip, drag to Applications, and launch — no Gatekeeper warnings. The binary is universal and runs natively on both Apple Silicon and Intel Macs.

### Using wallpapers

1. Click the **ÆtherDesk** icon in your menu bar
2. **Wallpapers** submenu shows all available wallpapers — click one to apply
3. If you have multiple displays, each gets its own submenu section
4. **Import Wallpaper...** lets you add `.zip` bundles or folders containing a wallpaper
5. Open **Preferences** to adjust FPS, tweak wallpaper-specific properties, or enable Launch at Login

### Bundled wallpapers

ÆtherDesk comes with three built-in wallpapers to get you started:

| Wallpaper | Description |
|-----------|-------------|
| **NeonCity** | Procedural neon-lit cityscape with rain, fog, and parallax |
| **MatrixRain** | Classic falling-code effect with configurable colors and density |
| **GradientWave** | Smooth animated color gradients with customizable palettes |

All three support real-time property tweaking from Preferences.

## Importing Lively Wallpapers

ÆtherDesk reads the same `LivelyInfo.json` and `LivelyProperties.json` format used by [Lively Wallpaper](https://www.rocksdanister.com/lively/) on Windows. To import:

1. Find a wallpaper you like (e.g. from the [Lively GitHub community](https://github.com/rocksdanister/lively))
2. Download the `.zip` bundle
3. In ÆtherDesk, click **Import Wallpaper...** and select the zip
4. The importer validates the bundle, copies it to `~/Library/Application Support/ÆtherDesk/Wallpapers/`, and makes it available immediately

Supported types: **web/HTML**, **video** (mp4, mov, m4v, webm), and **image** (png, jpg, gif, webp, heic).

---

## Creating Your Own Wallpaper

A wallpaper is just a folder with an `index.html` and a `LivelyInfo.json`:

```
MyWallpaper/
├── index.html              # Your wallpaper (canvas, WebGL, CSS, etc.)
├── LivelyInfo.json         # Metadata (title, author, type)
└── LivelyProperties.json   # Optional: sliders, color pickers, toggles
```

**Minimal `LivelyInfo.json`:**
```json
{
  "Title": "My Wallpaper",
  "Author": "You",
  "Description": "A cool animated wallpaper",
  "Type": "web",
  "FileName": "index.html"
}
```

**Adding user-tweakable properties** (`LivelyProperties.json`):
```json
{
  "speed": {
    "text": "Animation Speed",
    "type": "slider",
    "value": 1.0,
    "min": 0.1,
    "max": 5.0,
    "step": 0.1
  },
  "color": {
    "text": "Primary Color",
    "type": "color",
    "value": "#ff6600"
  }
}
```

Your `index.html` receives property updates through the Lively-compatible JS bridge:

```javascript
// Called by ÆtherDesk when the user changes a property
function livelyPropertyListener(name, val) {
  if (name === "speed") animationSpeed = val;
  if (name === "color") primaryColor = val;
}
```

Zip the folder and import it, or drop it directly into `~/Library/Application Support/ÆtherDesk/Wallpapers/`.

---

## Under the Hood

```
ÆtherDesk (menu-bar app, LSUIElement)
│
├── AppDelegate              — Bootstrap, restore last session
├── WallpaperManager         — Orchestrates runtimes across all displays
│   ├── DisplayManager       — Resolves CGDirectDisplayID ↔ NSScreen; change events via NSApplicationDidChangeScreenParametersNotification
│   ├── WallpaperHostWindow  — Borderless NSWindow at kCGDesktopWindowLevel
│   └── WallpaperRuntime     — Protocol with three concrete implementations:
│       ├── WebWallpaperRuntime    — WKWebView with lazy alloc/dealloc lifecycle
│       ├── VideoWallpaperRuntime  — AVPlayer + AVPlayerView with seamless looping
│       └── ImageWallpaperRuntime  — NSImageView
│
├── PropertyBridge           — Lively-compatible JS ↔ native bridge (50ms debounced batching)
├── WallpaperImporter        — Import, validate, and manage wallpaper bundles
├── WallpaperStore           — Per-display wallpaper persistence (UserDefaults, in-memory cached)
├── PropertyStore            — Per-wallpaper property overrides (UserDefaults, in-memory cached)
├── ThumbnailRenderer        — Snapshot generator with WebView pooling
├── WatchdogTimer            — Heartbeat monitor; silence → safe-mode demotion
│
└── UI
    ├── MenuBarController              — NSMenu-based status item; Wallpapers submenu rebuilt on each open
    ├── PreferencesWindowController    — Tabbed prefs (General, Performance, Wallpaper, About)
    ├── WallpaperPickerViewController  — List picker with async thumbnails
    └── PropertyEditorViewController   — Dynamic controls from LivelyProperties.json
```

**Some design decisions that might interest you:**

- **WebView lifecycle** — WKWebViews are created on `start()` and fully deallocated on `stop()`. No idle web processes sitting around eating memory when you swap wallpapers.
- **Debounced property bridge** — Rapid slider drags batch into a single `evaluateJavaScript` call every 50ms instead of flooding the web process with individual updates.
- **rAF throttle shim** — A `requestAnimationFrame` wrapper is injected at document start to enforce the FPS cap natively, regardless of what the wallpaper's JS does.
- **No Combine, no SwiftUI** — Pure AppKit + GCD + NotificationCenter. The entire app bundle is under 2 MB.
- **Stable wallpaper IDs** — Imported bundles use their UUID folder name; built-in wallpapers get a deterministic FNV-1a hash of their path, so property overrides survive moves and reinstalls.

## Building from Source

```bash
git clone https://github.com/sdelavega/AetherDesk.git
cd AetherDesk
open ÆtherDesk.xcodeproj
```

Build and run (`Cmd+R`). No SPM dependencies, no CocoaPods, no external frameworks — just AppKit, WebKit, and AVFoundation.

**Requirements:** macOS 12.0+ · Swift 5.9+ · Xcode 15+

## License

MIT License — Copyright (c) 2026 Stephen de la Vega. See [LICENSE](LICENSE) for details.
