import Foundation

enum ProjectStatus: String, Codable, Equatable, CaseIterable {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var displayName: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .stopping: return "停止中"
        case .failed: return "失败"
        }
    }
}

struct RuntimeState: Equatable {
    var status: ProjectStatus
    var pid: Int32?
    var lastError: String?
    var startedAt: Date?

    static let stopped = RuntimeState(status: .stopped, pid: nil, lastError: nil, startedAt: nil)
}
