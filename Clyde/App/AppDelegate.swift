import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
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

        // Hide standard buttons
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!

    private let collapsedSize = NSSize(width: 90, height: 120)
    private let expandedSize = NSSize(width: 420, height: 480)
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
        panel.minSize = NSSize(width: 90, height: 120)

        panel.orderFront(nil)
        appViewModel.start()

        // Start collapsed — disable resize in collapsed mode
        updatePanelForState(collapsed: true)

        appViewModel.$isCollapsed
            .dropFirst() // Skip initial value
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.animateTransition(collapsed: isCollapsed)
            }
            .store(in: &cancellables)
    }

    private func updatePanelForState(collapsed: Bool) {
        if collapsed {
            panel.styleMask.remove(.resizable)
            panel.minSize = collapsedSize
            panel.maxSize = collapsedSize
        } else {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 320, height: 350)
            panel.maxSize = NSSize(width: 800, height: 1000)
        }
    }

    private func animateTransition(collapsed: Bool) {
        let currentFrame = panel.frame
        let newSize = collapsed ? collapsedSize : expandedSize
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        // Anchor top-right corner
        var newOrigin = NSPoint(
            x: currentFrame.maxX - newSize.width,
            y: currentFrame.maxY - newSize.height
        )

        // Clamp to screen bounds
        newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - newSize.width))
        newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - newSize.height))

        let newFrame = NSRect(origin: newOrigin, size: newSize)

        // Update constraints before animation
        if !collapsed {
            panel.minSize = NSSize(width: 320, height: 350)
            panel.maxSize = NSSize(width: 800, height: 1000)
            panel.styleMask.insert(.resizable)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.updatePanelForState(collapsed: collapsed)
        })
    }
}
