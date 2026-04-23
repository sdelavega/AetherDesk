import AppKit
import Foundation

// MARK: - Updater mode
// If launched with --aetherdesk-updater <pid> <oldAppPath> <newAppPath> <tempDir>,
// perform the atomic swap and relaunch without ever starting NSApplication.
if CommandLine.arguments.count == 6,
   CommandLine.arguments[1] == "--aetherdesk-updater",
   let pid = Int32(CommandLine.arguments[2]) {
    let oldAppPath = CommandLine.arguments[3]
    let newAppPath = CommandLine.arguments[4]
    let tempDir    = CommandLine.arguments[5]
    let fm = FileManager.default

    // Wait for the parent process to die.
    while kill(pid, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.5)
    }
    Thread.sleep(forTimeInterval: 1.0)

    do {
        if fm.fileExists(atPath: oldAppPath) {
            try fm.removeItem(atPath: oldAppPath)
        }
        try fm.moveItem(atPath: newAppPath, toPath: oldAppPath)
    } catch {
        FileHandle.standardError.write(Data("AetherDesk updater failed to swap: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    do {
        if fm.fileExists(atPath: tempDir) {
            try fm.removeItem(atPath: tempDir)
        }
    } catch {
        // Non-fatal: the swap succeeded.
        NSLog("AetherDesk updater: cleanup warning: %@", error.localizedDescription)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [oldAppPath]
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("AetherDesk updater failed to relaunch: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

// MARK: - Normal launch

// Single-instance guard: exit immediately if another copy is already running.
let dominated = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
if dominated.count > 1 {
    NSLog("ÆtherDesk: another instance is already running — exiting.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
