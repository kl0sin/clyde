import XCTest
@testable import Clyde

final class HistoryStoreTests: XCTestCase {

    func testParsesAToolEventLine() {
        let line = #"{"ts": 1787660000, "event": "PreToolUse", "session_id": "s1", "cwd": "/repo", "tool": "Bash", "summary": "swift test"}"#

        let event = HistorySpool.parse(line: line)

        XCTAssertEqual(event?.event, "PreToolUse")
        XCTAssertEqual(event?.sessionID, "s1")
        XCTAssertEqual(event?.project, "/repo")
        XCTAssertEqual(event?.tool, "Bash")
        XCTAssertEqual(event?.summary, "swift test")
        XCTAssertEqual(event?.ts, Date(timeIntervalSince1970: 1787660000))
    }

    /// A shell-written file can always be cut mid-line by a full disk, so
    /// a broken line must be a skipped line, never a thrown error.
    func testReturnsNilForATruncatedLine() {
        XCTAssertNil(HistorySpool.parse(line: #"{"ts": 178766000"#))
        XCTAssertNil(HistorySpool.parse(line: ""))
    }

    /// Missing optional fields are normal: turn boundaries carry no tool.
    func testParsesAnEventWithoutToolFields() {
        let line = #"{"ts": 1787660000, "event": "Stop", "session_id": "s1", "cwd": "/repo"}"#

        let event = HistorySpool.parse(line: line)

        XCTAssertEqual(event?.event, "Stop")
        XCTAssertNil(event?.tool)
    }
}
