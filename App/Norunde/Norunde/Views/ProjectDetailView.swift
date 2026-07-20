import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        let _ = viewModel.statusRevision
        let _ = viewModel.logRevision
        if let project = viewModel.selectedProject {
            VStack(alignment: .leading, spacing: 12) {
                header(project)
                meta(project)
                endpointBar(project)
                controls(project)
                externalBanner(project)
                LogView(projectId: project.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(14)
            .onAppear {
                viewModel.refreshExternalProcesses(for: project)
            }
            .onChange(of: project.id) { _, _ in
                viewModel.refreshExternalProcesses(for: project)
            }
        }
    }

    private func header(_ project: Project) -> some View {
        let state = viewModel.runtimeState(for: project.id)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if project.autoStart {
                        Text("自动启动")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
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
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func meta(_ project: Project) -> some View {
        let state = viewModel.runtimeState(for: project.id)
        return VStack(alignment: .leading, spacing: 6) {
            labeled("目录", project.directory)
            labeled("命令", project.command)
            if let error = state.lastError, state.status == .failed {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
        }
    }

    @ViewBuilder
    private func endpointBar(_ project: Project) -> some View {
        let detection = viewModel.detectedEndpoint(for: project)
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            if let detection {
                Text(detection.url.absoluteString)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("打开") {
                    viewModel.openDetectedURL(for: project)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                Button("复制") {
                    viewModel.copyDetectedURL(for: project)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else {
                Text(viewModel.runtimeState(for: project.id).status == .running
                      ? "运行中，等待日志出现 Local URL…"
                      : "启动后自动识别端口 / 地址")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("打开") {
                    viewModel.openDetectedURL(for: project)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func controls(_ project: Project) -> some View {
        let status = viewModel.runtimeState(for: project.id).status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    viewModel.start(project)
                } label: {
                    Label("启动", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(status == .running || status == .starting || status == .stopping)

                Button {
                    viewModel.stop(project)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(status == .stopped || status == .stopping)

                Button {
                    viewModel.restart(project)
                } label: {
                    Label("重启", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(status == .starting || status == .stopping)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.refreshExternalProcesses(for: project)
                } label: {
                    Label(
                        viewModel.isScanningExternal ? "扫描中…" : "扫描外部",
                        systemImage: "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isScanningExternal)

                Button {
                    viewModel.killExternalProcesses(for: project)
                } label: {
                    Label("清理外部", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.externalProcesses.isEmpty && !viewModel.isScanningExternal)
                .help("结束终端等非 Norunde 启动的同项目进程，释放端口")
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.beginEdit(project)
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    viewModel.revealInFinder(project)
                } label: {
                    Label("Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    viewModel.openLogWindow(for: project)
                } label: {
                    Label("大日志", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    viewModel.deleteProject(project)
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }

            if !project.extraCommands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷命令（一次性，不打断主进程）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    FlowCommandBar(commands: project.extraCommands) { cmd in
                        viewModel.runExtraCommand(cmd, for: project)
                    } onSetPrimary: { cmd in
                        viewModel.setPrimaryCommand(cmd, for: project)
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { project.autoStart },
                set: { viewModel.setAutoStart($0, for: project) }
            )) {
                Text("App 启动时自动运行此项目")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func externalBanner(_ project: Project) -> some View {
        if viewModel.isScanningExternal {
            Text("正在扫描外部进程…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !viewModel.externalProcesses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("发现 \(viewModel.externalProcesses.count) 个外部相关进程（非本 App 管理）")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                ForEach(viewModel.externalProcesses.prefix(4)) { proc in
                    let portText = proc.ports.isEmpty
                        ? ""
                        : " :" + proc.ports.map(String.init).joined(separator: ",")
                    Text("· pid \(proc.pid)\(portText)  \(proc.command)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(proc.command)
                }
                if viewModel.externalProcesses.count > 4 {
                    Text("…还有 \(viewModel.externalProcesses.count - 4) 个")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Horizontal wrapping-ish command chips using a simple multi-row HStack layout.
private struct FlowCommandBar: View {
    let commands: [ProjectCommand]
    var onRun: (ProjectCommand) -> Void
    var onSetPrimary: (ProjectCommand) -> Void

    var body: some View {
        // Keep simple: horizontal scroll — reliable in narrow menu bar pane.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { cmd in
                    Menu {
                        Button("运行一次") { onRun(cmd) }
                        Button("设为主启动命令") { onSetPrimary(cmd) }
                    } label: {
                        Text(cmd.name)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help(cmd.command)
                }
            }
        }
    }
}
