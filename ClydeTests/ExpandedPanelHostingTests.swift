import XCTest
import AppKit
import SwiftUI
@testable import Clyde

/// `ExpandedPanelTests` pins the window class. This pins the thing that
/// actually broke: the panel with the real SwiftUI tree inside it.
///
/// v0.8.0's panel came up 400×1476 because AppKit sizes a window to its
/// content view's fitting size, and on the SDK the release is built
/// against, the session list reported one. It never reproduced on the
/// development machine — a different SDK, a different measurement — so
/// the only place this test says anything new is CI, where the compiler
/// is the one that shipped the bug.
///
/// The unpinned measurement is a probe, not an assertion: it records what
/// this SDK's SwiftUI wants the content to be, and the log is the
/// evidence. The assertions below it must hold on every SDK.
@MainActor
final class ExpandedPanelHostingTests: XCTestCase {

    private let expandedSize = NSSize(width: 400, height: 420)

    /// The v0.8.0 screenshots were of a panel with a real day's worth of
    /// sessions in it, and the height came from the list. One row is not
    /// the shape that broke — fill it.
    private func makeViewModels(sessions: Int = 12) -> (AppViewModel, SessionListViewModel) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-panel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<sessions {
            // Distinct pids: sessions collapse by pid, and liveness is
            // injected true below, so these never have to exist.
            let pid = 90000 + i
            let sid = UUID().uuidString
            let cwd = "/Users/me/projects/a-project-with-a-fairly-long-name-\(i)"
            let info = #"{"session_id":"\#(sid)","pid":\#(pid),"cwd":"\#(cwd)","started_at":0}"#
            try? info.write(to: dir.appendingPathComponent("\(sid)-info"),
                            atomically: true, encoding: .utf8)
            let busy = #"{"session_id":"\#(sid)","pid":\#(pid),"cwd":"\#(cwd)","timestamp":\#(Int(Date().timeIntervalSince1970))}"#
            try? busy.write(to: dir.appendingPathComponent("\(sid)-busy"),
                            atomically: true, encoding: .utf8)
        }

        let shell = MockShellExecutor()
        shell.responses["pgrep"] = ""
        let monitor = ProcessMonitor(shell: shell, pollingInterval: 1, stateDir: dir,
                                     isLiveClaudeProcessCheck: { _ in true })
        return (AppViewModel(processMonitor: monitor),
                SessionListViewModel(processMonitor: monitor))
    }

    private func rootView(_ appVM: AppViewModel, _ sessionVM: SessionListViewModel) -> ExpandedRootView {
        ExpandedRootView(appViewModel: appVM, sessionViewModel: sessionVM)
    }

    /// What the SDK under test wants the content to be, with nothing
    /// pinning it. Prints; never fails. On the SDK that shipped v0.8.0
    /// this is where the 1476 comes from.
    func testWhatThisSDKWantsTheUnpinnedContentToBe() async {
        let (appVM, sessionVM) = makeViewModels()
        await appVM.processMonitor.poll()

        let hosting = NSHostingView(rootView: rootView(appVM, sessionVM))
        let wanted = hosting.fittingSize

        let bare = NSPanel(contentRect: NSRect(origin: .zero, size: expandedSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        bare.contentView = hosting

        print("PANEL-PROBE unpinned sessions=\(sessionVM.sessionCount) fittingSize=\(wanted) bareWindow=\(bare.frame.size) sdkGrows=\(bare.frame.height > expandedSize.height)")
    }

    /// The panel as `AppDelegate` builds it: pinned root, pinned window.
    /// This must be 400×420 whatever the SDK's SwiftUI decides.
    func testTheRealPanelIsTheSizeItSaysItIs() async {
        let (appVM, sessionVM) = makeViewModels()
        await appVM.processMonitor.poll()

        let panel = ExpandedPanel(contentRect: NSRect(origin: NSPoint(x: 100, y: 100),
                                                      size: expandedSize))
        panel.minSize = expandedSize
        panel.maxSize = expandedSize

        let hosting = NSHostingView(
            rootView: rootView(appVM, sessionVM)
                .frame(width: expandedSize.width, height: expandedSize.height)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: expandedSize)
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: expandedSize), display: true)

        print("PANEL-PROBE pinned sessions=\(sessionVM.sessionCount) panel=\(panel.frame.size) content=\(hosting.fittingSize)")
        XCTAssertEqual(panel.frame.size, expandedSize,
                       "the panel grew to fit its content — this is the v0.8.0 bug")
    }

    /// Laying the content out is when SwiftUI reports a size, so do it and
    /// check the window again: the shipped bug appeared after the view
    /// tree had measured itself, not at construction.
    func testThePanelStaysPinnedAfterTheContentLaysOut() async {
        let (appVM, sessionVM) = makeViewModels()
        await appVM.processMonitor.poll()

        let panel = ExpandedPanel(contentRect: NSRect(origin: NSPoint(x: 100, y: 100),
                                                      size: expandedSize))
        let hosting = NSHostingView(
            rootView: rootView(appVM, sessionVM)
                .frame(width: expandedSize.width, height: expandedSize.height)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: expandedSize)
        panel.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        panel.displayIfNeeded()

        XCTAssertEqual(panel.frame.size, expandedSize)
    }
}
