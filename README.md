# AetherDesk - Architecture & Design Document

## 1. App Structure

```
AetherDesk/
├── App/
│   ├── main.swift                    # Manual app entry point
│   ├── AppDelegate.swift             # App lifecycle, menu bar setup
│   └── Constants.swift               # App-wide constants
├── Core/
│   ├── WallpaperManager.swift       # Central wallpaper orchestration
│   ├── DisplayManager.swift          # Multi-display management
│   ├── WallpaperHostWindow.swift     # Per-display wallpaper window
│   └── WallpaperRuntime.swift        # Abstract wallpaper runtime
├── WallpaperTypes/
│   ├── WebWallpaperRuntime.swift     # WKWebView-based HTML/JS wallpaper
│   ├── VideoWallpaperRuntime.swift   # AVPlayer-based video wallpaper
│   └── ImageWallpaperRuntime.swift   # Static/dynamic image wallpaper
├── LivelyCompatibility/
│   ├── LivelyInfoParser.swift       # Parse LivelyInfo.json
│   ├── LivelyPropertiesParser.swift  # Parse LivelyProperties.json
│   └── PropertyBridge.swift          # JS-to-native property bridge
├── Import/
│   ├── WallpaperBundle.swift         # Normalized wallpaper bundle model
│   ├── WallpaperImporter.swift       # Import from folder/archive
│   └── WallpaperValidator.swift      # Admission screening
├── UI/
│   ├── MenuBarController.swift       # NSStatusItem menu bar UI
│   ├── WallpaperPickerViewController.swift  # Wallpaper selection
│   ├── PropertyEditorViewController.swift   # Per-wallpaper settings
│   └── PreferencesWindowController.swift     # App preferences
├── Persistence/
│   ├── WallpaperStore.swift         # Persist wallpaper configs
│   └── PropertyStore.swift          # Persist property values
└── Resources/
    ├── Assets.xcassets
    ├── Wallpapers/                   # Built-in sample wallpapers
    └── Info.plist
```

## 2. Windowing Strategy

### The macOS Desktop Challenge

macOS does not provide a formal API for " wallpaper windows." The closest approximations:

1. **NSWindow at desktop level** - Setting `window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))` places content behind normal windows but in front of the desktop picture. This doesn't work for true wallpaper behavior.

2. **Secondary monitor mode** - No official wallpaper API exists.

3. **The chosen approach**: Use regular borderless NSWindows at `.desktop` level but treat them as wallpaper content. Accept that macOS wallpaper management is controlled by System Settings > Wallpaper, and provide clear UX when our wallpaper cannot override it.

### Wallpaper Host Windows

Each display gets one `WallpaperHostWindow`:

```swift
class WallpaperHostWindow: NSWindow {
    // Borderless, non-activating
    // level = .desktop (try), fall back to .normal - 1
    // collectionBehavior = [.canJoinSpaces, .stationary, .ignoresCycle]
    // isOpaque = false for web content that may have transparency
    // backgroundColor = .clear
    // ignoresMouseEvents = true (normal mode)
    // becomesKeyOnlyIfNeeded
}
```

### Display Reconfiguration

- `DisplayManager` observes `NSApplication.didChangeScreenParametersNotification`
- On display change: recreate windows for new display configuration
- On display removal: destroy corresponding wallpaper window

## 3. Wallpaper Runtime Model

### Runtime Protocol

```swift
protocol WallpaperRuntime {
    var displayID: CGDirectDisplayID { get }
    var isPaused: Bool { get }
    func start() throws
    func pause()
    func resume()
    func stop()
    func updateProperty(_ key: String, value: Any)
    func reload() throws
}
```

### WebWallpaperRuntime

- Uses `WKWebView` with `WKWebViewConfiguration`
- Runs `index.html` from imported bundle
- JavaScript bridge via `window.webkit.messageHandlers`
- Supports Lively property updates via custom JS API

### VideoWallpaperRuntime

- Uses `AVPlayerView` (hidden player) or `AVPlayerLayer`
- Loops playback
- Pauses when display sleeps

### ImageWallpaperRuntime

- Uses `NSImageView` or `NSLayer` with `NSImage`
- Supports animated images (GIF via `NSImage` representation)

## 4. Import/Validation Pipeline

### Import Flow

```
1. User selects folder/archive
2. WallpaperImporter extracts and validates structure
3. WallpaperValidator inspects contents:
   - Checks for LivelyInfo.json / LivelyProperties.json
   - Scans JS for suspicious patterns (eval, excessive timers, fetch spam)
   - Estimates resource profile
   - Checks for known-unsupported APIs
4. Validator returns Classification:
   - .allowed
   - .allowedWithLimits(fps: 30, networkBudget: 5)
   - .rejected(reason: String)
5. On success: Bundle stored in app's wallpapers directory
6. User shown import report
```

### Validation Rules

| Check | Policy |
|-------|--------|
| JS eval() usage | Warn, allow |
| setInterval < 100ms | Limit to 30fps |
| WebGL usage | Allow |
| Constant fetch/XHR | Reject or warn |
| External script injection | Reject |
| File size > 50MB | Warn |
| No LivelyInfo.json | Allow (treat as generic HTML) |
| Unity/CEF patterns | Reject |

## 5. Lively Property Bridge

### JS API Surface

```javascript
// Provided to wallpaper JS
window.aetherDesk = {
    properties: {
        get: () => { /* current property values */ },
        onUpdate: (callback) => { /* register for native updates */ }
    },
    display: {
        width: screen.width,
        height: screen.height,
        scaleFactor: window.devicePixelRatio,
        id: displayId,
        isPrimary: boolean
    },
    system: {
        isLowPowerMode: boolean,
        isOnline: boolean,
        fpsCap: 30,
        qualityMode: 'balanced' // 'light', 'balanced', 'heavy'
    },
    wallpaper: {
        setFPS: (fps) => {},
        getFPS: () => 30
    }
};
```

### Property Types Supported

- `RangeProperty` → NSSlider
- `BoolProperty` → NSButton (checkbox)
- `ChoiceProperty` → NSPopUpButton
- `ColorProperty` → NSColorWell
- `TextProperty` → NSTextField

## 6. Performance Policy

### Default FPS Cap: 30

- User configurable: 15, 30, 60
- `CADisplayLink` targetFPS clamped
- Web wallpapers: `requestAnimationFrame` throttled

### Power Saving

| Event | Action |
|-------|--------|
| Display sleeps | Pause wallpaper runtime |
| System locks | Pause wallpaper runtime |
| App enters background | Pause non-visible wallpapers |
| Low Power Mode active | Force 15fps cap, reduce effects |
| Battery < 20% | Suggest switching to safe mode |

### Crash Recovery

```
1. WallpaperRuntime detects hang (> 5s without render)
2. Attempt soft reload (reload web content)
3. If fail: switch to static fallback image
4. If fail: mark wallpaper as broken, notify user
5. App remains functional with fallback
```

## 7. Failure Recovery Model

```
Normal Operation
      │
      ▼
┌─────────────┐
│ Wallpaper   │── crash/hang
│ Runtime     │
└─────────────┘
      │
      ▼
┌─────────────────┐
│ RecoveryPolicy  │
└─────────────────┘
      │
      ├─── Timeout (< 5s) ───→ Soft Reload
      │                              │
      │                              ▼
      │                      ┌───────────────┐
      │                      │ Success?     │
      │                      └───────────────┘
      │                              │
      │         ┌───────────────────┴───────────────────┐
      │         ▼                                       ▼
      │  ┌───────────────┐                      ┌───────────────┐
      │  │     Yes      │                      │      No      │
      │  │ Resume ops   │                      │ Static fallback │
      │  └───────────────┘                      └───────────────┘
      │                                               │
      └─── Hard crash ──────→ Static fallback ◄────────┘
```

## 8. macOS Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| No wallpaper API | Cannot truly replace desktop wallpaper | Clear UX: "Desktop wallpaper must be set to 'Solid Color' for AetherDesk to show content" |
| WKWebView memory | HTML wallpapers use memory | FPS cap, memory monitoring, user warning |
| Multi-display是不同的 | Each display needs separate window | DisplayManager handles per-display |
| No force-quite for web content | Misbehaving JS can hang app | WebContentProcessTerminationHandler, watchdog timer |
| Screen sharing can leak wallpaper | Privacy concern | Detect screen sharing, optionally hide |
| Accessibility API needed for some features | Potential App Store issues | Sandbox with exceptions or non-sandboxed |

## 9. Info.plist Configuration

```xml
LSUIElement: true  <!-- No Dock icon -->
NSPrincipalClass: NSApplication
CFBundleDisplayName: AetherDesk
LSMinimumSystemVersion: 12.0
```

## 10. Entitlements

```xml
com.apple.security.app-sandbox: true
com.apple.security.network.client: true  <!-- For networked wallpapers -->
com.apple.security.files.user-selected.read-write: true  <!-- For import -->
com.apple.security.files.downloads.read-write: true
```

## 11. Implementation Phases

### Phase 1: Core Shell
- Menu bar app with basic status item
- Single display wallpaper window
- Load HTML wallpaper from bundle
- Basic stop/start

### Phase 2: Multi-Display
- DisplayManager with screen observation
- Per-display window creation
- Window recreation on display change

### Phase 3: Lively Compatibility
- LivelyInfo.json parser
- LivelyProperties.json parser
- Property editor UI
- PropertyBridge JS interface

### Phase 4: Validation
- WallpaperValidator
- Import UI with classification report
- Allow/limit/reject flow

### Phase 5: Polish
- Video wallpaper runtime
- Safe mode / fallback
- Preferences window
- Crash recovery

## 12. Compatibility Matrix (Planned)

| Wallpaper Type | Status | Notes |
|----------------|--------|-------|
| HTML/CSS/JS | Planned | WKWebView |
| Canvas 2D | Planned | WKWebView |
| WebGL/WebGL2 | Planned | WKWebView with metal fallback |
| Video (mp4/mov) | Planned | AVPlayer |
| Images | Planned | NSImageView |
| Unity EXE | Rejected | Windows-only |
| CEF App | Rejected | Windows-only |
