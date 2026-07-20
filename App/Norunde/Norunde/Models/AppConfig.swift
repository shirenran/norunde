import Foundation

struct AppConfig: Codable, Equatable {
    var version: Int
    var projects: [Project]

    static let currentVersion = 1

    static var empty: AppConfig {
        AppConfig(version: currentVersion, projects: [])
    }
}
