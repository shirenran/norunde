import Foundation

enum ProjectStoreError: LocalizedError {
    case cannotCreateDirectory(URL, Error)
    case writeFailed(Error)
    case readFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let url, let error):
            return "无法创建配置目录 \(url.path)：\(error.localizedDescription)"
        case .writeFailed(let error):
            return "写入配置失败：\(error.localizedDescription)"
        case .readFailed(let error):
            return "读取配置失败：\(error.localizedDescription)"
        }
    }
}

/// JSON persistence for project configuration.
/// Path: ~/Library/Application Support/Norunde/projects.json
final class ProjectStore {
    let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = support.appendingPathComponent("Norunde", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("projects.json")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> AppConfig {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let config = try decoder.decode(AppConfig.self, from: data)
            return config
        } catch {
            // Corrupt file → empty list (MVP fallback)
            NSLog("[Norunde] ProjectStore load failed, using empty config: \(error)")
            return .empty
        }
    }

    @discardableResult
    func save(_ config: AppConfig) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.cannotCreateDirectory(directory, error)
        }

        var payload = config
        if payload.version == 0 {
            payload.version = AppConfig.currentVersion
        }

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw ProjectStoreError.writeFailed(error)
        }

        let tempURL = directory.appendingPathComponent("projects.json.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ProjectStoreError.writeFailed(error)
        }
        return fileURL
    }
}
