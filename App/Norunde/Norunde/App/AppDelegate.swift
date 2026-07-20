import AppKit

/// Ensures managed processes are stopped when the app terminates for any reason.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nonisolated stop-all hook set from the main actor UI layer.
    nonisolated(unsafe) static var stopAll: (() -> Void)?
    /// Optional auto-start hook after UI is ready.
    nonisolated(unsafe) static var onReady: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !SingleInstance.acquireOrActivateExisting() {
            // Exit before UI builds a second menu bar icon.
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.onReady?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.stopAll?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app has no regular windows; never auto-quit on window close.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dockless app: still respond if someone re-opens the bundle.
        true
    }
}
