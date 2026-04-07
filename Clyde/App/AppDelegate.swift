import AppKit
import SwiftUI
import Combine
import Foundation

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        // Explicit drag regions only — SessionListView uses onDrag/onDrop
        // for reordering, so we can't let the whole background move the
        // window or every row drag becomes a window drag.
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// Invisible NSView whose only job is to report
/// `mouseDownCanMoveWindow = true`. Dropped behind draggable regions
/// (the collapsed widget chrome and the expanded title bar) so users
/// can still move the panel around the screen.
struct WindowDragArea: NSViewRepresentable {
    final class MovableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { MovableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Edge Snapping

enum ScreenEdge {
    case none, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!
    var statusItem: NSStatusItem?

    private let collapsedSize = NSSize(width: 186, height: 40)
    private let defaultExpandedSize = NSSize(width: 400, height: 420)
    private var lastExpandedSize: NSSize?
    private var savedWidgetOrigin: NSPoint?
    private var isAnimating = false
    private var isProgrammaticMove = false
    private var cancellables = Set<AnyCancellable>()
    private let snapMargin = AppConstants.edgeSnapMargin
    private let snapThreshold = AppConstants.edgeSnapThreshold

    func applicationDidFinishLaunching(_ notification: Notification) {
        appViewModel = AppViewModel()
        sessionViewModel = SessionListViewModel(
            processMonitor: appViewModel.processMonitor,
            attentionMonitor: appViewModel.attentionMonitor
        )

        let contentView = ContentView(
            appViewModel: appViewModel,
            sessionViewModel: sessionViewModel
        )

        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let initialOrigin = NSPoint(
            x: screenFrame.maxX - collapsedSize.width - snapMargin,
            y: screenFrame.maxY - collapsedSize.height - snapMargin
        )

        panel = FloatingPanel(contentRect: NSRect(origin: initialOrigin, size: collapsedSize))
        panel.minSize = collapsedSize
        panel.maxSize = collapsedSize
        savedWidgetOrigin = initialOrigin

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: collapsedSize)
        panel.contentView = hostingView

        panel.orderFront(nil)
        setupMenuBarIcon()
        appViewModel.start()
        registerGlobalHotKey()
        // Onboarding is deferred until the panel has been up for a moment
        // and we can present a non-blocking dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showOnboardingIfNeeded()
        }

        // Window move → snap to edges
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification, object: panel
        )

        appViewModel.$isCollapsed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                self?.performTransition(collapsed: isCollapsed)
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu Bar Icon

    @MainActor private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(menuBarClicked)
            button.target = self
            button.imagePosition = .imageLeft
        }

        refreshMenuBarItem()
        updateMenuBarMenu()

        // Update menu + icon whenever sessions, attention, or custom names change.
        appViewModel.processMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarItem()
                self?.updateMenuBarMenu()
            }
            .store(in: &cancellables)
        appViewModel.attentionMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarItem()
                self?.updateMenuBarMenu()
            }
            .store(in: &cancellables)
        // Rename events live in the session view model — subscribe so a new
        // custom name shows up in the dropdown without waiting for the next
        // process monitor tick.
        sessionViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarMenu() }
            .store(in: &cancellables)
        // Snooze changes — refresh icon + menu so the label switches between
        // "1 working" and "zzz 14m" immediately when the user toggles it.
        appViewModel.notificationService.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenuBarItem()
                self?.updateMenuBarMenu()
            }
            .store(in: &cancellables)
    }

    /// Render the menu bar button: Clyde silhouette (template) + a count
    /// label coloured to reflect the dominant state. Icon is always the
    /// same shape so the user sees "that's Clyde" at a glance; the state
    /// lives in the count's colour.
    @MainActor private func refreshMenuBarItem() {
        guard let button = statusItem?.button else { return }

        let liveSessions = appViewModel.processMonitor.sessions.filter { !$0.isGhost }
        let attentionPIDs = appViewModel.attentionMonitor.attentionPIDs
        let attention = liveSessions.filter { attentionPIDs.contains($0.pid) }.count
        let working = liveSessions.filter { $0.status == .busy && !attentionPIDs.contains($0.pid) }.count
        let ready = liveSessions.count - working - attention

        // Always the Clyde mascot as template — same silhouette regardless
        // of state, auto-tinted by macOS to match the menu bar appearance.
        button.image = ClydeMenuBarIcon.templateImage()

        // Snooze takes priority: show "zzz Xm" regardless of live counts so
        // the user clearly sees the app is muted.
        if appViewModel.notificationService.isSnoozed {
            let remaining = appViewModel.notificationService.minutesRemaining
            let title = NSAttributedString(
                string: " 💤 \(remaining)m",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            button.attributedTitle = title
            return
        }

        // State is conveyed by a small coloured dot prefix; the count
        // itself stays in the system label colour so it's always readable
        // regardless of what's behind the menu bar (wallpaper, transparent
        // background, dark/light mode).
        let count: Int
        let dotColor: NSColor
        if attention > 0 {
            count = attention
            dotColor = .systemBlue
        } else if working > 0 {
            count = working
            // Custom purple matching the widget and expanded view, but
            // lifted a notch for menu bar readability.
            dotColor = NSColor(red: 0.831, green: 0.549, blue: 1.0, alpha: 1)
        } else if ready > 0 {
            count = ready
            dotColor = .systemGreen
        } else {
            // No sessions — drop the count entirely, icon alone.
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let combined = NSMutableAttributedString()
        combined.append(NSAttributedString(
            string: " ● ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: dotColor,
                .baselineOffset: 1,
            ]
        ))
        combined.append(NSAttributedString(
            string: "\(count)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        button.attributedTitle = combined
    }

    @MainActor @objc private func menuBarClicked() {
        if appViewModel.isCollapsed {
            appViewModel.isCollapsed = false
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor private func updateMenuBarMenu() {
        let menu = NSMenu()

        // Read from sessionViewModel.sessions so we pick up user-set custom
        // names (stored per session_id in SessionListViewModel) instead of
        // the raw processMonitor output.
        let allSessions = sessionViewModel.sessions
        let liveSessions = allSessions.filter { !$0.isGhost }
        let attentionPIDs = appViewModel.attentionMonitor.attentionPIDs

        if liveSessions.isEmpty {
            let item = NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for session in liveSessions {
                let status: String
                if attentionPIDs.contains(session.pid) {
                    status = "🔵"
                } else if session.status == .busy {
                    status = "🟠"
                } else {
                    status = "🟢"
                }
                let title = "\(status) \(session.displayName)"
                let item = NSMenuItem(title: title, action: #selector(menuSessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.pid
                menu.addItem(item)
            }
        }

        let ghosts = allSessions.filter { $0.isGhost }
        if !ghosts.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recently ended", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for ghost in ghosts {
                let item = NSMenuItem(title: "⚪ \(ghost.displayName)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Snooze controls: if currently snoozed, show a "wake now" entry;
        // otherwise offer the standard preset durations as a submenu.
        let notifications = appViewModel.notificationService
        if notifications.isSnoozed {
            let remaining = notifications.minutesRemaining
            let resume = NSMenuItem(
                title: "Resume notifications (zzz \(remaining)m)",
                action: #selector(resumeNotifications),
                keyEquivalent: ""
            )
            resume.target = self
            menu.addItem(resume)
        } else {
            let snoozeMenu = NSMenu()
            for minutes in [15, 30, 60, 120] {
                let label = minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")"
                let item = NSMenuItem(title: label, action: #selector(snoozeClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = minutes
                snoozeMenu.addItem(item)
            }
            let snoozeParent = NSMenuItem(title: "Snooze notifications", action: nil, keyEquivalent: "")
            snoozeParent.submenu = snoozeMenu
            menu.addItem(snoozeParent)
        }

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Clyde", action: #selector(menuBarClicked), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clyde", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @MainActor @objc private func snoozeClicked(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        appViewModel.notificationService.snooze(minutes: minutes)
    }

    @MainActor @objc private func resumeNotifications() {
        appViewModel.notificationService.clearSnooze()
    }

    @MainActor @objc private func menuSessionClicked(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t,
              let session = appViewModel.processMonitor.sessions.first(where: { $0.pid == pid }) else { return }
        appViewModel.focusSession(session)
    }

    @MainActor @objc private func openSettings() {
        appViewModel.showSettings = true
        appViewModel.isCollapsed = false
    }

    // MARK: - Onboarding

    private static let onboardingShownKey = "onboardingShown"

    private var onboardingWindow: NSWindow?

    @MainActor private func showOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingShownKey) else { return }

        // LSUIElement apps don't normally appear in the Dock; temporarily
        // switch to .regular so our custom onboarding window gets focus
        // and standard window-level behaviour.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let onboardingView = OnboardingView(
            onGetStarted: { [weak self] in
                self?.dismissOnboarding()
            },
            onOpenSettings: { [weak self] in
                self?.dismissOnboarding()
                self?.openSettings()
            }
        )

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Clyde"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        window.isMovableByWindowBackground = true
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window

        defaults.set(true, forKey: Self.onboardingShownKey)
    }

    @MainActor private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Expand/Collapse Animation

    private func performTransition(collapsed: Bool) {
        guard !isAnimating else { return }
        isAnimating = true

        let currentFrame = panel.frame
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        // On first expand or if widget moved, capture its origin as the anchor
        if !collapsed && savedWidgetOrigin == nil {
            savedWidgetOrigin = currentFrame.origin
        }
        if collapsed {
            // Save expanded size for next open
            lastExpandedSize = currentFrame.size
        }

        let targetSize = collapsed ? collapsedSize : (lastExpandedSize ?? defaultExpandedSize)

        // The widget anchor is the single source of truth
        let widgetOrigin = savedWidgetOrigin ?? currentFrame.origin
        let widgetTopY = widgetOrigin.y + collapsedSize.height  // top edge in macOS coords

        var newOrigin: NSPoint
        if collapsed {
            // Returning to widget — use saved origin directly
            newOrigin = widgetOrigin
        } else {
            // Expanding — anchor to widget's visual edge based on screen half
            let widgetCenterX = widgetOrigin.x + collapsedSize.width / 2
            let anchorRight = widgetCenterX > screenFrame.midX

            if anchorRight {
                // Align right edges
                newOrigin = NSPoint(
                    x: widgetOrigin.x + collapsedSize.width - targetSize.width,
                    y: widgetTopY - targetSize.height
                )
            } else {
                // Align left edges
                newOrigin = NSPoint(
                    x: widgetOrigin.x,
                    y: widgetTopY - targetSize.height
                )
            }
        }

        // Clamp to screen bounds
        newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - targetSize.width))
        newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - targetSize.height))

        let targetFrame = NSRect(origin: newOrigin, size: targetSize)

        // Relax size constraints so animation can change the frame
        panel.minSize = NSSize(width: 1, height: 1)
        panel.maxSize = NSSize(width: 10000, height: 10000)

        animateFrame(to: targetFrame, duration: 0.35) { [weak self] in
            guard let self else { return }
            // Re-lock to target size
            self.panel.minSize = targetSize
            self.panel.maxSize = targetSize
            self.isAnimating = false
        }
    }

    private func animateFrame(to target: NSRect, duration: TimeInterval, completion: @escaping () -> Void) {
        let start = panel.frame
        let startTime = CACurrentMediaTime()
        let interval = 1.0 / 120.0

        isProgrammaticMove = true

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(elapsed / duration, 1.0)

            let t = 1 - pow(1 - progress, 4)

            let x = start.origin.x + (target.origin.x - start.origin.x) * t
            let y = start.origin.y + (target.origin.y - start.origin.y) * t
            let w = start.size.width + (target.size.width - start.size.width) * t
            let h = start.size.height + (target.size.height - start.size.height) * t

            self.panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)

            if progress >= 1.0 {
                timer.invalidate()
                self.panel.setFrame(target, display: true)
                // Keep isProgrammaticMove=true longer to absorb lingering notifications
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.isProgrammaticMove = false
                }
                completion()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Edge Snapping

    @MainActor @objc private func windowDidMove(_ notification: Notification) {
        guard !isAnimating, !isProgrammaticMove else { return }
        // Only track drags when in collapsed widget mode
        guard appViewModel.isCollapsed else { return }
        // Debounce — snap after user stops dragging (no move for 0.15s)
        snapDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.snapToNearestEdge()
            // Save the new widget position as anchor
            self.savedWidgetOrigin = self.panel.frame.origin
        }
        snapDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var snapDebounceWork: DispatchWorkItem?
    private var globalHotKeyMonitor: Any?
    private var localHotKeyMonitor: Any?

    // MARK: - Global hotkey (⌃⌘C)

    /// Toggles the expanded view from anywhere on the system.
    /// Uses NSEvent monitors (no entitlements needed). The local monitor
    /// covers the case when Clyde itself is the key window.
    @MainActor private func registerGlobalHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            // ⌃⌘C — control + command + "c"
            let needsModifiers: NSEvent.ModifierFlags = [.control, .command]
            let activeFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard activeFlags == needsModifiers else { return }
            guard event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
            DispatchQueue.main.async {
                self.toggleFromHotkey()
            }
        }

        globalHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    @MainActor private func toggleFromHotkey() {
        appViewModel.toggleExpanded()
        if !appViewModel.isCollapsed {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func snapToNearestEdge() {
        let frame = panel.frame
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var snapped = frame.origin

        if frame.minX < screen.minX + snapThreshold {
            snapped.x = screen.minX + snapMargin
        } else if frame.maxX > screen.maxX - snapThreshold {
            snapped.x = screen.maxX - frame.width - snapMargin
        }

        if frame.maxY > screen.maxY - snapThreshold {
            snapped.y = screen.maxY - frame.height - snapMargin
        } else if frame.minY < screen.minY + snapThreshold {
            snapped.y = screen.minY + snapMargin
        }

        if snapped != frame.origin {
            isProgrammaticMove = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(snapped)
            }, completionHandler: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.isProgrammaticMove = false
                    self?.savedWidgetOrigin = self?.panel.frame.origin
                }
            })
        }
    }
}

