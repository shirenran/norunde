import Foundation

/// Manages Process lifecycle per project: start / stop / restart, process group kill, logs.
@MainActor
final class ProcessManager {
    private struct ManagedProcess {
        var process: Process
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var intentionallyStopped: Bool
        /// Only set when the shell is confirmed to be a process-group leader.
        var processGroupID: pid_t?
        var incompleteStdout: String = ""
        var incompleteStderr: String = ""
    }

    private var managed: [UUID: ManagedProcess] = [:]
    /// One-shot jobs (build/test) keyed by job id; output goes to the project log buffer.
    private var oneShots: [UUID: ManagedProcess] = [:]
    private var oneShotProject: [UUID: UUID] = [:] // jobId -> projectId
    private var runtimeStates: [UUID: RuntimeState] = [:]
    private var logBuffers: [UUID: LogBuffer] = [:]
    private var restartAfterStop: Set<UUID> = []
    /// Projects removed from UI while a process may still be winding down.
    private var pendingDispose: Set<UUID> = []

    private let pathEnvironment: PathEnvironment
    private let stopTimeoutSeconds: TimeInterval

    /// Fired on MainActor when status or logs change.
    var onStateChange: (() -> Void)?

    init(pathEnvironment: PathEnvironment = .shared, stopTimeoutSeconds: TimeInterval = 3) {
        self.pathEnvironment = pathEnvironment
        self.stopTimeoutSeconds = stopTimeoutSeconds
    }

    func runtimeState(for id: UUID) -> RuntimeState {
        runtimeStates[id] ?? .stopped
    }

    /// PIDs currently owned by Norunde for a project (shell + descendants).
    /// Used to exclude them when scanning for external leftovers.
    func managedPIDs(for id: UUID) -> Set<Int32> {
        guard let entry = managed[id], entry.process.isRunning else { return [] }
        let root = entry.process.processIdentifier
        var pids: Set<Int32> = [root]
        for child in descendantPIDs(of: root) {
            pids.insert(child)
        }
        return pids
    }

    func logBuffer(for id: UUID) -> LogBuffer {
        if let buffer = logBuffers[id] {
            return buffer
        }
        let buffer = LogBuffer()
        logBuffers[id] = buffer
        return buffer
    }

    func clearLogs(for id: UUID) {
        logBuffer(for: id).clear()
        notify()
    }

    /// Drop runtime bookkeeping for a removed project (logs, status, optional stop).
    /// If a process is still running, signal stop and finish cleanup in `handleTermination`.
    func dispose(projectId: UUID) {
        restartAfterStop.remove(projectId)
        pendingDispose.insert(projectId)

        if managed[projectId] != nil {
            // Keep buffers until termination so final flush does not recreate empty state.
            stop(projectId: projectId)
            return
        }

        logBuffers.removeValue(forKey: projectId)
        runtimeStates.removeValue(forKey: projectId)
        pendingDispose.remove(projectId)
        notify()
    }

    func start(project: Project) {
        let id = project.id
        let current = runtimeState(for: id).status
        guard current == .stopped || current == .failed else {
            return
        }

        pendingDispose.remove(id)
        restartAfterStop.remove(id)

        let command = project.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(project: project, command: command) else { return }

        setState(id, RuntimeState(status: .starting, pid: nil, lastError: nil, startedAt: Date()))
        logBuffer(for: id).appendSystem("启动：\(command)")
        notify()

        launch(
            key: id,
            projectId: id,
            directory: project.directory,
            env: project.env,
            command: command,
            storeIn: .primary
        )
    }

    /// Run a named/extra command without replacing the long-running primary process.
    /// Output is appended to the same project log. Safe while primary is running.
    @discardableResult
    func runOneShot(project: Project, title: String, command: String) -> UUID? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logBuffer(for: project.id).appendSystem("错误：命令为空（\(title)）")
            notify()
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDir), isDir.boolValue else {
            logBuffer(for: project.id).appendSystem("错误：项目目录不存在：\(project.directory)")
            notify()
            return nil
        }

        let jobId = UUID()
        logBuffer(for: project.id).appendSystem("执行「\(title)」：\(trimmed)")
        notify()
        launch(
            key: jobId,
            projectId: project.id,
            directory: project.directory,
            env: project.env,
            command: trimmed,
            storeIn: .oneShot
        )
        return jobId
    }

    private enum ProcessStore {
        case primary
        case oneShot
    }

    private func validate(project: Project, command: String) -> Bool {
        let id = project.id
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDir), isDir.boolValue else {
            setState(id, RuntimeState(status: .failed, pid: nil, lastError: "项目目录不存在：\(project.directory)", startedAt: nil))
            logBuffer(for: id).appendSystem("错误：项目目录不存在：\(project.directory)")
            notify()
            return false
        }
        guard !command.isEmpty else {
            setState(id, RuntimeState(status: .failed, pid: nil, lastError: "启动命令为空", startedAt: nil))
            logBuffer(for: id).appendSystem("错误：启动命令为空")
            notify()
            return false
        }
        return true
    }

    private func launch(
        key: UUID,
        projectId: UUID,
        directory: String,
        env: [String: String],
        command: String,
        storeIn: ProcessStore
    ) {
        pathEnvironment.resolve()
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell for PATH / nvm hooks.
        // User command runs in background so the shell can trap TERM and tear down the tree.
        // After -c script, first arg is $0, second is $1 (the user command).
        let wrapper = """
        killtree() {
          local root="$1" sig="${2:-TERM}" kid
          for kid in $(pgrep -P "$root" 2>/dev/null); do
            killtree "$kid" "$sig"
          done
          kill -"$sig" "$root" 2>/dev/null
        }
        child=0
        trap 'if [ "$child" -ne 0 ]; then killtree "$child" TERM; fi; for kid in $(pgrep -P $$ 2>/dev/null); do killtree "$kid" TERM; done; exit 143' TERM INT
        eval "$1" &
        child=$!
        wait $child
        rc=$?
        for kid in $(pgrep -P $$ 2>/dev/null); do killtree "$kid" TERM; done
        exit $rc
        """
        process.arguments = ["-lc", wrapper, "norunde-runner", command]
        process.currentDirectoryURL = directoryURL
        process.environment = pathEnvironment.environment(extra: env)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let entry = ManagedProcess(
            process: process,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle,
            intentionallyStopped: false,
            processGroupID: nil
        )
        switch storeIn {
        case .primary:
            managed[key] = entry
        case .oneShot:
            oneShots[key] = entry
            oneShotProject[key] = projectId
        }

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                self?.consumeOutput(key: key, projectId: projectId, data: data, stream: .stdout, storeIn: storeIn)
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                self?.consumeOutput(key: key, projectId: projectId, data: data, stream: .stderr, storeIn: storeIn)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(key: key, projectId: projectId, process: proc, storeIn: storeIn)
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            var groupID: pid_t?
            if setpgid(pid, pid) == 0 {
                groupID = pid
            } else {
                NSLog("[Norunde] setpgid failed for pid \(pid): \(String(cString: strerror(errno))); using pid+children kill")
            }
            switch storeIn {
            case .primary:
                managed[key]?.processGroupID = groupID
                setState(projectId, RuntimeState(status: .running, pid: pid, lastError: nil, startedAt: runtimeState(for: projectId).startedAt ?? Date()))
                logBuffer(for: projectId).appendSystem("进程已启动 pid=\(pid)")
            case .oneShot:
                oneShots[key]?.processGroupID = groupID
                logBuffer(for: projectId).appendSystem("一次性任务已启动 pid=\(pid)")
            }
            notify()
        } catch {
            cleanupHandles(key: key, storeIn: storeIn)
            switch storeIn {
            case .primary:
                managed.removeValue(forKey: key)
                setState(projectId, RuntimeState(status: .failed, pid: nil, lastError: error.localizedDescription, startedAt: nil))
                logBuffer(for: projectId).appendSystem("启动失败：\(error.localizedDescription)")
            case .oneShot:
                oneShots.removeValue(forKey: key)
                oneShotProject.removeValue(forKey: key)
                logBuffer(for: projectId).appendSystem("一次性任务启动失败：\(error.localizedDescription)")
            }
            notify()
        }
    }

    func stop(projectId: UUID) {
        guard let entry = managed[projectId] else {
            setState(projectId, .stopped)
            notify()
            return
        }
        let status = runtimeState(for: projectId).status
        // Already stopping, or idle — nothing to do.
        guard status == .running || status == .starting || status == .failed else {
            return
        }

        managed[projectId]?.intentionallyStopped = true
        setState(projectId, RuntimeState(status: .stopping, pid: entry.process.processIdentifier, lastError: nil, startedAt: runtimeState(for: projectId).startedAt))
        logBuffer(for: projectId).appendSystem("正在停止…")
        notify()

        sendStopSignal(to: entry, signal: SIGTERM)

        let timeout = stopTimeoutSeconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let still = self.managed[projectId], still.process.isRunning else { return }
            self.logBuffer(for: projectId).appendSystem("超时，发送 SIGKILL")
            self.sendStopSignal(to: still, signal: SIGKILL)
            // Force cleanup if still hanging
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let final = self.managed[projectId], final.process.isRunning {
                final.process.terminate()
            }
        }
    }

    func restart(project: Project) {
        let id = project.id
        let status = runtimeState(for: id).status
        if status == .stopped || status == .failed {
            start(project: project)
            return
        }
        restartAfterStop.insert(id)
        if status != .stopping {
            stop(projectId: id)
        }
    }

    /// Stop all managed processes (app termination).
    func stopAll() {
        let ids = Array(managed.keys)
        let oneShotIds = Array(oneShots.keys)
        restartAfterStop.removeAll()
        pendingDispose.removeAll()
        for id in ids {
            stop(projectId: id)
        }
        // Kill one-shots too.
        for jobId in oneShotIds {
            if let entry = oneShots[jobId] {
                entry.process.terminationHandler = nil
                sendStopSignal(to: entry, signal: SIGTERM)
            }
        }
        // Best-effort synchronous wait (short).
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let anyPrimary = managed.values.contains { $0.process.isRunning }
            let anyOneShot = oneShots.values.contains { $0.process.isRunning }
            if !anyPrimary && !anyOneShot { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for (id, entry) in managed {
            if entry.process.isRunning {
                sendStopSignal(to: entry, signal: SIGKILL)
            }
            entry.process.terminationHandler = nil
            cleanupHandles(key: id, storeIn: .primary)
        }
        for (jobId, entry) in oneShots {
            if entry.process.isRunning {
                sendStopSignal(to: entry, signal: SIGKILL)
            }
            entry.process.terminationHandler = nil
            cleanupHandles(key: jobId, storeIn: .oneShot)
        }
        managed.removeAll()
        oneShots.removeAll()
        oneShotProject.removeAll()
        for id in ids {
            setState(id, .stopped)
        }
        notify()
    }

    // MARK: - Private

    private func setState(_ id: UUID, _ state: RuntimeState) {
        runtimeStates[id] = state
    }

    private func notify() {
        onStateChange?()
    }

    private func entry(for key: UUID, storeIn: ProcessStore) -> ManagedProcess? {
        switch storeIn {
        case .primary: return managed[key]
        case .oneShot: return oneShots[key]
        }
    }

    private func setEntry(_ entry: ManagedProcess, key: UUID, storeIn: ProcessStore) {
        switch storeIn {
        case .primary: managed[key] = entry
        case .oneShot: oneShots[key] = entry
        }
    }

    private func removeEntry(key: UUID, storeIn: ProcessStore) {
        switch storeIn {
        case .primary: managed.removeValue(forKey: key)
        case .oneShot:
            oneShots.removeValue(forKey: key)
            oneShotProject.removeValue(forKey: key)
        }
    }

    private func consumeOutput(key: UUID, projectId: UUID, data: Data, stream: LogStream, storeIn: ProcessStore) {
        guard !data.isEmpty else { return }
        guard var entry = entry(for: key, storeIn: storeIn) else { return }
        guard let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return
        }

        var pending = (stream == .stdout ? entry.incompleteStdout : entry.incompleteStderr) + chunk
        var completed: [String] = []
        while let range = pending.range(of: "\n") {
            let line = String(pending[..<range.lowerBound])
            completed.append(line)
            pending = String(pending[range.upperBound...])
        }
        if stream == .stdout {
            entry.incompleteStdout = pending
        } else {
            entry.incompleteStderr = pending
        }
        setEntry(entry, key: key, storeIn: storeIn)

        let buffer = logBuffer(for: projectId)
        for line in completed {
            buffer.append(stream: stream, text: line)
        }
        notify()
    }

    private func handleTermination(key: UUID, projectId: UUID, process: Process, storeIn: ProcessStore) {
        let intentional = entry(for: key, storeIn: storeIn)?.intentionallyStopped ?? false
        if let entry = entry(for: key, storeIn: storeIn) {
            if !entry.incompleteStdout.isEmpty {
                logBuffer(for: projectId).append(stream: .stdout, text: entry.incompleteStdout)
            }
            if !entry.incompleteStderr.isEmpty {
                logBuffer(for: projectId).append(stream: .stderr, text: entry.incompleteStderr)
            }
        }
        cleanupHandles(key: key, storeIn: storeIn)
        removeEntry(key: key, storeIn: storeIn)

        let code = process.terminationStatus
        let reason = process.terminationReason

        // One-shot: only log, never change primary runtime state.
        if storeIn == .oneShot {
            if intentional {
                logBuffer(for: projectId).appendSystem("一次性任务已取消（exit \(code)）")
            } else if code == 0 {
                logBuffer(for: projectId).appendSystem("一次性任务完成（exit 0）")
            } else {
                logBuffer(for: projectId).appendSystem("一次性任务失败 code=\(code) reason=\(reason.rawValue)")
            }
            notify()
            return
        }

        let shouldDispose = pendingDispose.remove(projectId) != nil
        let shouldRestart = !shouldDispose && restartAfterStop.remove(projectId) != nil

        if shouldDispose {
            logBuffers.removeValue(forKey: projectId)
            runtimeStates.removeValue(forKey: projectId)
            notify()
            return
        }

        if runtimeStates[projectId]?.status == .stopped {
            notify()
            if shouldRestart {
                NotificationCenter.default.post(name: .norundeShouldRestartProject, object: projectId)
            }
            return
        }

        if intentional || code == 0 {
            let label = intentional ? "已停止（exit \(code)）" : "进程已结束（exit \(code)）"
            logBuffer(for: projectId).appendSystem(label)
            setState(projectId, .stopped)
        } else {
            let message = "进程退出 code=\(code) reason=\(reason.rawValue)"
            logBuffer(for: projectId).appendSystem(message)
            setState(projectId, RuntimeState(status: .failed, pid: nil, lastError: message, startedAt: nil))
        }
        notify()

        if shouldRestart {
            NotificationCenter.default.post(name: .norundeShouldRestartProject, object: projectId)
        }
    }

    private func cleanupHandles(key: UUID, storeIn: ProcessStore) {
        if let entry = entry(for: key, storeIn: storeIn) {
            entry.stdoutHandle?.readabilityHandler = nil
            entry.stderrHandle?.readabilityHandler = nil
            try? entry.stdoutHandle?.close()
            try? entry.stderrHandle?.close()
        }
    }

    /// Signal the shell and its descendant tree without risking the app's own process group.
    private func sendStopSignal(to entry: ManagedProcess, signal: Int32) {
        let pid = entry.process.processIdentifier
        guard pid > 0 else { return }

        if let pgid = entry.processGroupID, pgid > 0 {
            // Confirmed group leader: tear down the whole group.
            _ = kill(-pgid, signal)
        }

        // Walk the full descendant tree (pnpm → node often nests deeper than one level).
        // Only use group kill above when setpgid succeeded; otherwise kill by pid tree.
        let descendants = descendantPIDs(of: pid)
        for child in descendants.reversed() {
            _ = kill(child, signal)
        }
        _ = kill(pid, signal)
    }

    /// Collect all descendant PIDs of `root` via repeated `pgrep -P` (BFS).
    private func descendantPIDs(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        while let current = queue.first {
            queue.removeFirst()
            for child in directChildren(of: current) where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private func directChildren(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
            .filter { $0 > 1 }
    }
}

extension Notification.Name {
    static let norundeShouldRestartProject = Notification.Name("norundeShouldRestartProject")
}
