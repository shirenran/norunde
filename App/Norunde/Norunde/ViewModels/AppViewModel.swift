import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedProjectId: UUID?
    @Published var isEditorPresented = false
    @Published var editorMode: EditorMode = .create
    @Published var editorDraft = ProjectDraft()
    @Published var bannerError: String?
    @Published private(set) var logRevision: UInt64 = 0
    @Published private(set) var statusRevision: UInt64 = 0
    /// External leftovers for the selected project (not managed by Norunde).
    @Published private(set) var externalProcesses: [ExternalProcessFinder.FoundProcess] = []
    @Published private(set) var isScanningExternal = false
    @Published var openAtLogin: Bool = LoginItemService.isEnabled

    enum EditorMode {
        case create
        case edit(UUID)
    }

    private let store: ProjectStore
    private let processManager: ProcessManager
    private var restartObserver: NSObjectProtocol?
    private var logThrottleTask: Task<Void, Never>?
    private var pendingLogNotify = false

    init(store: ProjectStore = ProjectStore(), processManager: ProcessManager? = nil) {
        self.store = store
        self.processManager = processManager ?? ProcessManager()

        PathEnvironment.shared.resolve()

        let config = store.load()
        projects = config.projects.sorted { $0.updatedAt > $1.updatedAt }
        if let first = projects.first {
            selectedProjectId = first.id
        }

        self.processManager.onStateChange = { [weak self] in
            self?.handleProcessChange()
        }

        // Register as early as possible so terminate still stops processes
        // even if the menu popover never appeared.
        AppDelegate.stopAll = { [weak self] in
            if Thread.isMainThread {
                self?.processManagerStopAll()
            } else {
                DispatchQueue.main.sync {
                    self?.processManagerStopAll()
                }
            }
        }

        restartObserver = NotificationCenter.default.addObserver(
            forName: .norundeShouldRestartProject,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            Task { @MainActor in
                self?.handleRestartSignal(projectId: id)
            }
        }

        LogWindowController.shared.attach(viewModel: self)

        // App ready → auto-start flagged projects (after PATH resolve).
        AppDelegate.onReady = { [weak self] in
            Task { @MainActor in
                self?.autoStartEligibleProjects()
            }
        }
        // If AppDelegate already fired (rare), still schedule once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.autoStartEligibleProjects()
        }
    }

    deinit {
        if let restartObserver {
            NotificationCenter.default.removeObserver(restartObserver)
        }
    }

    var selectedProject: Project? {
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }
    }

    var runningCount: Int {
        projects.reduce(0) { count, project in
            processManager.runtimeState(for: project.id).status == .running ? count + 1 : count
        }
    }

    func runtimeState(for id: UUID) -> RuntimeState {
        processManager.runtimeState(for: id)
    }

    func logs(for id: UUID) -> [LogLine] {
        _ = logRevision
        return processManager.logBuffer(for: id).snapshot()
    }

    // MARK: - CRUD

    func beginCreate() {
        editorMode = .create
        editorDraft = ProjectDraft()
        bannerError = nil
        presentEditor()
    }

    func beginCreate(directory: URL) {
        editorMode = .create
        var draft = ProjectDraft()
        draft.directory = directory.path
        draft.name = directory.lastPathComponent
        applyPackageJsonHints(to: &draft, directory: directory)
        editorDraft = draft
        bannerError = nil
        presentEditor()
    }

    func beginEdit(_ project: Project) {
        editorMode = .edit(project.id)
        editorDraft = ProjectDraft(project: project)
        bannerError = nil
        presentEditor()
    }

    func cancelEditor() {
        bannerError = nil
        dismissEditor()
    }

    func saveEditor() {
        NSLog("[Norunde] saveEditor tapped")
        bannerError = nil
        let name = editorDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = editorDraft.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = editorDraft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = ProjectDraft.parseEnv(editorDraft.envText)

        guard !name.isEmpty else {
            bannerError = "请填写项目名称"
            return
        }
        guard !directory.isEmpty else {
            bannerError = "请选择项目目录"
            return
        }
        guard !command.isEmpty else {
            bannerError = "请填写启动命令"
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            bannerError = "项目目录不存在：\(directory)"
            return
        }

        let extras = editorDraft.extraCommands
            .map { ProjectCommand(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), command: $0.command.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.name.isEmpty && !$0.command.isEmpty }

        switch editorMode {
        case .create:
            let project = Project(
                name: name,
                directory: directory,
                command: command,
                env: env,
                extraCommands: extras,
                autoStart: editorDraft.autoStart
            )
            projects.insert(project, at: 0)
            selectedProjectId = project.id
        case .edit(let id):
            guard let index = projects.firstIndex(where: { $0.id == id }) else {
                bannerError = "项目不存在"
                return
            }
            var updated = projects[index]
            updated.name = name
            updated.directory = directory
            updated.command = command
            updated.env = env
            updated.extraCommands = extras
            updated.autoStart = editorDraft.autoStart
            updated.updatedAt = Date()
            projects[index] = updated
            selectedProjectId = id
        }

        persist()
        dismissEditor()
        NSLog("[Norunde] saveEditor success name=\(name)")
    }

    /// Open floating editor panel. Do not rely on MenuBarView still being alive.
    private func presentEditor() {
        isEditorPresented = true
        EditorPanelController.shared.show(viewModel: self)
    }

    /// Close floating editor panel. Safe when MenuBarExtra popover is already gone.
    private func dismissEditor() {
        isEditorPresented = false
        EditorPanelController.shared.close()
    }

    func deleteProject(_ project: Project) {
        processManager.dispose(projectId: project.id)
        LogWindowController.shared.close(projectId: project.id)
        projects.removeAll { $0.id == project.id }
        if selectedProjectId == project.id {
            selectedProjectId = projects.first?.id
        }
        persist()
    }

    func selectProject(_ id: UUID) {
        selectAndRefreshExternal(id)
    }

    // MARK: - Process controls

    func start(_ project: Project) {
        // Never block start on external scan (ps/lsof). Fire-and-forget warn.
        refreshExternalProcesses(for: project, announceIfFound: true)
        processManager.start(project: project)
        bumpStatus()
    }

    func stop(_ project: Project) {
        processManager.stop(projectId: project.id)
        bumpStatus()
    }

    func restart(_ project: Project) {
        processManager.restart(project: project)
        bumpStatus()
    }

    func clearLogs(for project: Project) {
        processManager.clearLogs(for: project.id)
        logRevision &+= 1
    }

    /// Scan processes related to the project directory but not managed by Norunde.
    /// Always off main thread. Never leave `isScanningExternal` stuck true.
    func refreshExternalProcesses(for project: Project, announceIfFound: Bool = false) {
        // Allow a new scan even if a previous one is stuck/in-flight.
        isScanningExternal = true
        bumpStatus()
        let directory = project.directory
        let projectId = project.id
        let excluded = processManager.managedPIDs(for: projectId)
        let generation = statusRevision // lightweight stamp for logging only

        Task.detached(priority: .utility) { [weak self] in
            let found = ExternalProcessFinder.find(in: directory, excluding: excluded)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.selectedProjectId == projectId || announceIfFound {
                    self.externalProcesses = found
                }
                self.isScanningExternal = false
                if announceIfFound, !found.isEmpty {
                    let ports = found.flatMap(\.ports).map(String.init).joined(separator: ",")
                    let portHint = ports.isEmpty ? "" : " 端口: \(ports)"
                    self.processManager.logBuffer(for: projectId).appendSystem(
                        "检测到 \(found.count) 个外部相关进程\(portHint)。可点「清理外部进程」后再启动，避免端口顺延。"
                    )
                    self.logRevision &+= 1
                }
                _ = generation
                self.bumpStatus()
            }
        }
    }

    /// Kill external leftovers for the project directory.
    func killExternalProcesses(for project: Project) {
        let directory = project.directory
        let projectId = project.id
        let excluded = processManager.managedPIDs(for: projectId)
        isScanningExternal = true
        processManager.logBuffer(for: projectId).appendSystem("正在扫描并清理外部进程…")
        logRevision &+= 1
        bumpStatus()

        Task.detached(priority: .userInitiated) { [weak self] in
            let found = ExternalProcessFinder.find(in: directory, excluding: excluded)
            let pids = found.map(\.pid)
            if pids.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.externalProcesses = []
                    self.isScanningExternal = false
                    self.processManager.logBuffer(for: projectId).appendSystem("未发现外部相关进程")
                    self.logRevision &+= 1
                    self.bumpStatus()
                }
                return
            }

            let killed = ExternalProcessFinder.terminate(pids: pids)
            try? await Task.sleep(nanoseconds: 400_000_000)
            let remaining = ExternalProcessFinder.find(in: directory, excluding: excluded)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.externalProcesses = remaining
                self.isScanningExternal = false
                self.processManager.logBuffer(for: projectId).appendSystem(
                    "已停止 \(killed.count) 个外部 pid" + (remaining.isEmpty ? "，已清理干净" : "，仍有 \(remaining.count) 个可再清")
                )
                self.logRevision &+= 1
                self.bumpStatus()
            }
        }
    }

    func selectAndRefreshExternal(_ id: UUID) {
        selectedProjectId = id
        if let project = projects.first(where: { $0.id == id }) {
            refreshExternalProcesses(for: project)
        } else {
            externalProcesses = []
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        if let error = LoginItemService.setEnabled(enabled) {
            bannerError = error
            openAtLogin = LoginItemService.isEnabled
            return
        }
        openAtLogin = LoginItemService.isEnabled
        bannerError = nil
    }

    func stopAllAndQuit() {
        LogWindowController.shared.closeAll()
        processManagerStopAll()
        NSApplication.shared.terminate(nil)
    }

    /// Stop every managed process without quitting (used by AppDelegate on terminate).
    func processManagerStopAll() {
        processManager.stopAll()
    }

    func revealInFinder(_ project: Project) {
        let url = URL(fileURLWithPath: project.directory, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    /// Latest detected local URL/port from project logs (Vite/Next etc.).
    func detectedEndpoint(for project: Project) -> PortDetector.Detection? {
        _ = logRevision
        _ = statusRevision
        let lines = processManager.logBuffer(for: project.id).snapshot()
        return PortDetector.detect(fromLogLines: lines)
    }

    func openDetectedURL(for project: Project) {
        guard let detection = detectedEndpoint(for: project) else {
            bannerError = "日志里还没有可打开的地址（等 Vite/Next 打印 Local URL）"
            return
        }
        NSWorkspace.shared.open(detection.url)
    }

    func copyDetectedURL(for project: Project) {
        guard let detection = detectedEndpoint(for: project) else {
            bannerError = "还没有检测到地址可复制"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detection.url.absoluteString, forType: .string)
    }

    func setAutoStart(_ enabled: Bool, for project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].autoStart = enabled
        projects[index].updatedAt = Date()
        persist()
        bumpStatus()
    }

    /// Run a saved extra command as one-shot (does not stop the primary dev process).
    func runExtraCommand(_ command: ProjectCommand, for project: Project) {
        processManager.runOneShot(project: project, title: command.name, command: command.command)
        logRevision &+= 1
        bumpStatus()
    }

    /// Promote an extra command to the primary long-running command.
    func setPrimaryCommand(_ command: ProjectCommand, for project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].command = command.command
        projects[index].updatedAt = Date()
        persist()
        processManager.logBuffer(for: project.id).appendSystem("主命令已切换为：\(command.command)")
        logRevision &+= 1
        bumpStatus()
    }

    func openLogWindow(for project: Project) {
        LogWindowController.shared.attach(viewModel: self)
        LogWindowController.shared.show(projectId: project.id)
    }

    func applyPackageJsonToDraft() {
        let path = editorDraft.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            bannerError = "请先选择目录"
            return
        }
        applyPackageJsonHints(to: &editorDraft, directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: - Private

    private func persist() {
        do {
            try store.save(AppConfig(version: AppConfig.currentVersion, projects: projects))
        } catch {
            bannerError = error.localizedDescription
            NSLog("[Norunde] save failed: \(error)")
        }
    }

    private func applyPackageJsonHints(to draft: inout ProjectDraft, directory: URL) {
        // Display name always prefers the folder name on disk.
        // package.json "name" is often a monorepo package id (e.g. jeecgboot-vue3).
        let folderName = directory.lastPathComponent
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.name = folderName
        }

        switch PackageJsonParser.parse(directory: directory) {
        case .success(let info):
            // If name was previously set from package.json, migrate to folder name.
            if let pkgName = info.projectName,
               !pkgName.isEmpty,
               draft.name == pkgName,
               pkgName != folderName {
                draft.name = folderName
            }
            if let suggested = info.suggestedCommand {
                draft.command = suggested
            }
            draft.detectedScripts = info.scripts
            draft.detectedPackageManager = info.packageManager
            // Seed extra commands from package.json scripts (skip the current primary).
            if draft.extraCommands.isEmpty {
                let pm = info.packageManager
                let primaryScript = info.defaultScript
                draft.extraCommands = info.scripts
                    .filter { $0 != primaryScript }
                    .prefix(12)
                    .map { ProjectCommand(name: $0, command: "\(pm) run \($0)") }
            }
            bannerError = nil
        case .failure(let error):
            draft.detectedScripts = []
            draft.detectedPackageManager = nil
            // Non-blocking: allow manual command
            if draft.command.isEmpty {
                bannerError = error.localizedDescription + "（可手动填写命令）"
            }
        }
    }

    private func handleProcessChange() {
        bumpStatus()
        // Throttle log UI refresh ~10Hz
        pendingLogNotify = true
        if logThrottleTask == nil {
            logThrottleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                logThrottleTask = nil
                if pendingLogNotify {
                    pendingLogNotify = false
                    logRevision &+= 1
                }
            }
        }
    }

    private func bumpStatus() {
        statusRevision &+= 1
    }

    private func handleRestartSignal(projectId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        processManager.start(project: project)
        bumpStatus()
    }

    private var didAutoStart = false

    /// Start projects with autoStart=true once per app launch.
    private func autoStartEligibleProjects() {
        guard !didAutoStart else { return }
        let targets = projects.filter(\.autoStart)
        guard !targets.isEmpty else {
            didAutoStart = true
            return
        }
        didAutoStart = true
        for (offset, project) in targets.enumerated() {
            // Stagger slightly so PATH/logs stay readable.
            let delay = 0.35 * Double(offset)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let status = self.processManager.runtimeState(for: project.id).status
                guard status == .stopped || status == .failed else { return }
                self.processManager.logBuffer(for: project.id).appendSystem("自动启动（autoStart）")
                self.processManager.start(project: project)
                self.bumpStatus()
            }
        }
    }
}

struct ProjectDraft: Equatable {
    var name: String = ""
    var directory: String = ""
    var command: String = ""
    var envText: String = ""
    var autoStart: Bool = false
    var extraCommands: [ProjectCommand] = []
    var detectedScripts: [String] = []
    var detectedPackageManager: String?

    init() {}

    init(project: Project) {
        name = project.name
        directory = project.directory
        command = project.command
        autoStart = project.autoStart
        extraCommands = project.extraCommands
        envText = project.env
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    static func parseEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
}
