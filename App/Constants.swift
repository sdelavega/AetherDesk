import Foundation

enum Constants {
    static let appName = "AetherDesk"
    static let bundleIdentifier = "com.aetherdesk.AetherDesk"

    enum Defaults {
        static let fpsCap: Int = 30
        static let maxFPS: Int = 60
        static let minFPS: Int = 15
        static let watchdogTimeout: TimeInterval = 5.0
        static let memoryWarningThresholdMB: Int = 200
    }

    enum Directories {
        static let wallpapersSubfolder = "Wallpapers"
        static let bundledWallpapersSubfolder = "Resources/Wallpapers"
    }

    enum Notifications {
        static let wallpaperDidChange = Notification.Name("AetherDesk.wallpaperDidChange")
        static let displayConfigurationDidChange = Notification.Name("AetherDesk.displayConfigurationDidChange")
        static let lowPowerModeDidChange = Notification.Name("AetherDesk.lowPowerModeDidChange")
    }

    enum Keys {
        static let livelyInfo = "LivelyInfo.json"
        static let livelyProperties = "LivelyProperties.json"
        static let indexFile = "index.html"
    }
}
