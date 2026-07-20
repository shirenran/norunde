import Foundation

/// Discovers and kills processes that belong to a project directory
/// but are not currently managed by Norunde (e.g. leftover terminal `pnpm run dev`).
///
/// Heavy work must run off the main thread.
/// Uses temp-file capture for subprocess output to avoid Pipe buffer deadlocks
/// (`waitUntilExit` while the child blocks on a full stdout pipe).
enum ExternalProcessFinder {
    struct FoundProcess: Identifiable, Equatable, Sendable {
        var id: Int32 { pid }
        var pid: Int32
        var command: String
        var ports: [Int]
    }

    /// Find processes whose command line references the project directory.
    static func find(in directory: String, excluding excludePIDs: Set<Int32> = []) -> [FoundProcess] {
        let normalized = normalize(directory)
        guard !normalized.isEmpty else { return [] }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rows = runPS()
        var candidatePIDs: [Int32] = []
        var commandByPID: [Int32: String] = [:]

        for row in rows {
            if row.pid == selfPID { continue }
            if excludePIDs.contains(row.pid) { continue }
            if excludePIDs.contains(row.ppid) { continue }
            if !isRelated(command: row.command, directory: normalized) { continue }
            if isNoise(command: row.command) { continue }
            candidatePIDs.append(row.pid)
            commandByPID[row.pid] = summarize(row.command)
        }

        // Ports are optional UX sugar — skip entirely when no candidates.
        let portsByPID = candidatePIDs.isEmpty ? [:] : listeningPorts(for: Set(candidatePIDs))

        return candidatePIDs
            .sorted()
            .map { pid in
                FoundProcess(
                    pid: pid,
                    command: commandByPID[pid] ?? "pid \(pid)",
                    ports: portsByPID[pid] ?? []
                )
            }
    }

    @discardableResult
    static func terminate(pids: [Int32], forceAfter seconds: TimeInterval = 1.5) -> [Int32] {
        let unique = Array(Set(pids)).sorted()
        guard !unique.isEmpty else { return [] }

        for pid in unique {
            if Darwin.kill(-pid, SIGTERM) != 0 {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let alive = unique.filter { Darwin.kill($0, 0) == 0 }
            if alive.isEmpty { return unique }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for pid in unique where Darwin.kill(pid, 0) == 0 {
            if Darwin.kill(-pid, SIGKILL) != 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        return unique
    }

    // MARK: - Private

    private struct PSRow {
        var pid: Int32
        var ppid: Int32
        var command: String
    }

    private static func normalize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var p = url.path
        if p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func runPS() -> [PSRow] {
        guard let output = runCapturing(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="],
            timeoutSeconds: 3
        ) else {
            return []
        }

        var rows: [PSRow] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            rows.append(PSRow(pid: pid, ppid: ppid, command: String(parts[2])))
        }
        return rows
    }

    private static func isRelated(command: String, directory: String) -> Bool {
        if command.contains(directory) { return true }
        let last = (directory as NSString).lastPathComponent
        guard !last.isEmpty, last.count > 2 else { return false }
        let hasTool = command.range(
            of: #"\b(node|pnpm|npm|yarn|bun|vite|next|webpack|nuxt|esbuild)\b"#,
            options: .regularExpression
        ) != nil
        return hasTool && command.contains(last)
    }

    private static func isNoise(command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("externalprocessfinder") { return true }
        if lower.hasPrefix("ps ") || lower.contains("/bin/ps") { return true }
        if lower.contains("grep ") { return true }
        if lower.contains("norunde.app") { return true }
        if lower.contains("claude") && lower.contains("norunde") { return true }
        return false
    }

    private static func summarize(_ command: String) -> String {
        if command.count <= 120 { return command }
        return String(command.prefix(117)) + "..."
    }

    private static func listeningPorts(for pids: Set<Int32>) -> [Int32: [Int]] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.sorted().prefix(40).map(String.init).joined(separator: ",")
        guard let text = runCapturing(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", list, "-iTCP", "-sTCP:LISTEN"],
            timeoutSeconds: 3
        ) else {
            return [:]
        }

        var result: [Int32: Set<Int>] = [:]
        let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 2, let pid = Int32(cols[1]) else { continue }
            let lineStr = String(line)
            let ns = NSRange(lineStr.startIndex..<lineStr.endIndex, in: lineStr)
            guard let match = regex?.firstMatch(in: lineStr, options: [], range: ns),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: lineStr),
                  let port = Int(lineStr[r]) else { continue }
            result[pid, default: []].insert(port)
        }
        return result.mapValues { $0.sorted() }
    }

    /// Run a short-lived command, capturing stdout to a temp file (no Pipe deadlock).
    /// Returns nil on launch failure / timeout / empty.
    private static func runCapturing(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("norunde-scan-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let outHandle = try? FileHandle(forWritingTo: tempURL) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outHandle.close()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            // Force if needed
            let forceDeadline = Date().addingTimeInterval(0.4)
            while process.isRunning, Date() < forceDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.interrupt()
            }
            try? outHandle.close()
            NSLog("[Norunde] scan subprocess timed out: \(executable)")
            return nil
        }

        try? outHandle.close()
        process.waitUntilExit()

        guard let data = try? Data(contentsOf: tempURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
