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
        // Starts collapsed → background drag enabled. Toggled off when
        // expanding so the session list's drag-to-reorder works.
        isMovableByWindowBackground = true
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
    /// The widget panel — small, fixed size, always at its anchor.
    /// Hosts only `WidgetView`. Never resizes.
    var panel: FloatingPanel!
    /// The expanded panel — larger, hosts the session list / settings.
    /// Sibling of `panel`. Shown / hidden via fade + small slide on
    /// `appViewModel.isCollapsed` toggling. Positioned next to the
    /// widget anchor through `WidgetAnchor.expandedOrigin`.
    var expandedPanel: ExpandedPanel!
    var appViewModel: AppViewModel!
    var sessionViewModel: SessionListViewModel!
    var statusItem: NSStatusItem?

    private let widgetSize = NSSize(width: 130, height: 40)
    private let expandedSize = NSSize(width: 400, height: 420)
    /// Single source of truth for the widget's preferred position. See
    /// `WidgetAnchor.swift` for the rationale.
    private var widgetAnchor: WidgetAnchor!
    private var isProgrammaticMove = false
    private var cancellables = Set<AnyCancellable>()
    private let snapMargin = AppConstants.edgeSnapMargin
    private let snapThreshold = AppConstants.edgeSnapThreshold

    /// Monitor for left-mouse events used to make the expanded panel
    /// draggable from its header strip. Set up in
    /// `installExpandedDragMonitor`, removed at deinit.
    private var expandedDragMonitor: Any?
    /// State for an in-progress expanded-panel drag. `nil` when the user
    /// isn't currently dragging the expanded panel by its header.
    /// `hasMoved` distinguishes a real drag from a plain click (e.g. on
    /// the collapse button) — without that distinction, mouseUp would
    /// interpret a button click as the end of a zero-distance drag.
    private struct ExpandedDragState {
        let initialFrameOrigin: NSPoint
        let initialMouseLocation: NSPoint
        var hasMoved: Bool
    }
    private var expandedDragState: ExpandedDragState?
    private static let dragActivationDistance: CGFloat = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        appViewModel = AppViewModel()
        sessionViewModel = SessionListViewModel(
            processMonitor: appViewModel.processMonitor,
            attentionMonitor: appViewModel.attentionMonitor
        )

        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let initialOrigin = NSPoint(
            x: screenFrame.maxX - widgetSize.width - snapMargin,
            y: screenFrame.maxY - widgetSize.height - snapMargin
        )
        widgetAnchor = WidgetAnchor(origin: initialOrigin)

        // --- Widget panel ---
        // Always at fixed widget size. Hosts WidgetView only. Never
        // resizes — that was the source of half our previous bugs.
        panel = FloatingPanel(contentRect: NSRect(origin: initialOrigin, size: widgetSize))
        panel.minSize = widgetSize
        panel.maxSize = widgetSize

        let widgetRoot = WidgetView(viewModel: appViewModel)
        let widgetHostingView = NSHostingView(rootView: widgetRoot)
        widgetHostingView.frame = NSRect(origin: .zero, size: widgetSize)
        panel.contentView = widgetHostingView
        panel.orderFront(nil)

        // --- Expanded panel ---
        // Created up-front but kept hidden (orderOut + alpha 0) until
        // the user expands. Position is recomputed every show.
        let expandedOrigin = widgetAnchor.expandedOrigin(
            for: expandedSize,
            in: screenFrame,
            collapsedSize: widgetSize
        )
        expandedPanel = ExpandedPanel(
            contentRect: NSRect(origin: expandedOrigin, size: expandedSize)
        )
        expandedPanel.minSize = expandedSize
        expandedPanel.maxSize = expandedSize

        let expandedRoot = ExpandedRootView(
            appViewModel: appViewModel,
            sessionViewModel: sessionViewModel
        )
        let expandedHostingView = NSHostingView(rootView: expandedRoot)
        expandedHostingView.frame = NSRect(origin: .zero, size: expandedSize)
        expandedPanel.contentView = expandedHostingView
        expandedPanel.alphaValue = 0
        // Don't orderFront yet — it stays hidden until the user opens it.

        setupMenuBarIcon()
        appViewModel.start()
        registerGlobalHotKey()
        installExpandedDragMonitor()
        // Onboarding is deferred until the panel has been up for a moment
        // and we can present a non-blocking dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showOnboardingIfNeeded()
        }

        // Window move on the WIDGET → snap to edges and update anchor.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification, object: panel
        )

        appViewModel.$isCollapsed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isCollapsed in
                if isCollapsed {
                    self?.hideExpandedPanel()
                } else {
                    self?.showExpandedPanel()
                }
            }
            .store(in: &cancellables)

        // React to "show floating widget" toggle: when the user turns the
        // widget off, hide the widget panel. The expanded panel remains
        // available via the menu bar entry point.
        appViewModel.$widgetVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.applyWidgetVisibility(visible)
            }
            .store(in: &cancellables)

        applyWidgetVisibility(appViewModel.widgetVisible)
    }

    /// Show or hide the WIDGET panel based on the user preference.
    /// The expanded panel is unaffected — even when the widget is
    /// hidden, the user can still open the expanded view from the menu
    /// bar item.
    @MainActor private func applyWidgetVisibility(_ visible: Bool) {
        if visible {
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Expanded panel show / hide

    /// Position + animate-in the expanded panel next to the widget.
    @MainActor private func showExpandedPanel() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let targetOrigin = widgetAnchor.expandedOrigin(
            for: expandedSize,
            in: screen,
            collapsedSize: widgetSize
        )

        // Pre-position 8pt below the final spot so the appearance
        // looks like a small slide + fade-in instead of a hard pop.
        let startOrigin = NSPoint(x: targetOrigin.x, y: targetOrigin.y - 8)
        expandedPanel.setFrameOrigin(startOrigin)
        expandedPanel.alphaValue = 0
        expandedPanel.orderFront(nil)
        expandedPanel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            expandedPanel.animator().setFrameOrigin(targetOrigin)
            expandedPanel.animator().alphaValue = 1
        })
    }

    /// Animate the expanded panel out and order it offscreen.
    @MainActor private func hideExpandedPanel() {
        let currentOrigin = expandedPanel.frame.origin
        let endOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y - 8)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            expandedPanel.animator().alphaValue = 0
            expandedPanel.animator().setFrameOrigin(endOrigin)
        }, completionHandler: { [weak self] in
            self?.expandedPanel.orderOut(nil)
        })
    }

    // MARK: - Menu Bar Icon

    @MainActor private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(menuBarClicked)
            button.target = self
            button.imagePosition = .imageLeft
            button.setAccessibilityLabel("Clyde — Claude Code session monitor")
            button.setAccessibilityRole(.button)
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

        // Snooze takes priority: show the template Clyde icon + "💤 Xm"
        // so the user clearly sees the app is muted.
        if appViewModel.notificationService.isSnoozed {
            let remaining = appViewModel.notificationService.minutesRemaining
            button.image = ClydeMenuBarIcon.templateImage()
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

        // No live sessions → drop the rich capsule and fall back to the
        // plain template Clyde silhouette so the menu bar stays quiet.
        if attention == 0 && working == 0 && ready == 0 {
            button.image = ClydeMenuBarIcon.templateImage()
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        // Render the rich capsule (sprite watermark + dominant count) plus
        // the two stacked ticks for the non-dominant states. The image
        // builder picks the dominant state internally with the same
        // attention > working > ready priority used everywhere else.
        button.image = ClydeMenuBarStatus.image(
            attention: attention,
            working: working,
            ready: ready
        )
        // The capsule already contains the count; clear any prior title
        // so we don't double up text next to the image.
        button.attributedTitle = NSAttributedString(string: "")
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
                // Coloured-bullet prefix matching the rest of the app:
                // blue = attention, purple = working, green = ready.
                let status: String
                if attentionPIDs.contains(session.pid) {
                    status = "🔵"
                } else if session.status == .busy {
                    status = "🟣"
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

        let updateItem = NSMenuItem(
            title: "Check for updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = UpdateController.shared
        menu.addItem(updateItem)

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

    // MARK: - Edge Snapping

    @MainActor @objc private func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        // Debounce — snap after user stops dragging (no move for 0.15s).
        snapDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.snapToNearestEdge()
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
            // Snap needed — animate, then commit the post-snap position
            // as the new widget anchor in the completion handler.
            isProgrammaticMove = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(snapped)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    self.isProgrammaticMove = false
                    self.widgetAnchor = WidgetAnchor(origin: self.panel.frame.origin)
                }
            })
        } else {
            // No snap needed — the panel is already at a valid position,
            // commit the current frame as the new anchor.
            widgetAnchor = WidgetAnchor(origin: frame.origin)
        }
    }

    // MARK: - Expanded-panel drag

    /// Allow the user to drag the expanded panel by clicking-and-dragging
    /// inside its header strip. The panel has
    /// `isMovableByWindowBackground = false` because SessionListView
    /// uses SwiftUI onDrag/onDrop for row reordering, so we install a
    /// low-level NSEvent monitor that tracks the mouse manually and
    /// only acts when the click started in the top header strip.
    @MainActor private func installExpandedDragMonitor() {
        // Header strip height — matches ExpandedHeader's visual height
        // (sprite tile 44 + vertical padding 14*2 ≈ 72pt). Slight fudge.
        let headerHeight: CGFloat = 72

        expandedDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  event.window === self.expandedPanel else {
                return event
            }

            switch event.type {
            case .leftMouseDown:
                let local = event.locationInWindow
                let inHeader = local.y >= self.expandedPanel.frame.height - headerHeight
                guard inHeader else {
                    self.expandedDragState = nil
                    return event
                }
                self.expandedDragState = ExpandedDragState(
                    initialFrameOrigin: self.expandedPanel.frame.origin,
                    initialMouseLocation: NSEvent.mouseLocation,
                    hasMoved: false
                )
                return event

            case .leftMouseDragged:
                guard var drag = self.expandedDragState else { return event }
                let current = NSEvent.mouseLocation
                let dx = current.x - drag.initialMouseLocation.x
                let dy = current.y - drag.initialMouseLocation.y
                if !drag.hasMoved {
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard distance >= Self.dragActivationDistance else {
                        return event
                    }
                    drag.hasMoved = true
                    self.expandedDragState = drag
                }
                self.expandedPanel.setFrameOrigin(NSPoint(
                    x: drag.initialFrameOrigin.x + dx,
                    y: drag.initialFrameOrigin.y + dy
                ))
                return event

            case .leftMouseUp:
                guard let drag = self.expandedDragState else { return event }
                self.expandedDragState = nil
                guard drag.hasMoved else { return event }
                // Recompute the widget anchor from the new expanded
                // frame so that on the next collapse the widget snaps
                // to a sensible spot adjacent to where the user dropped
                // the expanded panel.
                if let screen = NSScreen.main?.visibleFrame {
                    self.widgetAnchor = WidgetAnchor.from(
                        expandedFrame: self.expandedPanel.frame,
                        in: screen,
                        collapsedSize: self.widgetSize
                    )
                    // And actually move the widget panel to the new
                    // anchor so the two stay co-located visually.
                    self.isProgrammaticMove = true
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.18
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.panel.animator().setFrameOrigin(self.widgetAnchor.origin)
                    }, completionHandler: { [weak self] in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self?.isProgrammaticMove = false
                        }
                    })
                }
                return event

            default:
                return event
            }
        }
    }
}

