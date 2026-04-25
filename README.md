# ÆtherDesk

**Live wallpapers for macOS, with a narrower scope and a stricter attitude than most desktop wallpaper toys.**

ÆtherDesk is a native menu-bar-only macOS app that hosts live wallpapers behind your desktop icons. It supports animated HTML/JS wallpapers in `WKWebView`, looping muted video, and static images. If you want the one-sentence pitch: it is a macOS Lively-style wallpaper host, but intentionally focused on the parts that fit well on the platform.

It reads Lively's bundle metadata and property formats, so a lot of existing community wallpapers import cleanly. It does **not** try to run everything Lively can run on Windows. Web, video, and image bundles are in scope. Executables, Unity, and other platform-specific runtimes are not.

## What It Does Well

- Runs as an `LSUIElement` accessory app: no Dock icon, no app window hanging around, no clutter in Cmd-Tab
- Hosts one wallpaper window per display at the desktop window level
- Supports per-display wallpaper assignment and restores it on launch
- Reads `LivelyInfo.json` and `LivelyProperties.json` directly
- Lets wallpapers expose live controls in Preferences
- Generates thumbnails for imported and bundled wallpapers
- Watches web wallpapers with a heartbeat watchdog and demotes a hung runtime to safe black content instead of taking the whole app down
- Includes automatic update checking and optional automatic install for GitHub Releases builds

## Current Feature Set

- **Web, video, and image wallpapers**
  HTML/JS wallpapers run in `WKWebView`, videos loop through `AVPlayer`, and stills use `NSImageView`.

- **Per-display control**
  Different wallpaper on each monitor, plus an “All Displays” apply path from the menu.

- **Live property editing**
  If a wallpaper ships `LivelyProperties.json`, ÆtherDesk builds the controls dynamically and pushes updates live into the running wallpaper.

- **Menu bar workflow**
  The app lives in the status item. Preferences is the only real window.

- **Performance controls**
  FPS cap is configurable at 15, 30, or 60. Wallpapers can also pause when occluded, when the Mac enters low power mode, or when running on battery, depending on your settings.

- **Import screening**
  Imported bundles are checked before they run. Oversized bundles, obvious tracker/ad scripts, crypto-mining patterns, infinite loops, and unsupported wallpaper types get rejected. Riskier-but-not-fatal bundles can still import under tighter limits.

- **Network controls for web wallpapers**
  ÆtherDesk can block external network requests entirely, block raw-IP WebSocket connections, deny access to private IPs unless LAN access is explicitly allowed, and reject cloud metadata endpoint access / DNS rebinding tricks.

- **Tracker and miner blocking**
  A compiled WebKit content rule list blocks a set of known analytics, ad-tech, and cryptomining domains inside wallpaper WebViews.

- **Safe failure behavior**
  A wallpaper that wedges its web content process or stops heartbeating gets demoted on that display only. The rest of the app keeps running.

## Bundled Wallpapers

The repo currently ships with four sample wallpapers:

- `GradientWave`
- `MatrixRain`
- `NeonCity`
- `WeatherAether`

They exist partly as usable defaults and partly as reference bundles for the import/runtime pipeline.

## Using It

Click the ÆtherDesk menu bar item and open the `Wallpapers` submenu. On a single display, applying one is straightforward. On multiple displays, the menu lets you apply to all displays or target a specific one.

`Preferences` gives you four tabs:

- `General`: launch at login, update settings, reveal wallpaper folder
- `Performance`: FPS cap, pause policies, network controls
- `Wallpaper`: picker, preview thumbnails, wallpaper property editor, contacted domains view for the selected wallpaper
- `About`: version/build info

Imported wallpapers are copied into the app's Application Support wallpaper library and become available immediately.

## Importing Lively Wallpapers

ÆtherDesk uses Lively's on-disk bundle format:

```text
MyWallpaper/
├── LivelyInfo.json
├── LivelyProperties.json   # optional
├── index.html              # for web wallpapers
├── preview.png             # optional
└── assets...
```

Supported content types today:

- **Web**: HTML/JS wallpapers
- **Video**: `mp4`, `mov`, `m4v`, `webm`
- **Image**: common still-image formats

Not supported:

- executable/application wallpapers
- Unity / Godot / other engine-specific bundles
- anything that assumes Windows-only runtime behavior

So “Lively compatible” here means the metadata and property model are compatible, and the supported media/runtime types import cleanly. It is not a claim of total feature parity with Lively on Windows.

## Writing a Wallpaper

At minimum, a web wallpaper is just a folder with an `index.html` and `LivelyInfo.json`.

```json
{
  "Title": "My Wallpaper",
  "Author": "You",
  "Description": "A small animated wallpaper",
  "Type": "web",
  "FileName": "index.html"
}
```

If you add `LivelyProperties.json`, ÆtherDesk will build native controls for it and push updates into the running wallpaper.

For wallpapers that already speak Lively's JS property contract, that mostly just works. ÆtherDesk also injects its own bridge with wallpaper properties, display information, power/network state, suspend/resume hooks, heartbeat plumbing, native fetch support, and geolocation request handling.

In other words: if you're already authoring Lively-style web wallpapers, you usually do not need to learn a brand-new bundle format to get started here.

## Under the Hood

The spine of the app is `WallpaperManager`, which owns one host window and at most one runtime per display. It restores persisted assignments at launch, rebuilds hosts as display configuration changes, and demotes only the failing display when a runtime misbehaves.

The web runtime is intentionally disposable. `WKWebView` instances are created on `start()` and torn down fully on `stop()` so rapidly switching wallpapers does not leave zombie web content processes hanging around. A JS heartbeat resets a native watchdog timer; if the wallpaper goes silent for too long or the content process dies, the runtime posts a failure notification and the manager swaps in safe content.

Persistence is split cleanly:

- `WallpaperStore` remembers which wallpaper is assigned to which display
- `PropertyStore` remembers per-wallpaper property overrides
- `AppSettingsStore`, `RuntimePolicyStore`, `UpdateSettingsStore`, and `GeolocationPermissionStore` cover the rest of the user-tunable state

Thumbnail generation is also native: preview image if present, otherwise type-specific rendering. Web thumbnails come from an offscreen `WKWebView` snapshot path with caching on disk.

## Building From Source

This project is XcodeGen-driven. The checked-in `.xcodeproj` is generated output, not the source of truth.

```bash
brew install xcodegen
git clone https://github.com/sdelavega/AetherDesk.git
cd AetherDesk
xcodegen
open AetherDesk.xcodeproj
```

Requirements:

- macOS 12.0+
- Xcode 26.3+ recommended
- Swift 5.9

There are no third-party package dependencies. It is just AppKit, WebKit, AVFoundation, and the usual Apple frameworks.

## Project Status Notes

A few things are worth stating plainly:

- The app is currently **unsandboxed** by design, though there is scaffolding in place for a future sandbox migration.
- Display restore at launch is in good shape; display hot-plug restore still has room to improve.
- The codebase is AppKit-first and intentionally avoids piling on abstraction for a small utility app.

## License

MIT License. See [LICENSE](LICENSE).
