import SwiftUI

struct StatusBadgeView: View {
    let status: ProjectStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .help(status.displayName)
    }

    private var color: Color {
        switch status {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .stopping: return .orange
        case .failed: return .red
        }
    }
}
