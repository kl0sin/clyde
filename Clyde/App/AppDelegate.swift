import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var isDragging = false
    private var dragOffset = NSPoint.zero

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!

    private let collapsedSize = NSSize(width: 150, height: 52)
    private let defaultExpandedSize = NSSize(width: 400, height: 420)
    private var lastExpandedSize: NSSize?
    private var isAnimating = false
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

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        panel.orderFront(nil)
        appViewModel.start()

        appViewModel.$isCollapsed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.performTransition(collapsed: isCollapsed)
            }
            .store(in: &cancellables)
    }

    private func performTransition(collapsed: Bool) {
        guard !isAnimating else { return }
        isAnimating = true

        let currentFrame = panel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        // Save expanded size before collapsing
        if collapsed {
            lastExpandedSize = currentFrame.size
        }

        let targetSize = collapsed ? collapsedSize : (lastExpandedSize ?? defaultExpandedSize)

        // Anchor: keep top-right corner fixed
        let newOrigin = NSPoint(
            x: max(screenFrame.minX, min(currentFrame.maxX - targetSize.width, screenFrame.maxX - targetSize.width)),
            y: max(screenFrame.minY, min(currentFrame.maxY - targetSize.height, screenFrame.maxY - targetSize.height))
        )

        let targetFrame = NSRect(origin: newOrigin, size: targetSize)

        // Phase 1: Fade out content
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.contentView?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }

            // Phase 2: Resize window with spring-like ease
            self.animateFrame(to: targetFrame, duration: 0.28) {
                // Phase 3: Fade in new content
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel.contentView?.animator().alphaValue = 1
                }, completionHandler: {
                    self.isAnimating = false
                })
            }
        })
    }

    /// Custom frame animation using CVDisplayLink for ultra-smooth 60fps
    private func animateFrame(to target: NSRect, duration: TimeInterval, completion: @escaping () -> Void) {
        let start = panel.frame
        let startTime = CACurrentMediaTime()

        // Use a high-frequency timer for smooth animation
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(elapsed / duration, 1.0)

            // Cubic ease-in-out for smooth feel
            let t = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2

            let x = start.origin.x + (target.origin.x - start.origin.x) * t
            let y = start.origin.y + (target.origin.y - start.origin.y) * t
            let w = start.size.width + (target.size.width - start.size.width) * t
            let h = start.size.height + (target.size.height - start.size.height) * t

            self.panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)

            if progress >= 1.0 {
                timer.invalidate()
                completion()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
    }
}
