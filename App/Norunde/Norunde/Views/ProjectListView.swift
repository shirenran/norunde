import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        // Observe status for badge refresh
        let _ = viewModel.statusRevision
        List(selection: Binding(
            get: { viewModel.selectedProjectId },
            set: { if let id = $0 { viewModel.selectProject(id) } }
        )) {
            if viewModel.projects.isEmpty {
                Text("暂无项目")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(viewModel.projects) { project in
                    ProjectRowView(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("启动") { viewModel.start(project) }
                            Button("停止") { viewModel.stop(project) }
                            Button("重启") { viewModel.restart(project) }
                            Divider()
                            Button("编辑") { viewModel.beginEdit(project) }
                            Button("在 Finder 中显示") { viewModel.revealInFinder(project) }
                            Divider()
                            Button("删除", role: .destructive) { viewModel.deleteProject(project) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ProjectRowView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let project: Project

    var body: some View {
        let state = viewModel.runtimeState(for: project.id)
        HStack(spacing: 10) {
            StatusBadgeView(status: state.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(state.status.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
