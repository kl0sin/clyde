import AppKit
import SwiftUI
import Combine
import Foundation

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The widget's one permitted size. Same reasoning as
    /// `ExpandedPanel.fixedSize`, and the same exposure: the comment where
    /// this panel is built records an earlier round of SwiftUI content
    /// pushing it a few points taller, which drifts the anchor maths that
    /// places the expanded panel beside it. That was corrected with a
    /// one-shot setFrame — the same defence that failed to hold in v0.8.0.
    private let fixedSize: NSSize

    init(contentRect: NSRect) {
        fixedSize = contentRect.size
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

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: frameRect.origin, size: fixedSize), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(NSRect(origin: frameRect.origin, size: fixedSize),
                       display: flag, animate: animate)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(fixedSize)
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

    /// Widget panel size. Height MUST match the actual SwiftUI content
    /// height (CompactStatusView's dominantBlock is 30pt + 8pt vertical
    /// padding × 2 = 46pt) — otherwise NSHostingView reports a
    /// different intrinsic content size and the panel ends up taller
    /// than `widgetSize`, breaking the WidgetAnchor gap math.
    private let widgetSize = NSSize(width: 130, height: 46)
    static let fullPanelHeight: CGFloat = 420
    /// The full panel's size, and what the window is built at. Compact
    /// changes the height afterwards through `applyHeight`.
    private let expandedSize = NSSize(width: 400, height: AppDelegate.fullPanelHeight)
    /// Single source of truth for the widget's preferred position. See
    /// `WidgetAnchor.swift` for the rationale.
    private var widgetAnchor: WidgetAnchor!
    private var isProgrammaticMove = false
    private var cancellables = Set<AnyCancellable>()
    private let snapMargin = AppConstants.edgeSnapMargin
    private let snapThreshold = AppConstants.edgeSnapThreshold

    /// NSEvent monitor for left-mouse events used to drag the expanded
    /// panel by its header strip. The expanded panel is independent of
    /// the widget once open — the widget can be dragged separately
    /// without affecting the expanded panel position.
    private var expandedDragMonitor: Any?
    /// State for an in-progress expanded-panel drag.
    private struct ExpandedDragState {
        let initialFrameOrigin: NSPoint
        let initialMouseLocation: NSPoint
        var hasMoved: Bool
    }
    private var expandedDragState: ExpandedDragState?
    private static let dragActivationDistance: CGFloat = 3

    /// Token returned by `NotificationCenter.addObserver(forName:…)`. We
    /// hold it explicitly so `deinit` can remove it; the older
    /// selector-based observer leaked across the app's lifetime.
    private var widgetMoveObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var diagnosticsObserver: NSObjectProtocol?
    private var reviewObserver: NSObjectProtocol?
    private var rebuildHistoryObserver: NSObjectProtocol?
    private var panelResizeObserver: NSObjectProtocol?

    private(set) var historyStore: HistoryStore?
    private var historyIngestTimer: Timer?

    deinit {
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = diagnosticsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = widgetMoveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = reviewObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = rebuildHistoryObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = panelResizeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let monitor = globalHotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localHotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = expandedDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appViewModel = AppViewModel()
        // Run synchronously before the menu-bar item or panels exist —
        // otherwise an upgrading user could click the icon and trigger
        // `maybeStart` before the migration sets `coachmarksShown`.
        appViewModel.coachmarks.runMigrationIfNeeded()
        sessionViewModel = SessionListViewModel(
            processMonitor: appViewModel.processMonitor,
            attentionMonitor: appViewModel.attentionMonitor
        )

        // History is best-effort: if the store cannot be opened, Clyde
        // carries on with tracking and the review window reports itself
        // unavailable. Session tracking must never break because of a
        // statistics feature.
        do {
            let store = try HistoryStore(directory: AppPaths.historyDir)
            historyStore = store
            appViewModel.historyAvailable = true
            DispatchQueue.global(qos: .utility).async { store.ingestPending() }
            // 30s, not the 3s poll: the review needs no second-level
            // freshness, and writing to the database that often is work
            // with no reader.
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async { store.ingestPending() }
            }
            historyIngestTimer = timer
        } catch {
            ClydeLog.general.error("History disabled: \(error.localizedDescription, privacy: .public)")
        }

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
        let widgetHostingView = NSHostingView(
            rootView: widgetRoot.frame(width: widgetSize.width, height: widgetSize.height)
        )
        widgetHostingView.translatesAutoresizingMaskIntoConstraints = true
        widgetHostingView.autoresizingMask = [.width, .height]
        widgetHostingView.frame = NSRect(origin: .zero, size: widgetSize)
        panel.contentView = widgetHostingView
        // Re-assert the panel size AFTER assigning the hosting view —
        // NSHostingView reports its intrinsic content size to the panel
        // and AppKit uses that as the new content size unless we
        // explicitly force it back to widgetSize. Without this, the
        // SwiftUI content can push the panel a few points taller than
        // widgetSize, breaking the WidgetAnchor math (the anchor was
        // set assuming a 40pt-tall panel but the actual panel ends up
        // ~46pt tall and the gap calculation drifts by the difference).
        panel.setFrame(NSRect(origin: initialOrigin, size: widgetSize), display: true)
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
        // Compact is deliberately shorter than the full panel, so these
        // bound the width alone; the height is governed by
        // `applyHeight`, which is the panel's only door for it.
        expandedPanel.minSize = NSSize(width: expandedSize.width, height: 0)
        expandedPanel.maxSize = NSSize(width: expandedSize.width, height: .greatestFiniteMagnitude)

        let expandedRoot = PanelRootView(
            appViewModel: appViewModel,
            sessionViewModel: sessionViewModel
        )
        // Pin the SwiftUI content to the panel's size. AppKit sizes a
        // window to its content view's fitting size, and the session list
        // is a scroll view with no fixed height — so on the SDK the
        // release is built against, that fitting size came out at 1476 and
        // took the window with it. A pinned root has nothing to grow to,
        // whichever SwiftUI is doing the measuring.
        // Width is pinned; height is not, because compact is as tall as
        // the sessions it shows. The protection that replaced pinning is
        // stronger: `ExpandedPanel` refuses every size except the one it
        // was deliberately given, so the content cannot push the window
        // around whatever it computes.
        let expandedHostingView = NSHostingView(
            rootView: expandedRoot.frame(width: expandedSize.width)
        )
        expandedHostingView.translatesAutoresizingMaskIntoConstraints = true
        expandedHostingView.autoresizingMask = [.width, .height]
        expandedHostingView.frame = NSRect(origin: .zero, size: expandedSize)
        expandedPanel.contentView = expandedHostingView
        // Same NSHostingView intrinsic-size workaround as the widget
        // panel — force the expanded panel back to expandedSize after
        // hooking up the hosting view.
        expandedPanel.setFrame(
            NSRect(origin: expandedOrigin, size: expandedSize),
            display: true
        )
        expandedPanel.alphaValue = 0
        // Don't orderFront yet — it stays hidden until the user opens it.

        setupMenuBarIcon()
        appViewModel.start()
        registerGlobalHotKey()
        installExpandedDragMonitor()
        closeStraySettingsWindows()
        // A way to open the panel without System Events. The scenario
        // scripts drove it through Automation, which needs a permission
        // that has been denied mid-session more than once — and a check
        // that cannot run is not a check. Reading a default costs
        // nothing and is never true for a user who has not set it.
        if UserDefaults.standard.bool(forKey: "openPanelAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.appViewModel.isCollapsed = false
            }
        }
        // Same idea for the other windows, so a UI pass can look at all
        // of them without a human clicking through menus.
        if let window = UserDefaults.standard.string(forKey: "openWindowAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                switch window {
                case "settings": self?.openSettings()
                case "review": self?.openReview()
                default: break
                }
            }
        }

        // Onboarding is deferred until the panel has been up for a moment
        // and we can present a non-blocking dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showOnboardingIfNeeded()
        }

        // Window move on the WIDGET → snap to edges and update anchor.
        // Closure-based observer so we can remove it explicitly in
        // `deinit` via the returned token.
        widgetMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] note in
            // The observer is delivered on .main queue, but the callback
            // closure isn't statically @MainActor-isolated. Hop through
            // a Task so we can call the @MainActor method without a
            // concurrency warning. The hop is essentially free since we
            // are already on the main thread.
            Task { @MainActor in
                self?.windowDidMove(note)
            }
        }

        // Settings / diagnostics notifications from the About tab.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .clydeOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showSettingsWindow() }
        }
        // Last line of defence for the panel's geometry. The overrides on
        // ExpandedPanel block the documented paths, but this bug arrived
        // from a layout pass on an SDK that cannot be reproduced here, so
        // the assumption that those are the only paths is exactly the kind
        // of assumption that shipped it. Every resize, by any route, ends
        // in this notification.
        panelResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: expandedPanel, queue: .main
        ) { [weak self] _ in
            // The size to defend is the one the panel was last given,
            // not a constant: compact changes its height deliberately
            // whenever a session starts or ends. Comparing against 420
            // meant this net caught every legitimate compact resize and
            // undid it — the guard working exactly as written, against
            // a door that did not exist when it was written.
            guard let self,
                  self.expandedPanel.frame.size != self.expandedPanel.currentAllowedSize
            else { return }
            ClydeLog.general.error("Panel was resized to \(NSStringFromSize(self.expandedPanel.frame.size), privacy: .public) — restoring")
            self.expandedPanel.setFrame(
                NSRect(origin: self.expandedPanel.frame.origin,
                       size: self.expandedPanel.currentAllowedSize),
                display: true
            )
        }
        rebuildHistoryObserver = NotificationCenter.default.addObserver(
            forName: .clydeRebuildHistory, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildHistoryStore() }
        }
        reviewObserver = NotificationCenter.default.addObserver(
            forName: .clydeOpenReview, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openReview() }
        }
        diagnosticsObserver = NotificationCenter.default.addObserver(
            forName: .clydeCopyDiagnostics, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appViewModel.copyDiagnosticInfoToPasteboard() }
        }

        // Compact is as tall as what it shows, so the window's height
        // follows the mode and the session list. Both go through
        // `applyHeight`, which is the panel's only door for a size
        // change.
        appViewModel.$panelMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.applyPanelHeight(for: mode)
                self?.applyWidgetVisibility(self?.appViewModel.widgetVisible ?? true)
            }
            .store(in: &cancellables)

        sessionViewModel.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.appViewModel.panelMode == .compact else { return }
                self.applyPanelHeight(for: .compact)
            }
            .store(in: &cancellables)

        appViewModel.$permissionRequests
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.appViewModel.panelMode == .compact else { return }
                self.applyPanelHeight(for: .compact)
            }
            .store(in: &cancellables)

        // Every health check is also the moment to ask whether the
        // shortcut's monitor became installable. While a permission is
        // missing that check runs every fifteen seconds, which is how
        // the shortcut starts working shortly after the grant instead
        // of at the next launch.
        appViewModel.$hookHealthIssue
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reregisterHotKeyIfTrustArrived() }
            }
            .store(in: &cancellables)

        // The advisory arrives after launch — the health check is
        // asynchronous — so the height has to be recomputed when it
        // does, not only when the user opens it out. Without this an
        // advisory that was already open at launch rendered into a
        // window sized before anyone knew it existed.
        appViewModel.$hookHealthIssue
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.appViewModel.panelMode == .compact else { return }
                self.applyPanelHeight(for: .compact)
            }
            .store(in: &cancellables)

        appViewModel.$compactAdvisoryExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.appViewModel.panelMode == .compact else { return }
                self.applyPanelHeight(for: .compact)
            }
            .store(in: &cancellables)

        appViewModel.$compactRowCap
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.appViewModel.panelMode == .compact else { return }
                self.applyPanelHeight(for: .compact)
            }
            .store(in: &cancellables)

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

    func applicationWillTerminate(_ notification: Notification) {
        historyIngestTimer?.invalidate()
        // Dispatch async, not a blocking call on the main thread: the spool
        // file is durable, so losing this race at quit costs nothing —
        // anything left unclaimed, or claimed but not yet committed, is
        // picked up by the next launch's ingest, leftover-`.ingesting`
        // sweep included. A synchronous call here would buy freshness at
        // a moment when no window is open to show it, and pay for that
        // with the risk of a hang: a burst of tool calls right before quit
        // could make ingestion slow enough that macOS force-kills the
        // process before it returns. It would also now serialize behind
        // `HistoryStore`'s internal ingest queue, so a synchronous call
        // could additionally block on an ingest already in flight from the
        // timer. Keep this async.
        if let store = historyStore {
            DispatchQueue.global(qos: .utility).async { store.ingestPending() }
        }
    }

    /// Show or hide the WIDGET panel based on the user preference.
    /// The expanded panel is unaffected — even when the widget is
    /// hidden, the user can still open the expanded view from the menu
    /// bar item.
    /// The widget stays, in every mode.
    ///
    /// Compact was going to replace it — two always-on-top surfaces
    /// listing the same sessions seemed like one too many. That read
    /// the widget as a second status display, which it is not: it is
    /// the anchor the panel positions itself against and the handle the
    /// whole thing is dragged by. Taking it away left compact floating
    /// with nothing to attach to, which is exactly how it looked.
    ///
    /// Only the user's own setting decides.
    static func widgetShouldShow(setting: Bool,
                                 mode: AppViewModel.PanelMode,
                                 isCollapsed: Bool) -> Bool {
        setting
    }

    @MainActor private func applyWidgetVisibility(_ setting: Bool) {
        let visible = Self.widgetShouldShow(setting: setting,
                                            mode: appViewModel.panelMode,
                                            isCollapsed: appViewModel.isCollapsed)
        if visible {
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Expanded panel show / hide

    /// Position + animate-in the expanded panel next to the widget.
    @MainActor private func applyPanelHeight(for mode: AppViewModel.PanelMode) {
        let height: CGFloat
        switch mode {
        case .full:
            height = Self.fullPanelHeight
        case .compact:
            let visible = CompactRootView.visible(sessions: sessionViewModel.sessions,
                                                  cap: appViewModel.compactRowCap)
            let request = CompactRootView.expandedRequest(
                from: appViewModel.permissionRequests,
                visiblePIDs: Set(visible.map(\.pid)))
            let advisory = appViewModel.compactAdvisoryExpanded
                && appViewModel.hookHealthIssue?.presentation == .chip
                ? appViewModel.hookHealthIssue : nil
            height = CompactRootView.height(for: visible, expanded: request, advisory: advisory)
        }
        guard expandedPanel.currentAllowedSize.height != height else { return }
        expandedPanel.applyHeight(height)
        // A different shape wants a different place: the panel hangs off
        // the widget, and a height change moves the edge that hangs.
        // Without this, switching modes left the panel where the other
        // mode had put it — visibly detached from the widget it belongs
        // to.
        if !appViewModel.isCollapsed {
            repositionExpandedPanelAgainstWidget()
        }
    }

    /// Put the panel back where its size says it belongs, relative to
    /// the widget. Same maths as opening it, without the animation.
    @MainActor private func repositionExpandedPanelAgainstWidget() {
        widgetAnchor = WidgetAnchor(origin: panel.frame.origin)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let size = expandedPanel.currentAllowedSize
        let origin = widgetAnchor.expandedOrigin(
            for: size,
            in: screen,
            collapsedSize: widgetSize
        )
        expandedPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @MainActor private func showExpandedPanel() {
        // Belt-and-braces: pre-sync the anchor to the live panel
        // origin so any pending snap-debounce or in-flight animation
        // can't leave us using a stale anchor at this critical moment.
        widgetAnchor = WidgetAnchor(origin: panel.frame.origin)
        snapDebounceWork?.cancel()
        snapDebounceWork = nil

        let screen = NSScreen.main?.visibleFrame ?? .zero
        // The size the panel *is*, not the size the full panel would be:
        // compact is a hundred points tall, and positioning it as if it
        // were 420 put it most of a panel away from its widget.
        let currentSize = expandedPanel.currentAllowedSize
        let targetOrigin = widgetAnchor.expandedOrigin(
            for: currentSize,
            in: screen,
            collapsedSize: widgetSize
        )

        let widgetBottomY = widgetAnchor.origin.y
        let expandedTopY = targetOrigin.y + currentSize.height

        // Direction-aware slide. The panel always starts FURTHER from
        // the widget than its final position and slides toward it,
        // never overlapping the widget area.
        let isDropDown = expandedTopY < widgetBottomY
        let slideDistance: CGFloat = 28
        let startOrigin: NSPoint = isDropDown
            ? NSPoint(x: targetOrigin.x, y: targetOrigin.y - slideDistance)
            : NSPoint(x: targetOrigin.x, y: targetOrigin.y + slideDistance)
        let targetFrame = NSRect(origin: targetOrigin, size: currentSize)
        let startFrame = NSRect(origin: startOrigin, size: currentSize)

        // Place the panel at the start frame BEFORE making it visible
        // and force a display tick so the window server actually has a
        // start state to animate FROM. Without this, NSWindow's
        // animator can collapse the start + animation into a single
        // render and only the final frame is shown.
        expandedPanel.alphaValue = 0
        expandedPanel.setFrame(startFrame, display: true)
        expandedPanel.orderFront(nil)
        expandedPanel.makeKeyAndOrderFront(nil)

        // Defer the animation to the next runloop tick so the window
        // is fully realised on screen at the start frame before we
        // start animating toward the target.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.36
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.0, 0.32, 1.0)
                ctx.allowsImplicitAnimation = true
                self.expandedPanel.animator().setFrame(targetFrame, display: true)
                self.expandedPanel.animator().alphaValue = 1
            })
        }
    }

    /// Animate the expanded panel out and order it offscreen. Slides
    /// the panel further AWAY from the widget while fading — mirror
    /// of the opening animation.
    @MainActor private func hideExpandedPanel() {
        let currentOrigin = expandedPanel.frame.origin
        let panelSize = expandedPanel.currentAllowedSize
        let isDropDown = currentOrigin.y + panelSize.height < widgetAnchor.origin.y + widgetSize.height
        let slideDistance: CGFloat = 28
        let endOrigin: NSPoint = isDropDown
            ? NSPoint(x: currentOrigin.x, y: currentOrigin.y - slideDistance)
            : NSPoint(x: currentOrigin.x, y: currentOrigin.y + slideDistance)
        let endFrame = NSRect(origin: endOrigin, size: panelSize)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            expandedPanel.animator().setFrame(endFrame, display: true)
            expandedPanel.animator().alphaValue = 0
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

        // Refresh the accessibility value alongside the icon so VoiceOver
        // always announces the live count summary on focus.
        button.setAccessibilityValue(currentStatusItemValue())

        // Snooze takes priority: show the template Clyde icon + "💤 Xm"
        // so the user clearly sees the app is muted.
        if appViewModel.notificationService.isSnoozed {
            let remaining = appViewModel.notificationService.snoozeRemainingMinutes ?? 0
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
            let remaining = notifications.snoozeRemainingMinutes ?? 0
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

        let reviewItem = NSMenuItem(title: "Session review…", action: #selector(openReview), keyEquivalent: "")
        reviewItem.target = self
        // A menu item that silently does nothing is the same defect as a
        // button that does: when the history store failed to open, the
        // panel hides its route into the review, and this one greys out
        // and says why instead of swallowing the click. Settings carries
        // the same message in full.
        if historyStore == nil {
            reviewItem.isEnabled = false
            reviewItem.toolTip = "History tracking is unavailable — see Settings › Advanced."
            menu.autoenablesItems = false
        }
        menu.addItem(reviewItem)

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

    @MainActor @objc func openSettings() {
        showSettingsWindow()
    }

    // MARK: - Review Window

    private var reviewWindow: NSWindow?
    private var reviewWindowDelegate: SettingsWindowDelegate?

    /// Recover from a database Clyde could not read. Best-effort, like
    /// every other history path: a failed rebuild leaves tracking off and
    /// says so, and session tracking is untouched either way.
    @MainActor private func rebuildHistoryStore() {
        do {
            let store = try HistoryStore.rebuild(directory: AppPaths.historyDir)
            historyStore = store
            appViewModel.historyAvailable = true
            DispatchQueue.global(qos: .utility).async { store.ingestPending() }
            ClydeLog.general.info("History: rebuilt the store on request")
        } catch {
            ClydeLog.general.error("History: rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor @objc func openReview() {
        guard let store = historyStore else {
            ClydeLog.general.info("Review requested but history is unavailable")
            return
        }
        if let existing = reviewWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: ReviewView(stats: HistoryStats(store: store)))
        let window = NSWindow(contentViewController: controller)
        window.title = "Session review"
        // Same chrome as the welcome window: a system titlebar is what made
        // this read as a form from another app rather than as Clyde. The
        // view draws its own header, so the bar only needs to carry the
        // traffic lights.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        // The window opens at a size worth reading and can be pulled
        // smaller from there. It used to take its height from the view's
        // own minimum, so lowering that minimum — which is what let the
        // content scroll instead of being clipped — silently shrank the
        // window it opened at.
        window.setContentSize(NSSize(width: 620, height: 720))
        window.center()

        // Unlike the settings window, the review window doesn't need to
        // flip the activation policy — `NSApp.activate(ignoringOtherApps:)`
        // alone is enough to give it key focus as an accessory app. On
        // close, drop the reference so the hosting controller and its view
        // graph (and the stale numbers it's holding) are released rather
        // than sitting hidden for the rest of the process.
        let delegate = SettingsWindowDelegate { [weak self] in
            self?.reviewWindow = nil
            self?.reviewWindowDelegate = nil
        }
        window.delegate = delegate
        reviewWindowDelegate = delegate

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reviewWindow = window
    }

    // MARK: - Settings Window

    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?

    @MainActor private func showSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            NSApp.setActivationPolicy(.regular)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appViewModel: appViewModel, historyStore: historyStore)
            .environment(\.colorScheme, .dark)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clyde Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        window.isMovableByWindowBackground = false
        window.setContentSize(NSSize(width: 600, height: 500))
        window.minSize = NSSize(width: 500, height: 400)
        window.center()

        let delegate = SettingsWindowDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.settingsWindowDelegate = nil
            NSApp.setActivationPolicy(.accessory)
        }
        window.delegate = delegate
        settingsWindowDelegate = delegate

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    /// Reverts the activation policy when the settings window closes so
    /// Clyde goes back to being a menu-bar-only (LSUIElement) app.
    private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }

    /// SwiftUI's `Settings { EmptyView() }` scene in ClydeApp.swift can be
    /// restored by macOS on launch if it was visible when Clyde last quit,
    /// appearing as an empty "Settings" window. We manage Settings via our
    /// own NSWindow, so any restored SwiftUI scene window is a ghost —
    /// close it immediately. Deferred to the next runloop so SwiftUI has
    /// a chance to instantiate any restored windows first.
    @MainActor private func closeStraySettingsWindows() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows {
                // Skip our own settings window (not yet created at launch, but
                // guarded anyway) and any panels / onboarding.
                if window === self.settingsWindow { continue }
                if window === self.panel || window === self.expandedPanel { continue }
                if window === self.onboardingWindow { continue }
                // SwiftUI's Settings scene window has "Settings" in its title
                // (localized as "Ustawienia" etc). Match on identifier prefix
                // which is stable across locales: SwiftUI uses identifiers
                // like "com_apple_SwiftUI_Settings_window".
                let identifier = window.identifier?.rawValue ?? ""
                if identifier.contains("Settings") || identifier.contains("SwiftUI") {
                    ClydeLog.general.info("Closing stray SwiftUI Settings window: \(identifier, privacy: .public)")
                    window.close()
                }
            }
        }
    }

    // MARK: - Onboarding

    static let onboardingShownKey = "onboardingShown"

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
        // Update the anchor inline so the expanded panel can use a
        // current value even if the user clicks expand before the
        // debounced snap fires. Without this, anchor stays at the
        // pre-drag value for ~0.45s after release and any expand
        // action in that window positions the panel from the wrong
        // origin.
        widgetAnchor = WidgetAnchor(origin: panel.frame.origin)

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
    private var hotKeyTrust = HotKeyTrustWatcher()

    @MainActor private func registerGlobalHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            guard Self.isToggleShortcut(event) else {
                // Any modified press of C, not just one that already
                // carries ⌃⌘. Narrowing this to "control and command
                // are both held" assumes the modifiers arrive intact,
                // which is the thing under suspicion: a keyboard
                // remapper that turns right-command into right-option
                // produces silence here rather than evidence. Only the
                // key code and modifiers are recorded, never what was
                // typed.
                let modified = !event.modifierFlags
                    .intersection([.command, .control, .option, .shift])
                    .isEmpty
                if event.keyCode == 8 && modified {
                    let flags = event.modifierFlags
                    ClydeLog.ui.debug("""
                        Hotkey near miss: keyCode=\(event.keyCode) \
                        cmd=\(flags.contains(.command)) ctrl=\(flags.contains(.control)) \
                        opt=\(flags.contains(.option)) shift=\(flags.contains(.shift)) \
                        caps=\(flags.contains(.capsLock)) fn=\(flags.contains(.function))
                        """)
                }
                return
            }
            ClydeLog.ui.info("Global shortcut fired")
            DispatchQueue.main.async {
                self.toggleFromHotkey()
            }
        }

        // Ask before installing. The pane does not create a
        // row on its own — the row exists because the application
        // asked, and `addGlobalMonitorForEvents` asks for nothing, it
        // just silently stops receiving events. Without these calls a
        // user whose entry is missing or stale has nothing to switch on
        // and no prompt offering to put one back. Both are silent once
        // a decision exists, so they prompt on first run only, which is
        // the moment the shortcut is being installed and needs them.
        let trusted = HookInstaller.isAccessibilityTrusted()
        if !trusted { ShortcutPermission.requestAccessibility() }

        // A monitor installed without trust never starts working when
        // the trust arrives — it has to be built again. Remember which
        // it was, so the recheck below knows.
        hotKeyTrust.recordInstall(trusted: trusted)
        globalHotKeyMonitor.map(NSEvent.removeMonitor)
        globalHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        // Whether the monitor exists and whether macOS trusts us are
        // different questions, and a dead shortcut looks identical
        // either way. Say both out loud at startup.
        // Both permissions, because the shortcut needs both and a dead
        // one looks identical whichever is missing. Input monitoring is
        // the one that was empty while everything else looked fine.
        ClydeLog.ui.info("""
            Global hotkey monitor installed=\(self.globalHotKeyMonitor != nil) \
            accessibilityTrusted=\(HookInstaller.isAccessibilityTrusted()) \
            inputMonitoringTrusted=\(HookInstaller.isInputMonitoringTrusted())
            """)
        localHotKeyMonitor.map(NSEvent.removeMonitor)
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    /// Rebuild the shortcut's monitor if the permission arrived after
    /// it was installed.
    ///
    /// Granting accessibility in System Settings touches nothing Clyde
    /// watches, and the monitor it already holds stays deaf. Until this
    /// existed the cure was restarting the app — which the user has no
    /// way to know, and which made a working permission look broken.
    @MainActor func reregisterHotKeyIfTrustArrived() {
        guard hotKeyTrust.needsReinstall(trustedNow: HookInstaller.isAccessibilityTrusted())
        else { return }
        ClydeLog.ui.info("Accessibility arrived after launch — rebuilding the shortcut monitor")
        registerGlobalHotKey()
    }

    /// ⌃⌘C, matched on the physical key and the modifiers that carry
    /// meaning.
    ///
    /// Reported dead on two machines, and the old comparison has two
    /// ways of producing exactly that. It required the modifier flags to
    /// equal [.control, .command], but `deviceIndependentFlagsMask`
    /// carries Caps Lock and `.function` too, so the shortcut stopped
    /// working whenever Caps Lock happened to be on. And it read the
    /// letter from `charactersIgnoringModifiers`, which with Control
    /// held can arrive as U+0003 rather than "c" — a keyboard where that
    /// happens is a keyboard where the shortcut never works at all.
    ///
    /// keyCode 8 is C on every layout that has one, and the character is
    /// accepted in either spelling as a fallback for layouts that report
    /// a different code.
    static func isToggleShortcut(_ event: NSEvent) -> Bool {
        // Caps Lock and .function say nothing about intent. Everything
        // else does: ⌃⌘⇧C is a different shortcut, and may be bound
        // elsewhere.
        let meaningful: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let active = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection(meaningful)
        guard active == [.control, .command] else { return false }

        if event.keyCode == 8 { return true }
        let typed = event.charactersIgnoringModifiers?.lowercased()
        return typed == "c" || typed == "\u{03}"
    }

    @MainActor private func toggleFromHotkey() {
        appViewModel.toggleExpanded()
        if !appViewModel.isCollapsed {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor func snapToNearestEdge() {
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
            // Snap instantly — no animation. Animating left a 0.3s
            // race window where the panel was mid-flight, the user
            // could click expand and end up with a stale anchor or a
            // mid-animation frame as the source of the expanded
            // position calculation. The visual jump is small (snap
            // distance is at most snapThreshold + snapMargin = ~48pt)
            // and immediate snap is the standard menu-bar app pattern.
            isProgrammaticMove = true
            panel.setFrameOrigin(snapped)
            widgetAnchor = WidgetAnchor(origin: snapped)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isProgrammaticMove = false
            }
        } else {
            // No snap needed — commit current frame as the anchor.
            widgetAnchor = WidgetAnchor(origin: frame.origin)
        }
    }

    // MARK: - Expanded panel drag

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
                self.expandedDragState = nil
                return event

            default:
                return event
            }
        }
    }

    // MARK: - Accessibility

    /// Plain-language summary of the menu-bar status item's current state,
    /// used as the VoiceOver value so users hear e.g. "2 working, 1 ready"
    /// alongside the static "Clyde" label and `.button` role. Delegates to
    /// `AppViewModel.widgetAccessibilityLabel` (the shared source of truth
    /// the widget panel uses) and strips the leading "Clyde, " prefix
    /// because the status item's own accessibility label already says
    /// "Clyde — Claude Code session monitor".
    @MainActor
    private func currentStatusItemValue() -> String {
        let label = appViewModel.widgetAccessibilityLabel
        return label.replacingOccurrences(of: "Clyde, ", with: "")
    }
}

