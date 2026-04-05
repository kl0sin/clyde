import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!

    private let collapsedSize = NSSize(width: 150, height: 52)
    private let defaultExpandedSize = NSSize(width: 400, height: 420)
    private var lastExpandedFrame: NSRect?
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

        setCollapsedConstraints()

        appViewModel.$isCollapsed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.animateTransition(collapsed: isCollapsed)
            }
            .store(in: &cancellables)
    }

    private func setCollapsedConstraints() {
        panel.styleMask.remove(.resizable)
        panel.minSize = collapsedSize
        panel.maxSize = collapsedSize
    }

    private func setExpandedConstraints() {
        panel.styleMask.insert(.resizable)
        panel.minSize = NSSize(width: 320, height: 300)
        panel.maxSize = NSSize(width: 700, height: 800)
    }

    private func animateTransition(collapsed: Bool) {
        let currentFrame = panel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        if collapsed {
            lastExpandedFrame = currentFrame
        }

        let targetSize = collapsed ? collapsedSize : (lastExpandedFrame?.size ?? defaultExpandedSize)

        var origin: NSPoint
        if !collapsed, let saved = lastExpandedFrame {
            origin = saved.origin
        } else {
            origin = NSPoint(
                x: currentFrame.maxX - targetSize.width,
                y: currentFrame.maxY - targetSize.height
            )
        }

        // Clamp to screen
        origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - targetSize.width))
        origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - targetSize.height))

        if !collapsed { setExpandedConstraints() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: origin, size: targetSize), display: true)
        }, completionHandler: { [weak self] in
            if collapsed { self?.setCollapsedConstraints() }
        })
    }
}
