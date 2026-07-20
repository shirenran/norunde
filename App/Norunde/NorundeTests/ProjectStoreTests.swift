import XCTest
@testable import Norunde

final class ProjectStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("norunde-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("projects.json")
        store = ProjectStore(fileURL: storeURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadEmptyWhenMissing() {
        let config = store.load()
        XCTAssertEqual(config.projects.count, 0)
        XCTAssertEqual(config.version, AppConfig.currentVersion)
    }

    func testSaveAndLoadRoundTrip() throws {
        let project = Project(
            name: "admin-web",
            directory: "/tmp/admin-web",
            command: "pnpm run dev",
            env: ["PORT": "3001"]
        )
        let config = AppConfig(version: 1, projects: [project])
        try store.save(config)

        let loaded = store.load()
        XCTAssertEqual(loaded.projects.count, 1)
        XCTAssertEqual(loaded.projects[0].name, "admin-web")
        XCTAssertEqual(loaded.projects[0].directory, "/tmp/admin-web")
        XCTAssertEqual(loaded.projects[0].command, "pnpm run dev")
        XCTAssertEqual(loaded.projects[0].env["PORT"], "3001")
        XCTAssertEqual(loaded.projects[0].id, project.id)
    }

    func testCorruptFileFallsBackToEmpty() throws {
        try "{ not-valid-json".write(to: storeURL, atomically: true, encoding: .utf8)
        let config = store.load()
        XCTAssertTrue(config.projects.isEmpty)
    }

    func testProjectDraftEnvParsing() {
        let text = """
        PORT=3001
        # comment
        NODE_ENV=development
        INVALID_LINE
        EMPTY=
        """
        let env = ProjectDraft.parseEnv(text)
        XCTAssertEqual(env["PORT"], "3001")
        XCTAssertEqual(env["NODE_ENV"], "development")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertNil(env["INVALID_LINE"])
    }

    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("hello"), "'hello'")
        XCTAssertEqual(ShellQuote.quote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }
}
