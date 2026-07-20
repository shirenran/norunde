import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 720)
        .onChange(of: viewModel.isEditorPresented) { _, presented in
            if presented {
                EditorPanelController.shared.show(viewModel: viewModel)
            } else {
                EditorPanelController.shared.close()
            }
        }
        .onAppear {
            if viewModel.isEditorPresented {
                EditorPanelController.shared.show(viewModel: viewModel)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Norunde")
                .font(.title3.weight(.semibold))
            if viewModel.runningCount > 0 {
                Text("\(viewModel.runningCount) 运行中")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                importProject()
            } label: {
                Label("导入", systemImage: "plus")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("导入项目")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        HStack(spacing: 0) {
            ProjectListView()
                .frame(width: 180)
            Divider()
            if viewModel.selectedProject != nil {
                ProjectDetailView()
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("点击「导入」添加前端项目")
                        .foregroundStyle(.secondary)
                        .font(.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("开机自启", isOn: Binding(
                get: { viewModel.openAtLogin },
                set: { viewModel.setOpenAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.callout)
            .help("登录 macOS 后自动启动 Norunde（菜单栏常驻）")

            if let error = viewModel.bannerError, !viewModel.isEditorPresented {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("退出") {
                viewModel.stopAllAndQuit()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Open floating editor first, then present folder picker as a sheet on it.
    /// Avoids NSOpenPanel being buried under MenuBarExtra content (and never kills the status icon).
    private func importProject() {
        // Only hide the big content panel; status item icon stays.
        DirectoryPicker.dismissMenuBarContentWindows()
        viewModel.beginCreate() // shows floating editor immediately

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            DirectoryPicker.pickDirectory(
                parentWindow: EditorPanelController.shared.hostWindow
            ) { url in
                guard let url else { return }
                DispatchQueue.main.async {
                    viewModel.editorDraft.directory = url.path
                    if viewModel.editorDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        viewModel.editorDraft.name = url.lastPathComponent
                    }
                    viewModel.applyPackageJsonToDraft()
                    EditorPanelController.shared.show(viewModel: viewModel)
                }
            }
        }
    }
}
