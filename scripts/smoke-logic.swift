#!/usr/bin/env swift
// Standalone smoke tests for pure logic (no XCTest host / full Xcode required).
// Usage: swift scripts/smoke-logic.swift

import Foundation

// MARK: - Minimal copies of production logic under test
// Keep in sync with App/Norunde services; this avoids module linking under CLT-only.

enum ShellQuote {
    static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if !value.contains("'") { return "'\(value)'" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PackageJsonInfo {
    var packageManager: String
    var scripts: [String]
    var defaultScript: String?
    var suggestedCommand: String?
    var projectName: String?
}

enum PackageJsonParser {
    private static let preferredScripts = ["dev", "start", "serve"]

    enum ParseError: Error { case fileNotFound, invalidJSON }

    static func parse(directory: URL) -> Result<PackageJsonInfo, ParseError> {
        let packageURL = directory.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return .failure(.fileNotFound)
        }
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        let projectName = json["name"] as? String
        let scriptsDict = json["scripts"] as? [String: Any] ?? [:]
        let scripts = scriptsDict.keys.sorted()
        let pm = detectPackageManager(in: directory)
        let defaultScript = pickDefaultScript(from: scripts)
        let suggested = defaultScript.map { "\(pm) run \($0)" }
        return .success(PackageJsonInfo(
            packageManager: pm,
            scripts: scripts,
            defaultScript: defaultScript,
            suggestedCommand: suggested,
            projectName: projectName
        ))
    }

    static func detectPackageManager(in directory: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if fm.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("bun.lock").path) { return "bun" }
        if fm.fileExists(atPath: directory.appendingPathComponent("package-lock.json").path) { return "npm" }
        return "npm"
    }

    static func pickDefaultScript(from scripts: [String]) -> String? {
        for preferred in preferredScripts where scripts.contains(preferred) { return preferred }
        return scripts.sorted().first
    }
}

struct ProjectCommand: Codable, Equatable {
    var id: UUID
    var name: String
    var command: String
    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id; self.name = name; self.command = command
    }
}

struct Project: Codable, Equatable {
    var id: UUID
    var name: String
    var directory: String
    var command: String
    var env: [String: String]
    var extraCommands: [ProjectCommand]
    var autoStart: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, directory, command, env, extraCommands, autoStart, createdAt, updatedAt
    }

    init(id: UUID = UUID(), name: String, directory: String, command: String, env: [String: String] = [:], extraCommands: [ProjectCommand] = [], autoStart: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.directory = directory; self.command = command
        self.env = env; self.extraCommands = extraCommands; self.autoStart = autoStart
        self.createdAt = createdAt; self.updatedAt = updatedAt
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
}

enum PortDetector {
    struct Detection: Equatable {
        var url: URL
        var port: Int?
        var host: String
    }

    static func detect(from lines: [String]) -> Detection? {
        var best: (score: Int, detection: Detection)?
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in lines {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let url = match?.url, let host = url.host?.lowercased() else { return }
                let scheme = (url.scheme ?? "http").lowercased()
                guard scheme == "http" || scheme == "https" else { return }
                var score = 10
                if host == "localhost" || host == "127.0.0.1" { score += 100 }
                else if host == "0.0.0.0" { score += 80 }
                let port = url.port
                var open = url
                if host == "0.0.0.0", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    c.host = "localhost"
                    if let r = c.url { open = r }
                }
                let d = Detection(url: open, port: port, host: open.host ?? host)
                if best == nil || score >= best!.score { best = (score, d) }
            }
        }
        return best?.detection
    }
}

struct AppConfig: Codable, Equatable {
    var version: Int
    var projects: [Project]
    static let currentVersion = 1
    static var empty: AppConfig { AppConfig(version: currentVersion, projects: []) }
}

final class ProjectStore {
    let fileURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() -> AppConfig {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            return .empty
        }
    }

    func save(_ config: AppConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        let tempURL = directory.appendingPathComponent("projects.json.tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
        }
    }
}

final class LogBuffer {
    private var lines: [String] = []
    private let capacity: Int
    init(capacity: Int = 2000) { self.capacity = capacity }
    func append(_ text: String) {
        lines.append(text)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
    var count: Int { lines.count }
    func clear() { lines.removeAll() }
}

func parseEnv(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: eq)...])
        if !key.isEmpty { result[key] = value }
    }
    return result
}

// MARK: - Runner

var failures = 0
func expect(_ cond: @autoclosure () -> Bool, _ message: String) {
    if cond() {
        print("  OK  \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

print("== ShellQuote ==")
expect(ShellQuote.quote("hello") == "'hello'", "simple quote")
expect(ShellQuote.quote("a'b") == "'a'\\''b'", "embedded single quote")
expect(ShellQuote.quote("") == "''", "empty")

print("== PackageJsonParser ==")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("norunde-smoke-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let pkg: [String: Any] = [
    "name": "demo-app",
    "scripts": ["build": "vite build", "dev": "vite", "start": "node s.js"]
]
try! JSONSerialization.data(withJSONObject: pkg).write(to: tmp.appendingPathComponent("package.json"))
try! "lockfileVersion: '9.0'\n".write(to: tmp.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)

switch PackageJsonParser.parse(directory: tmp) {
case .success(let info):
    expect(info.packageManager == "pnpm", "pnpm lock")
    expect(info.defaultScript == "dev", "prefer dev")
    expect(info.suggestedCommand == "pnpm run dev", "suggested command")
    expect(info.projectName == "demo-app", "project name")
case .failure(let err):
    expect(false, "parse failed: \(err)")
}

let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent("norunde-smoke2-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp2, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp2) }
try! JSONSerialization.data(withJSONObject: ["scripts": ["serve": "x", "lint": "y"]]).write(to: tmp2.appendingPathComponent("package.json"))
try! "# yarn\n".write(to: tmp2.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
if case .success(let info) = PackageJsonParser.parse(directory: tmp2) {
    expect(info.packageManager == "yarn", "yarn lock")
    expect(info.defaultScript == "serve", "prefer serve over lint")
} else {
    expect(false, "yarn parse")
}

print("== ProjectStore ==")
let storeURL = tmp.appendingPathComponent("projects.json")
let store = ProjectStore(fileURL: storeURL)
expect(store.load().projects.isEmpty, "missing file empty")
let project = Project(
    id: UUID(),
    name: "admin-web",
    directory: "/tmp/admin-web",
    command: "pnpm run dev",
    env: ["PORT": "3001"],
    autoStart: true,
    createdAt: Date(),
    updatedAt: Date()
)
try! store.save(AppConfig(version: 1, projects: [project]))
let loaded = store.load()
expect(loaded.projects.count == 1, "roundtrip count")
expect(loaded.projects.first?.name == "admin-web", "roundtrip name")
expect(loaded.projects.first?.env["PORT"] == "3001", "roundtrip env")
expect(loaded.projects.first?.autoStart == true, "roundtrip autoStart")
// legacy JSON without autoStart
let legacy = """
{"version":1,"projects":[{"id":"\(UUID().uuidString)","name":"old","directory":"/tmp/old","command":"npm run dev","env":{},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]}
"""
try! legacy.write(to: storeURL, atomically: true, encoding: .utf8)
let legacyLoaded = store.load()
expect(legacyLoaded.projects.first?.autoStart == false, "legacy autoStart default false")
try! "{ bad".write(to: storeURL, atomically: true, encoding: .utf8)
expect(store.load().projects.isEmpty, "corrupt fallback")

print("== PortDetector ==")
let det = PortDetector.detect(from: [
    "ready in 300ms",
    "  ➜  Local:   http://localhost:3100/",
    "  ➜  Network: http://192.168.1.2:3100/"
])
expect(det?.host == "localhost", "prefer localhost")
expect(det?.port == 3100, "port 3100")
let detZero = PortDetector.detect(from: ["Local: http://0.0.0.0:5173/"])
expect(detZero?.host == "localhost", "rewrite 0.0.0.0")
expect(detZero?.port == 5173, "port 5173")

print("== LogBuffer ring ==")
let buf = LogBuffer(capacity: 3)
buf.append("a"); buf.append("b"); buf.append("c"); buf.append("d")
expect(buf.count == 3, "capacity enforced")
buf.clear()
expect(buf.count == 0, "clear")

print("== env parse ==")
let env = parseEnv("PORT=3001\n# c\nNODE_ENV=dev\nbad\nEMPTY=\n")
expect(env["PORT"] == "3001", "PORT")
expect(env["NODE_ENV"] == "dev", "NODE_ENV")
expect(env["EMPTY"] == "", "EMPTY")
expect(env["bad"] == nil, "invalid line ignored")

if failures == 0 {
    print("\nAll smoke tests passed.")
    exit(0)
} else {
    print("\n\(failures) failure(s).")
    exit(1)
}
