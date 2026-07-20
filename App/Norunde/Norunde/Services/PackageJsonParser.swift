import Foundation

struct PackageJsonInfo: Equatable {
    var packageManager: String
    var scripts: [String]
    var defaultScript: String?
    var suggestedCommand: String?
    var projectName: String?
}

enum PackageJsonParserError: LocalizedError {
    case fileNotFound(URL)
    case invalidJSON(Error)
    case missingScripts

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "未找到 package.json：\(url.path)"
        case .invalidJSON(let error):
            return "package.json 解析失败：\(error.localizedDescription)"
        case .missingScripts:
            return "package.json 中没有 scripts"
        }
    }
}

enum PackageJsonParser {
    private static let preferredScripts = ["dev", "start", "serve"]

    /// Parse package.json + infer package manager from lockfiles.
    static func parse(directory: URL) -> Result<PackageJsonInfo, PackageJsonParserError> {
        let packageURL = directory.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return .failure(.fileNotFound(packageURL))
        }

        let data: Data
        do {
            data = try Data(contentsOf: packageURL)
        } catch {
            return .failure(.invalidJSON(error))
        }

        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.invalidJSON(NSError(domain: "PackageJsonParser", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "根节点不是对象"
                ])))
            }
            json = object
        } catch {
            return .failure(.invalidJSON(error))
        }

        let projectName = json["name"] as? String
        let scriptsDict = json["scripts"] as? [String: Any] ?? [:]
        let scripts = scriptsDict.keys.sorted()

        let pm = detectPackageManager(in: directory)
        let defaultScript = pickDefaultScript(from: scripts)
        let suggested: String?
        if let defaultScript {
            suggested = "\(pm) run \(defaultScript)"
        } else {
            suggested = nil
        }

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
        if fm.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("bun.lock").path) {
            return "bun"
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("package-lock.json").path) {
            return "npm"
        }
        return "npm"
    }

    static func pickDefaultScript(from scripts: [String]) -> String? {
        for preferred in preferredScripts {
            if scripts.contains(preferred) {
                return preferred
            }
        }
        return scripts.sorted().first
    }
}
