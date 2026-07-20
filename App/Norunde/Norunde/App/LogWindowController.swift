import AppKit
import SwiftUI

/// Detached large log window for a project. Shares the same ViewModel/logs as the menu bar.
@MainActor
final class LogWindowController: NSObject, NSWindowDelegate {
    static let shared = LogWindowController()

    private var windows: [UUID: NSWindow] = [:]
    private weak var viewModel: AppViewModel?

    private override init() {
        super.init()
    }

    func attach(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func show(projectId: UUID) {
        guard let viewModel else { return }

        if let existing = windows[projectId] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let projectName = viewModel.projects.first(where: { $0.id == projectId })?.name ?? "日志"
        let root = LogWindowView(projectId: projectId)
            .environmentObject(viewModel)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Norunde · \(projectName)"
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[projectId] = window
    }

    func close(projectId: UUID) {
        if let window = windows[projectId] {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeValue(forKey: projectId)
    }

    func closeAll() {
        for id in Array(windows.keys) {
            close(projectId: id)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let id = windows.first(where: { $0.value === window })?.key {
            windows.removeValue(forKey: id)
        }
    }
}

struct LogWindowView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let projectId: UUID

    var body: some View {
        let _ = viewModel.statusRevision
        let _ = viewModel.logRevision
        let project = viewModel.projects.first(where: { $0.id == projectId })
        let state = viewModel.runtimeState(for: projectId)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project?.name ?? "项目日志")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        StatusBadgeView(status: state.status)
                        Text(state.status.displayName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let pid = state.pid {
                            Text("pid \(pid)")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        if let detection = project.flatMap({ viewModel.detectedEndpoint(for: $0) }) {
                            Text(detection.url.absoluteString)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                }
                Spacer()
                if let project {
                    Button("打开地址") { viewModel.openDetectedURL(for: project) }
                        .disabled(viewModel.detectedEndpoint(for: project) == nil)
                    Button("启动") { viewModel.start(project) }
                        .disabled(state.status == .running || state.status == .starting || state.status == .stopping)
                    Button("停止") { viewModel.stop(project) }
                        .disabled(state.status == .stopped || state.status == .stopping)
                    Button("重启") { viewModel.restart(project) }
                        .disabled(state.status == .starting || state.status == .stopping)
                }
            }
            .buttonStyle(.bordered)

            if let project, !project.extraCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("命令")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(project.extraCommands) { cmd in
                            Button(cmd.name) {
                                viewModel.runExtraCommand(cmd, for: project)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                }
            }

            LogView(projectId: projectId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }
}
