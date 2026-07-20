import AppKit
import Foundation

/// Ensure only one Norunde instance runs. Second launch activates the first and exits.
enum SingleInstance {
    static let bundleID = "app.norunde"

    /// Call as early as possible in app launch. Returns false if this process should exit.
    @discardableResult
    static func acquireOrActivateExisting() -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }

        guard let existing = others.first else {
            return true
        }

        // Bring existing instance forward (menu bar app may not show a window).
        if #available(macOS 14.0, *) {
            existing.activate()
        } else {
            existing.activate(options: [.activateAllWindows])
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.norunde.activate"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSLog("[Norunde] another instance is running (pid=\(existing.processIdentifier)); exiting")
        return false
    }
}
