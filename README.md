# ÆtherDesk

Live wallpapers for macOS that actually behave themselves.

ÆtherDesk is a native menu-bar-only app that hosts animated HTML/JS wallpapers, looping video, and static images behind your desktop icons. It was born out of the simple frustration that Lively — which is genuinely great on Windows — doesn't exist on macOS, and every macOS alternative either demands too much trust, too much RAM, or too much forgiveness.

It reads Lively's bundle format directly, so a lot of community wallpapers just work. It doesn't try to run *everything* Lively can run — executables, Unity, and engine-specific bundles aren't happening — but if it's a web wallpaper, a video loop, or a still image, you're in the right place.

---

## Get It

**TestFlight (App Store build):** The current build is on TestFlight while the App Store submission finishes review. Sandboxed, WeatherKit weather data, macOS 13.5+.

[**Join the TestFlight Beta →**](https://testflight.apple.com/join/KFUDzBqY)

**GitHub Releases (OSS build):** Prefer the open-source configuration? Grab the latest release from the [Releases page](https://github.com/sdelavega/AetherDesk/releases). It's signed and notarized by me, so macOS will open it without complaint — no right-click tricks, no disabling Gatekeeper, no terminal incantations. Just download and run.

Found something broken? [Open an issue.](https://github.com/sdelavega/AetherDesk/issues) Steps to reproduce, what you expected, what actually happened — that's all you need. Console output is a bonus but never required.

---

## What It Does

ÆtherDesk runs as an `LSUIElement` accessory — no Dock icon, no Cmd-Tab clutter, nothing in your way. It puts one wallpaper window per display at the desktop window level and keeps it there. Per-display assignments persist across launches, so it remembers what you had where.

Web wallpapers get a proper runtime: a `WKWebView` with a heartbeat watchdog watching over it. If a wallpaper's web content process dies or stops responding for 30 seconds, that display gets demoted to safe black content and the rest of the app keeps running. Nobody panics, nothing crashes. The problematic wallpaper just quietly gets benched on that one screen.

If a wallpaper ships `LivelyProperties.json`, ÆtherDesk builds live controls for it in Preferences and pushes updates into the running wallpaper in real time. No restart needed.

There's also a fair amount of security scaffolding you can tune: block all external network requests, block raw-IP WebSocket connections, restrict access to private IPs, and a compiled WebKit content rule list that quietly drops known ad-tech, analytics, and cryptomining domains. Because wallpapers running JavaScript on your desktop probably shouldn't be phoning home to Google Analytics.

**Performance controls** let you cap the FPS at 15, 30, or 60, and wallpapers can pause automatically when they're occluded, when low power mode kicks in, or when you're on battery. It's polite like that.

---

## The Bundled Wallpapers

Four come in the box: `GradientWave`, `MatrixRain`, `NeonCity`, and `WeatherAether`. They're usable defaults and honest examples of what the import/runtime pipeline expects. WeatherAether is the interesting one — it uses live location and weather data and adapts its visuals accordingly.

---

## Using It

Click the menu bar item, open the Wallpapers submenu, pick something. On a single display it's obvious. On multiple displays, the menu gives you per-display targeting and an "All Displays" shortcut.

Preferences has four tabs: **General** (launch at login, updates, wallpaper folder), **Performance** (FPS, pause policies, network controls), **Wallpaper** (the picker, thumbnails, property editor, and a view of what domains the selected wallpaper talks to), and **About**.

Imported wallpapers get copied into Application Support and show up immediately. No restart, no drama.

---

## Importing Lively Wallpapers

The bundle format is exactly Lively's:

```text
MyWallpaper/
├── LivelyInfo.json
├── LivelyProperties.json   # optional
├── index.html              # for web wallpapers
├── preview.png             # optional
└── assets...
```

Web, video (`mp4`, `mov`, `m4v`, `webm`), and common image formats are supported. Executables, Unity, and anything that assumes a Windows runtime are not. "Lively compatible" means the metadata format and property model are compatible — not that every Lively wallpaper in existence will run here.

---

## Writing a Wallpaper

At minimum, a web wallpaper is a folder with `index.html` and `LivelyInfo.json`:

```json
{
  "Title": "My Wallpaper",
  "Author": "You",
  "Description": "A small animated wallpaper",
  "Type": "web",
  "FileName": "index.html"
}
```

Add `LivelyProperties.json` and ÆtherDesk will build native controls and push live updates into it. If you're already writing Lively-style web wallpapers, you mostly won't need to change anything — ÆtherDesk injects its own bridge on top with display geometry, power state, suspend/resume hooks, native fetch routing, and geolocation handling.

---

## Under the Hood

`WallpaperManager` is the spine: one host window and one runtime per display, rebuilt on display configuration changes, with per-display failure isolation. The web runtime is intentionally disposable — `WKWebView` is created on `start()` and fully torn down on `stop()`. Rapidly cycling wallpapers doesn't leave zombie content processes behind.

Persistence is split into two stores: `WallpaperStore` for display-to-wallpaper assignments, and `PropertyStore` for per-wallpaper property overrides. Thumbnails are generated natively — preview image if the bundle includes one, otherwise type-specific rendering (frame grab for video, offscreen `WKWebView` snapshot for web), with a disk cache keyed to bundle modification time.

---

## Building From Source

Clone the repo and open `AetherDesk.xcodeproj` directly in Xcode. No package managers, no code generation step, no third-party dependencies — just AppKit, WebKit, AVFoundation, and the usual Apple stack.

```bash
git clone https://github.com/sdelavega/AetherDesk.git
cd AetherDesk
open AetherDesk.xcodeproj
```

There are two build configurations and they're meaningfully different:

**OSS (default):** Unsandboxed, pulls weather data from open-meteo, runs on macOS 12.0+. This is what you get if you just hit Run.

**App Store:** Sandboxed, uses WeatherKit for weather data, requires macOS 13.5+. WeatherKit requires a paid Apple Developer Program membership — if you don't have one, the weather wallpaper will silently fall back to open-meteo anyway, but the App Store scheme won't archive cleanly without valid entitlements. Switching to this config involves changing the scheme and signing settings; it's doable but not the default path.

If you're just poking around or building for yourself, the OSS configuration is the one you want.

---

## Honest Caveats

The OSS build is unsandboxed by design. The App Store / TestFlight build is fully sandboxed. Display restore at launch works well; hot-plug restore (unplug and replug a display mid-session) is on the list. The codebase is AppKit-first and deliberately light on abstraction — it's a focused utility, not a framework.

---

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
