import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!

    private let collapsedSize = NSSize(width: 80, height: 110)
    private let expandedSize = NSSize(width: 360, height: 400)
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appViewModel = AppViewModel()
        sessionViewModel = SessionListViewModel(processMonitor: appViewModel.processMonitor)

        let contentView = ContentView(
            appViewModel: appViewModel,
            sessionViewModel: sessionViewModel
        )

        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let initialOrigin = NSPoint(
            x: screenFrame.maxX - collapsedSize.width - 20,
            y: screenFrame.maxY - collapsedSize.height - 20
        )

        panel = FloatingPanel(contentRect: NSRect(origin: initialOrigin, size: collapsedSize))
        panel.contentView = NSHostingView(rootView: contentView)

        panel.orderFront(nil)
        appViewModel.start()

        appViewModel.$isCollapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.animateTransition(collapsed: isCollapsed)
            }
            .store(in: &cancellables)
    }

    private func animateTransition(collapsed: Bool) {
        let currentFrame = panel.frame
        let newSize = collapsed ? collapsedSize : expandedSize

        let newOrigin = NSPoint(
            x: currentFrame.maxX - newSize.width,
            y: currentFrame.maxY - newSize.height
        )

        let newFrame = NSRect(origin: newOrigin, size: newSize)

        panel.setFrame(newFrame, display: true, animate: true)
        panel.isMovableByWindowBackground = collapsed

        if !collapsed {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 300, height: 300)
        } else {
            panel.styleMask.remove(.resizable)
        }
    }
}
