import AppKit

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
