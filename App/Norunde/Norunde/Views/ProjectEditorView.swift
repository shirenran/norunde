import AppKit
import SwiftUI

struct ProjectEditorView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title3.weight(.semibold))

                formField(label: "名称") {
                    TextField("项目名称", text: $viewModel.editorDraft.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }

                formField(label: "目录") {
                    HStack(spacing: 10) {
                        TextField("/path/to/project", text: $viewModel.editorDraft.directory)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                        Button("选择…") { pickDirectory() }
                            .controlSize(.regular)
                        Button("识别 scripts") { viewModel.applyPackageJsonToDraft() }
                            .controlSize(.regular)
                    }
                }

                if let pm = viewModel.editorDraft.detectedPackageManager {
                    Text("包管理器：\(pm)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.editorDraft.detectedScripts.isEmpty {
                    formField(label: "设为主启动脚本") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.editorDraft.detectedScripts, id: \.self) { script in
                                    Button(script) {
                                        let pm = viewModel.editorDraft.detectedPackageManager ?? "npm"
                                        viewModel.editorDraft.command = "\(pm) run \(script)"
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }
                        }
                    }
                }

                formField(label: "主启动命令（长驻）") {
                    TextField("pnpm run dev", text: $viewModel.editorDraft.command)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }

                formField(label: "快捷命令（build / test 等，可一次运行）") {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.editorDraft.extraCommands.isEmpty {
                            Text("点「从 scripts 填充」或「添加」")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(viewModel.editorDraft.extraCommands.enumerated()), id: \.element.id) { index, _ in
                            HStack(spacing: 8) {
                                TextField("名称", text: bindingName(at: index))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                TextField("命令", text: bindingCommand(at: index))
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    viewModel.editorDraft.command = viewModel.editorDraft.extraCommands[index].command
                                } label: {
                                    Image(systemName: "star")
                                }
                                .help("设为主启动命令")
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    viewModel.editorDraft.extraCommands.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        HStack(spacing: 10) {
                            Button("添加") {
                                viewModel.editorDraft.extraCommands.append(
                                    ProjectCommand(name: "build", command: "pnpm run build")
                                )
                            }
                            Button("从 scripts 填充") {
                                fillExtrasFromScripts()
                            }
                            .disabled(viewModel.editorDraft.detectedScripts.isEmpty)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }

                formField(label: "环境变量") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每行 KEY=VALUE，可选")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.editorDraft.envText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80, maxHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                }

                Toggle(isOn: $viewModel.editorDraft.autoStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App 启动时自动运行")
                            .font(.body)
                        Text("Norunde 打开后自动执行主启动命令")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if let error = viewModel.bannerError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Spacer()
                    Button("取消") {
                        viewModel.cancelEditor()
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                    Button("保存") {
                        viewModel.saveEditor()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 640)
    }

    private var title: String {
        switch viewModel.editorMode {
        case .create: return "导入项目"
        case .edit: return "编辑项目"
        }
    }

    private func formField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func bindingName(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard viewModel.editorDraft.extraCommands.indices.contains(index) else { return "" }
                return viewModel.editorDraft.extraCommands[index].name
            },
            set: { newValue in
                guard viewModel.editorDraft.extraCommands.indices.contains(index) else { return }
                viewModel.editorDraft.extraCommands[index].name = newValue
            }
        )
    }

    private func bindingCommand(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard viewModel.editorDraft.extraCommands.indices.contains(index) else { return "" }
                return viewModel.editorDraft.extraCommands[index].command
            },
            set: { newValue in
                guard viewModel.editorDraft.extraCommands.indices.contains(index) else { return }
                viewModel.editorDraft.extraCommands[index].command = newValue
            }
        )
    }

    private func fillExtrasFromScripts() {
        let pm = viewModel.editorDraft.detectedPackageManager ?? "npm"
        let primary = viewModel.editorDraft.command
        let existing = Set(viewModel.editorDraft.extraCommands.map(\.command))
        for script in viewModel.editorDraft.detectedScripts {
            let cmd = "\(pm) run \(script)"
            if cmd == primary || existing.contains(cmd) { continue }
            viewModel.editorDraft.extraCommands.append(ProjectCommand(name: script, command: cmd))
        }
    }

    private func pickDirectory() {
        let start: URL? = viewModel.editorDraft.directory.isEmpty
            ? nil
            : URL(fileURLWithPath: viewModel.editorDraft.directory, isDirectory: true)
        DirectoryPicker.pickDirectory(
            startingAt: start,
            parentWindow: EditorPanelController.shared.hostWindow
        ) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                viewModel.editorDraft.directory = url.path
                if viewModel.editorDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.editorDraft.name = url.lastPathComponent
                }
                viewModel.applyPackageJsonToDraft()
            }
        }
    }
}
