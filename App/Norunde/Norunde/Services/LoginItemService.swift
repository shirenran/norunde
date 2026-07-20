import Foundation

/// Manages "open Norunde at login" via a user LaunchAgent.
/// Points at ~/Applications/Norunde.app when installed, otherwise the running bundle.
@MainActor
enum LoginItemService {
    static let launchAgentLabel = "app.norunde.login"
    /// Pre-open-source personal label; cleaned up when writing/disabling login item.
    private static let legacyLaunchAgentLabels = [
        "dev.shirenran.norunde.login",
    ]

    static var preferredInstallURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications/Norunde.app", isDirectory: true)
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private static func launchAgentURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Best app URL to launch at login: installed copy preferred over build tree.
    static var launchAppURL: URL {
        if FileManager.default.fileExists(atPath: preferredInstallURL.path) {
            return preferredInstallURL
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle
        }
        return preferredInstallURL
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    /// Enable/disable open-at-login. Returns error message or nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if enabled {
            return enable()
        }
        return disable()
    }

    private static func enable() -> String? {
        do {
            removeLegacyLaunchAgents()
            try writeLaunchAgent(appURL: launchAppURL)
            try loadLaunchAgent()
            return nil
        } catch {
            return "开启开机自启失败：\(error.localizedDescription)"
        }
    }

    private static func disable() -> String? {
        do {
            try unloadLaunchAgent()
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            removeLegacyLaunchAgents()
            return nil
        } catch {
            return "关闭开机自启失败：\(error.localizedDescription)"
        }
    }

    /// Drop old personal LaunchAgent labels after Bundle ID rename.
    private static func removeLegacyLaunchAgents() {
        let uid = getuid()
        let domain = "gui/\(uid)"
        for label in legacyLaunchAgentLabels {
            let url = launchAgentURL(for: label)
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "\(domain)/\(label)"]
            bootout.standardOutput = FileHandle.nullDevice
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()

            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func writeLaunchAgent(appURL: URL) throws {
        let dir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let executable = appURL
            .appendingPathComponent("Contents/MacOS/Norunde")
            .path

        let programArguments: [String]
        if FileManager.default.fileExists(atPath: executable) {
            programArguments = [executable]
        } else {
            programArguments = ["/usr/bin/open", "-a", appURL.path]
        }

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private static func loadLaunchAgent() throws {
        let uid = getuid()
        let domain = "gui/\(uid)"

        // Unload previous first (ignore errors).
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "\(domain)/\(launchAgentLabel)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()

        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, launchAgentURL.path]
        bootstrap.standardOutput = FileHandle.nullDevice
        bootstrap.standardError = FileHandle.nullDevice
        try bootstrap.run()
        bootstrap.waitUntilExit()
        if bootstrap.terminationStatus == 0 { return }

        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", "-w", launchAgentURL.path]
        load.standardOutput = FileHandle.nullDevice
        load.standardError = FileHandle.nullDevice
        try load.run()
        load.waitUntilExit()
        if load.terminationStatus != 0 {
            throw NSError(
                domain: "LoginItemService",
                code: Int(load.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "launchctl load failed (\(load.terminationStatus))"]
            )
        }
    }

    private static func unloadLaunchAgent() throws {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "\(domain)/\(launchAgentLabel)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()

        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", "-w", launchAgentURL.path]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()
    }
}
