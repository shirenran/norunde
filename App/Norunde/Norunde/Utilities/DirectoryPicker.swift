import AppKit

/// Directory picker that stays in front of MenuBarExtra *content*.
/// Never touches NSStatusItem / status-bar windows (that would hide the menu bar icon).
@MainActor
enum DirectoryPicker {
    static func pickDirectory(
        message: String = "选择前端项目目录",
        prompt: String = "选择",
        startingAt: URL? = nil,
        parentWindow: NSWindow? = nil,
        completion: @escaping (URL?) -> Void
    ) {
        // Only hide the large MenuBarExtra content panel — never the status item icon.
        dismissMenuBarContentWindows(keeping: parentWindow)

        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = startingAt

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)

            // Prefer sheet on our floating editor — above MenuBarExtra content, keeps icon.
            if let parent = parentWindow ?? EditorPanelController.shared.hostWindow, parent.isVisible {
                parent.level = .floating
                parent.makeKeyAndOrderFront(nil)
                panel.beginSheetModal(for: parent) { response in
                    completion(response == .OK ? panel.url : nil)
                }
                return
            }

            // Fallback free-standing panel (after content is dismissed).
            panel.level = .floating
            panel.center()
            panel.begin { response in
                completion(response == .OK ? panel.url : nil)
            }
            // Nudge front once more on next turn.
            DispatchQueue.main.async {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Hide only MenuBarExtra(.window) content panels.
    /// Must NOT hide status-item / status-bar windows or the menu bar icon disappears permanently.
    static func dismissMenuBarContentWindows(keeping keep: NSWindow? = nil) {
        let keepID = keep.map { ObjectIdentifier($0) }
        for window in NSApp.windows {
            if let keepID, ObjectIdentifier(window) == keepID { continue }
            if window === EditorPanelController.shared.hostWindow { continue }
            guard window.isVisible else { continue }

            let className = NSStringFromClass(type(of: window))

            // Hard skip: anything that is (or hosts) the status item / icon.
            if className.localizedCaseInsensitiveContains("StatusBar")
                || className.localizedCaseInsensitiveContains("StatusItem")
                || className.localizedCaseInsensitiveContains("NSStatus")
                || window.level.rawValue >= NSWindow.Level.statusBar.rawValue {
                continue
            }

            // MenuBarExtra(.window) content: sizable empty-title panel, not our editor/log.
            let frame = window.frame
            let looksLikeExtraContent =
                window.title.isEmpty
                && frame.width >= 400
                && frame.height >= 300

            if looksLikeExtraContent {
                window.orderOut(nil)
            }
        }
    }
}
