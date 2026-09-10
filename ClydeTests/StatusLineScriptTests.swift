import XCTest
@testable import Clyde

/// Drives the bundled `clyde-statusline.sh` as a real subprocess with a
/// sandboxed `$HOME`, the way `HookScriptTests` drives the hook. The
/// script is the producer half of the feature; `UsageLimitsStore` is
/// the consumer.
final class StatusLineScriptTests: XCTestCase {

    private static let scriptURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Clyde/Resources/clyde-statusline.sh")
    }()

    private func tempHome() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-statusline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let payload = """
    {"session_id": "abc-123", "model": {"id": "claude-opus-5", "display_name": "Opus"},
     "rate_limits": {"five_hour": {"used_percentage": 42.4, "resets_at": 1800004320},
                     "seven_day": {"used_percentage": 18, "resets_at": 1800400000}}}
    """

    /// Runs the script; returns (exit status, stdout).
    private func run(payload: String, home: URL) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [Self.scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        task.environment = env
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = Pipe()
        try task.run()
        stdin.fileHandleForWriting.write(payload.data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()
        task.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testWritesTheWholePayloadAsASnapshot() throws {
        let home = tempHome()
        let (status, _) = try run(payload: payload, home: home)
        XCTAssertEqual(status, 0)
        let snapshot = home.appendingPathComponent(".clyde/usage/statusline.json")
        let data = try Data(contentsOf: snapshot)
        let limits = UsageLimits.parse(data, modifiedAt: Date())
        XCTAssertEqual(limits?.fiveHour?.usedPercentage, 42.4)
        XCTAssertEqual(limits?.sessionID, "abc-123")
    }

    func testPrintsItsOwnLineWhenThereIsNoPassthrough() throws {
        let (status, out) = try run(payload: payload, home: tempHome())
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "Opus · 5h 42% · 7d 18%")
    }

    func testOwnLineOmitsAbsentLimits() throws {
        let noLimits = #"{"session_id": "abc", "model": {"display_name": "Opus"}}"#
        let (_, out) = try run(payload: noLimits, home: tempHome())
        XCTAssertEqual(out, "Opus")
    }

    func testPassesStdinThroughToTheUsersCommand() throws {
        let home = tempHome()
        let usageDir = home.appendingPathComponent(".clyde/usage")
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try "sed -e 's/.*display_name\": \"\\([A-Za-z]*\\)\".*/theirs:\\1/'"
            .write(to: usageDir.appendingPathComponent("passthrough"), atomically: true, encoding: .utf8)
        let (status, out) = try run(payload: payload.replacingOccurrences(of: "\n", with: ""), home: home)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, "theirs:Opus")
    }

    func testAFailingPassthroughStillExitsZero() throws {
        let home = tempHome()
        let usageDir = home.appendingPathComponent(".clyde/usage")
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try "exit 3".write(to: usageDir.appendingPathComponent("passthrough"), atomically: true, encoding: .utf8)
        let (status, _) = try run(payload: payload, home: home)
        XCTAssertEqual(status, 0)
    }

    func testGarbageInputStillExitsZero() throws {
        let (status, _) = try run(payload: "not json at all", home: tempHome())
        XCTAssertEqual(status, 0)
    }

    func testCarriesAVersionStamp() throws {
        let source = try String(contentsOf: Self.scriptURL, encoding: .utf8)
        XCTAssertTrue(source.contains("# clyde-statusline-version: \(1)"))
    }
}
