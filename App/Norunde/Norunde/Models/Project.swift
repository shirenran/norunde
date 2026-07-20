import Foundation

struct ProjectCommand: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

struct Project: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var directory: String
    /// Primary long-running command (dev server).
    var command: String
    var env: [String: String]
    /// Extra named commands (build / test / lint …), run as one-shot or set as primary.
    var extraCommands: [ProjectCommand]
    /// When true, Norunde starts this project shortly after the app launches.
    var autoStart: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        directory: String,
        command: String,
        env: [String: String] = [:],
        extraCommands: [ProjectCommand] = [],
        autoStart: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.command = command
        self.env = env
        self.extraCommands = extraCommands
        self.autoStart = autoStart
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, directory, command, env, extraCommands, autoStart, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(String.self, forKey: .directory)
        command = try c.decode(String.self, forKey: .command)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        extraCommands = try c.decodeIfPresent([ProjectCommand].self, forKey: .extraCommands) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(directory, forKey: .directory)
        try c.encode(command, forKey: .command)
        try c.encode(env, forKey: .env)
        try c.encode(extraCommands, forKey: .extraCommands)
        try c.encode(autoStart, forKey: .autoStart)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
