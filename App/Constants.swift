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
    }

    enum Keys {
        static let livelyInfo = "LivelyInfo.json"
        static let livelyProperties = "LivelyProperties.json"
        static let indexFile = "index.html"
    }
}
