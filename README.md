# ÆtherDesk

Live wallpapers for macOS that actually behave themselves.

ÆtherDesk is a native menu-bar-only app that hosts animated HTML/JS wallpapers, looping video, and static images behind your desktop icons. It was born out of the simple frustration that Lively — which is genuinely great on Windows — doesn't exist on macOS, and every macOS alternative either demands too much trust, too much RAM, or too much forgiveness.

It reads Lively's bundle format directly, so a lot of community wallpapers just work. It doesn't try to run *everything* Lively can run — executables, Unity, and engine-specific bundles aren't happening — but if it's a web wallpaper, a video loop, or a still image, you're in the right place.

---

## Get It

**TestFlight (App Store build):** The current build is on TestFlight while the App Store submission finishes review. Sandboxed, macOS 14+. The app is free; an optional **ÆtherDesk Premium** in-app purchase (lifetime or yearly) switches WeatherAether to Apple Weather data. Without it, WeatherAether uses Open-Meteo, same as the OSS build. TestFlight purchases are free.

[**Join the TestFlight Beta →**](https://testflight.apple.com/join/KFUDzBqY)

**GitHub Releases (OSS build):** Prefer the open-source configuration? Grab the latest release from the [Releases page](https://github.com/sdelavega/AetherDesk/releases). It's signed and notarized by me, so macOS will open it without complaint — no right-click tricks, no disabling Gatekeeper, no terminal incantations. Just download and run.

**Homebrew (OSS build):**

```bash
brew install --cask sdelavega/tap/aetherdesk
```

The OSS build uses Sparkle for updates. Choose **Check for Updates…** from the menu bar or enable automatic checks in **Preferences › General**. An update check sends only the app version and macOS version to `sdelavega.github.io`, nothing else. System profiling is disabled. You can disable automatic checks in **Preferences › General**; the App Store build receives updates through Apple.

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

Preferences has four tabs: **General** (launch at login, updates, wallpaper folder), **Performance** (FPS, pause policies, network controls), **Wallpaper** (the picker, thumbnails, property editor, and a view of what domains the selected wallpaper talks to), and **About**. The App Store build adds a fifth, **Premium**, for buying or restoring Apple Weather access.

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

Clone the repo and open `ÆtherDesk.xcodeproj` directly in Xcode. Xcode resolves Sparkle 2 through Swift Package Manager for the OSS target. No code generation step is needed; the App Store target does not link Sparkle.

```bash
git clone https://github.com/sdelavega/AetherDesk.git
cd AetherDesk
open ÆtherDesk.xcodeproj
```

There are two schemes and they're meaningfully different:

**`AetherDesk` (OSS, default):** Unsandboxed, pulls weather data from open-meteo, runs on macOS 14+. Includes Sparkle updates. This is what you get if you just hit Run.

**`AetherDesk-AppStore`:** Sandboxed, macOS 14+, with WeatherKit behind the Premium in-app purchase. Running it from Xcode uses `AetherDesk.storekit` for local purchase testing, so you can buy, restore, and refund (Debug › StoreKit › Manage Transactions) without App Store Connect. WeatherKit itself requires a paid Apple Developer Program membership and the WeatherKit capability on your App ID; without them the weather wallpaper falls back to open-meteo, and the scheme won't archive cleanly.

If you're just poking around or building for yourself, the OSS scheme is the one you want.

Tests: `AetherDesk` runs the unit tests (no signing needed). `AetherDesk-AppStore` also runs the StoreKit tests, which are hosted in the app and need your own signing team.

---

## Releasing the OSS Build

Start on a clean `v1.4` or `main` checkout with Xcode, Python 3, Node.js and the standard macOS command-line tools. Run `scripts/test-release.sh` for local pipeline checks; `shellcheck scripts/release-*.sh scripts/make-dmg.sh scripts/test-release.sh` checks shell syntax and usage.

```bash
scripts/release-build.sh 1.4.0 41 --unsigned-test
scripts/release-publish.sh 1.4.0
```

The unsigned rehearsal changes versions in a temporary copy, verifies both app schemes, runs `scripts/test-gate.sh --with-js --with-appstore`, archives Release without Developer ID signing, exports and ad-hoc signs the archived app, and creates the legacy zip/checksum, DMG and manifest in `dist/1.4.0/`. It asserts that the v1.3 handover reaches and fails the team check. Notarization and Sparkle signing print explicit skipped messages. The checkout's versions stay unchanged; unsigned artifacts cannot be published. Move the output directory aside before rebuilding the same version.

For a supervised signed release, omit `--unsigned-test`. Install a Developer ID Application identity for team `N5PUFD82GV`, configure `xcrun notarytool` with keychain profile `AetherDesk` (or set `NOTARIZE_KEYCHAIN_PROFILE`), and keep the Sparkle EdDSA key in the keychain under account `AetherDesk`. The scripts never export the private key. Child tools receive only `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_*`, `USER` and `DEVELOPER_DIR`; GitHub CLI uses its local authentication. The build rejects a placeholder public key, verifies the Sparkle 2.10.0 SPM tool hashes against `scripts/sparkle-tools.sha256`, notarizes and staples the app and DMG, checks v1.3 compatibility, and verifies the generated appcast enclosure signature. It uses local `ExportOptions.plist` when present, otherwise generates Developer ID export options for the team. Only a successful signed build commits the version bump for both targets.

`dist/<version>/` contains `AetherDesk.zip`, `AetherDesk.zip.sha256` (standard SHA-256 plus `AetherDesk.zip` filename), `AetherDesk-<version>.dmg`, `release-info.txt`, and `manifest.txt` (SHA-256, byte size, filename); signed builds also contain `appcast.xml`. Replacing resolved Sparkle tools requires deliberately updating the pins after checking the new upstream artifact.

`release-publish.sh <version>` prints the complete plan without creating files or contacting a service. With `--execute`, it validates signed artifacts and current HEAD, requires the exact version typed at the prompt, creates the GitHub release, commits and pushes the appcast from a detached `gh-pages` worktree, and renders, commits and pushes `Casks/aetherdesk.rb` in the clean sibling `../homebrew-tap` clone. The `gh-pages` branch must already exist. It then downloads the served feed and all three assets and checks their hashes and sizes against the manifest. A partial publish stops with a diagnostic; inspect the remote state before retrying.

The cask removes the OSS app's Application Support folder, preferences and ASCII-bundle-ID thumbnail cache. It leaves the App Store container intact; the OSS build is unsandboxed and does not create it. No saved-state path is included because none was observed.

---

## Honest Caveats

The OSS build is unsandboxed by design. The App Store / TestFlight build is fully sandboxed. The codebase is AppKit-first and deliberately light on abstraction — it's a focused utility, not a framework.

---

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
