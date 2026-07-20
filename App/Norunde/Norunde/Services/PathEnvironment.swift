import Foundation

/// Resolves a login-shell PATH so menu bar apps can find pnpm/npm/node.
final class PathEnvironment: @unchecked Sendable {
    static let shared = PathEnvironment()

    private let lock = NSLock()
    private var cachedPATH: String?
    private var didResolve = false

    private init() {}

    /// Cached login PATH, or current process PATH as fallback.
    var loginPATH: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPATH {
            return cachedPATH
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Resolve once (or force refresh). Safe to call from background.
    func resolve(force: Bool = false) {
        lock.lock()
        if didResolve && !force {
            lock.unlock()
            return
        }
        lock.unlock()

        let path = Self.readLoginShellPATH() ?? ProcessInfo.processInfo.environment["PATH"]

        lock.lock()
        cachedPATH = path
        didResolve = true
        lock.unlock()
    }

    /// Merge system environment with login PATH and project overrides.
    func environment(extra: [String: String] = [:]) -> [String: String] {
        resolve()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH
        for (key, value) in extra {
            env[key] = value
        }
        return env
    }

    private static func readLoginShellPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "echo -n \"$PATH\""]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[Norunde] PathEnvironment: failed to run login shell: \(error)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }
        return output
    }
}
