import Foundation

enum Constants {
    static let appName = "ÆtherDesk"
    static let bundleIdentifier = "com.aetherdesk.AetherDesk"

    enum Defaults {
        static let fpsCap: Int = 30
        static let maxFPS: Int = 60
        static let minFPS: Int = 15

        /// How often web wallpapers should ping the native side with a
        /// heartbeat. Set from JS via setInterval.
        static let watchdogHeartbeatInterval: TimeInterval = 5.0

        /// Seconds of heartbeat silence before a runtime is considered
        /// unresponsive and demoted to safe content for its display.
        static let watchdogTimeout: TimeInterval = 30.0

        static let memoryWarningThresholdMB: Int = 200

        /// Seconds after launch before the first automatic update check fires.
        static let updateCheckInitialDelay: TimeInterval = 30

        /// Seconds between periodic update checks (24 hours).
        static let updateCheckInterval: TimeInterval = 86_400

        /// Maximum response body size (bytes) for wallpaper native fetch proxy.
        static let maxNativeFetchResponseBytes: Int64 = 5_000_000 // 5 MB
    }

    enum Directories {
        static let wallpapersSubfolder = "Wallpapers"
        static let bundledWallpapersSubfolder = "Resources/Wallpapers"
    }

    enum Notifications {
        static let wallpaperDidChange = Notification.Name("ÆtherDesk.wallpaperDidChange")
        static let displayConfigurationDidChange = Notification.Name("ÆtherDesk.displayConfigurationDidChange")
        static let lowPowerModeDidChange = Notification.Name("ÆtherDesk.lowPowerModeDidChange")

        /// Posted by a runtime when it has decided it cannot continue
        /// (watchdog trip, web content process terminated, AV player item
        /// failed). `userInfo["displayID"]` carries the affected display so
        /// the manager can demote just that one.
        static let runtimeDidFail = Notification.Name("ÆtherDesk.runtimeDidFail")

        /// Posted by UpdateManager when a newer release is found during a quiet
        /// (periodic) check. `object` is the `UpdateManager.GitHubRelease` value.
        static let updateAvailable = Notification.Name("ÆtherDesk.updateAvailable")

        /// Posted by WallpaperImporter after a bundle is deleted from disk.
        /// `userInfo["bundleID"]` carries the deleted bundle's UUID string so
        /// WallpaperManager can tear down any runtime currently showing it.
        static let wallpaperDeleted = Notification.Name("ÆtherDesk.wallpaperDeleted")
    }

    enum Keys {
        static let livelyInfo = "LivelyInfo.json"
        static let livelyProperties = "LivelyProperties.json"
        static let indexFile = "index.html"
    }
}
