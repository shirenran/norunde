import XCTest
@testable import Norunde

final class PackageJsonParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("norunde-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParseScriptsAndPreferDev() throws {
        try writePackageJSON([
            "name": "demo-app",
            "scripts": [
                "build": "vite build",
                "dev": "vite",
                "start": "node server.js"
            ]
        ])
        try writeFile("pnpm-lock.yaml", contents: "lockfileVersion: '9.0'\n")

        let result = PackageJsonParser.parse(directory: tempDir)
        switch result {
        case .success(let info):
            XCTAssertEqual(info.packageManager, "pnpm")
            XCTAssertEqual(info.defaultScript, "dev")
            XCTAssertEqual(info.suggestedCommand, "pnpm run dev")
            XCTAssertEqual(info.projectName, "demo-app")
            XCTAssertTrue(info.scripts.contains("dev"))
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    func testFallbackToStartWhenNoDev() throws {
        try writePackageJSON([
            "scripts": [
                "start": "node index.js",
                "lint": "eslint ."
            ]
        ])
        try writeFile("package-lock.json", contents: "{}\n")

        let result = PackageJsonParser.parse(directory: tempDir)
        let info = try XCTUnwrap(result.get())
        XCTAssertEqual(info.packageManager, "npm")
        XCTAssertEqual(info.defaultScript, "start")
        XCTAssertEqual(info.suggestedCommand, "npm run start")
    }

    func testYarnLockDetection() throws {
        try writePackageJSON(["scripts": ["serve": "vue-cli-service serve"]])
        try writeFile("yarn.lock", contents: "# yarn lockfile v1\n")

        let info = try XCTUnwrap(PackageJsonParser.parse(directory: tempDir).get())
        XCTAssertEqual(info.packageManager, "yarn")
        XCTAssertEqual(info.defaultScript, "serve")
        XCTAssertEqual(info.suggestedCommand, "yarn run serve")
    }

    func testBunLockDetection() throws {
        try writePackageJSON(["scripts": ["alpha": "echo a", "beta": "echo b"]])
        try writeFile("bun.lock", contents: "{}\n")

        let info = try XCTUnwrap(PackageJsonParser.parse(directory: tempDir).get())
        XCTAssertEqual(info.packageManager, "bun")
        // no preferred scripts → alphabetical first
        XCTAssertEqual(info.defaultScript, "alpha")
    }

    func testMissingPackageJson() {
        let result = PackageJsonParser.parse(directory: tempDir)
        if case .failure(.fileNotFound) = result {
            // ok
        } else {
            XCTFail("expected fileNotFound")
        }
    }

    func testInvalidJSON() throws {
        try writeFile("package.json", contents: "{ not json")
        let result = PackageJsonParser.parse(directory: tempDir)
        if case .failure(.invalidJSON) = result {
            // ok
        } else {
            XCTFail("expected invalidJSON")
        }
    }

    // MARK: - Helpers

    private func writePackageJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: tempDir.appendingPathComponent("package.json"))
    }

    private func writeFile(_ name: String, contents: String) throws {
        try contents.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

private extension Result {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
