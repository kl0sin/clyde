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

    /// Activate panel to receive keyboard input
    func activateForInput() {
        // Remove nonactivatingPanel to allow keyboard focus
        styleMask.remove(.nonactivatingPanel)
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
    }

    /// Return to non-activating mode (floating widget)
    func deactivateForWidget() {
        styleMask.insert(.nonactivatingPanel)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!

    private let collapsedSize = NSSize(width: 90, height: 120)
    private let defaultExpandedSize = NSSize(width: 480, height: 520)
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

        // Start collapsed
        updatePanelForState(collapsed: true)

        appViewModel.$isCollapsed
            .dropFirst()
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
            panel.deactivateForWidget()
        } else {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 360, height: 300)
            panel.maxSize = NSSize(width: 1200, height: 900)
            panel.activateForInput()
        }
    }

    private func animateTransition(collapsed: Bool) {
        let currentFrame = panel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        if collapsed {
            // Save current expanded frame before collapsing
            lastExpandedFrame = currentFrame
        }

        let targetSize: NSSize
        if collapsed {
            targetSize = collapsedSize
        } else if let saved = lastExpandedFrame {
            targetSize = saved.size
        } else {
            targetSize = defaultExpandedSize
        }

        // Determine position
        var newOrigin: NSPoint
        if !collapsed, let saved = lastExpandedFrame {
            // Restore saved position
            newOrigin = saved.origin
        } else {
            // Anchor top-right corner
            newOrigin = NSPoint(
                x: currentFrame.maxX - targetSize.width,
                y: currentFrame.maxY - targetSize.height
            )
        }

        // Clamp to screen bounds
        newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - targetSize.width))
        newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - targetSize.height))

        let newFrame = NSRect(origin: newOrigin, size: targetSize)

        // Prepare constraints before expanding
        if !collapsed {
            panel.minSize = NSSize(width: 360, height: 300)
            panel.maxSize = NSSize(width: 1200, height: 900)
            panel.styleMask.insert(.resizable)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.updatePanelForState(collapsed: collapsed)

            // Focus the terminal text view after expanding
            if !collapsed {
                self.focusTerminalTextView()
            }
        })
    }

    private func focusTerminalTextView() {
        // Walk the view hierarchy to find the TerminalTextView and make it first responder
        guard let hostingView = panel.contentView else { return }
        if let textView = findTerminalTextView(in: hostingView) {
            panel.makeFirstResponder(textView)
        }
    }

    private func findTerminalTextView(in view: NSView) -> NSView? {
        if view is TerminalTextView {
            return view
        }
        for subview in view.subviews {
            if let found = findTerminalTextView(in: subview) {
                return found
            }
        }
        return nil
    }
}
