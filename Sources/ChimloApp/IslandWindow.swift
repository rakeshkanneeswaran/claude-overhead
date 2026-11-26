import AppKit
import ChimloCore
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    var interactiveFrame: () -> NSRect = { .zero }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The camera housing is inside AppKit's protected safe area. Claude Overhead is
        // intentionally anchored there, so the normal menu-bar constraint must
        // not push this borderless panel below the hardware.
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp
            || event.type == .rightMouseDown || event.type == .rightMouseUp,
           !interactiveFrame().contains(event.locationInWindow) {
            ignoresMouseEvents = true
            repostMouseEvent(event)
            return
        }

        super.sendEvent(event)
    }

    private func repostMouseEvent(_ event: NSEvent) {
        let type: CGEventType
        let button: CGMouseButton
        switch event.type {
        case .leftMouseDown:
            type = .leftMouseDown
            button = .left
        case .leftMouseUp:
            type = .leftMouseUp
            button = .left
        case .rightMouseDown:
            type = .rightMouseDown
            button = .right
        case .rightMouseUp:
            type = .rightMouseUp
            button = .right
        default:
            return
        }

        let location = event.cgEvent?.location ?? NSEvent.mouseLocation
        DispatchQueue.main.async {
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: button
            )?.post(tap: .cghidEventTap)
        }
    }
}

private extension CGRect {
    /// A cursor pushed against the top of the screen reports y == maxY, and
    /// `contains` leaves maxY out, so the island read it as "pointer left" and
    /// collapsed while the pointer was still on it. One extra point at the top
    /// takes that row in; nothing can sit above the screen's top edge anyway.
    var includingTopEdge: CGRect {
        CGRect(x: minX, y: minY, width: width, height: height + 1)
    }
}

private final class FullBleedHostingView<Content: View>: NSHostingView<Content> {
    var hitTestFrame: () -> NSRect = { .zero }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestFrame().contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class IslandWindowCoordinator {
    private let model: ApplicationModel
    private let github: GitHubModel
    private let openSettings: () -> Void
    private let panel: IslandPanel
    private var cancellables: Set<AnyCancellable> = []
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerInsideIntendedFrame = false
    /// The display the notch is on. `chooseScreen` is the only place that
    /// picks it, and the panel's frame and pointer hit-testing both read this
    /// one value, so the notch is always tested where it is drawn.
    private var screen: NSScreen?

    init(model: ApplicationModel, github: GitHubModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.github = github
        self.openSettings = openSettings
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        screen = chooseScreen()
        refreshLayout()
        configurePanel()
        observeChanges()
        updateHostFrame()
    }

    func show() {
        updateHostFrame()
        refreshPointerPresence()
        panel.orderFrontRegardless()
    }

    func stop() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
        cancellables.removeAll()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Configure floating behavior before restoring the status-bar level.
        // AppKit otherwise treats this as a movable desktop window during a
        // Space transition and can carry/scale it with the outgoing desktop.
        panel.isFloatingPanel = true
        panel.isMovable = false
        // Keep Claude Overhead above WindowServer's menu-bar layer so the visible wings
        // receive real pointer events. isFloatingPanel resets this to 3, so the
        // explicit level assignment must remain after it.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        // An alert or save panel of ours must never stop the owner from
        // answering a request in the notch.
        panel.worksWhenModal = true
        panel.ignoresMouseEvents = true
        let hostingView = FullBleedHostingView(
            rootView: IslandRootView(model: model, github: github, openSettings: openSettings)
        )
        // AppKit owns one stable host window while SwiftUI animates the visible
        // island inside it. A Space switch can no longer capture a partially
        // resized WindowServer frame.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.hitTestFrame = { [weak self] in
            self?.interactiveFrameInPanel ?? .zero
        }
        panel.interactiveFrame = { [weak self] in
            self?.interactiveFrameInPanel ?? .zero
        }
        panel.contentView = hostingView
        installPointerMonitoring()
    }

    private func installPointerMonitoring() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]

        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event)
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event)
            }
            return event
        }
    }

    private func handlePointerEvent(_ event: NSEvent) {
        if model.preferredDisplay == .displayWithPointer, chooseScreen() != screen {
            // The pointer crossed to another display: the notch follows it.
            updateHostFrame()
        }
        refreshPointerPresence()
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !intendedPanelFrameContainsPointer {
                model.collapsePanelFromOutsideClick()
            }
        default:
            break
        }
    }

    private func refreshPointerPresence() {
        let inside = intendedPanelFrameContainsPointer
        if inside != pointerInsideIntendedFrame {
            pointerInsideIntendedFrame = inside
            model.pointerPresenceChanged(inside)
        }
        updateMouseEventRouting()
    }

    private func updateMouseEventRouting() {
        panel.ignoresMouseEvents = !pointerInsideIntendedFrame
    }

    private var interactiveFrameInPanel: CGRect {
        let size = model.panelSize
        return CGRect(
            x: (panel.frame.width - size.width) / 2,
            y: panel.frame.height - size.height,
            width: size.width,
            height: size.height
        ).includingTopEdge
    }

    private var intendedPanelFrameContainsPointer: Bool {
        guard let screen else { return false }
        let intendedFrame = IslandGeometry.frame(
            for: model.panelSize,
            on: screen,
            hasCameraHousing: model.islandLayout.hasCameraHousing,
            atScreenTop: anchorsAtScreenTop
        )
        return intendedFrame.includingTopEdge.contains(NSEvent.mouseLocation)
    }

    /// A hidden notch on a display without a camera housing is an invisible
    /// target where a notch would be: the top of the screen, not under the
    /// menu bar where the pill normally sits.
    private var anchorsAtScreenTop: Bool {
        !model.islandLayout.hasCameraHousing && model.isNotchConcealed
    }

    private func observeChanges() {
        // Hiding or showing the notch (the eye button, or a request that
        // shows a hidden notch for a moment) changes where it may be clicked.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .compactMap { [weak self] in self?.model.isNotchConcealed }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateHostFrame()
                self?.refreshPointerPresence()
            }
            .store(in: &cancellables)

        model.$islandLayout
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHostFrame() }
            .store(in: &cancellables)

        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.activeSpaceDidChangeNotification
            ),
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshPointerPresence()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateHostFrame()
            }
            .store(in: &cancellables)

        // "Show the notch on" in Settings.
        model.$preferredDisplay
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateHostFrame()
                self?.refreshPointerPresence()
            }
            .store(in: &cancellables)

        // The island changes size without the pointer moving: a request
        // opens it, a card leaves. Look again at where the pointer is, so
        // the panel takes clicks exactly where it is drawn and a first click
        // never falls through to the app underneath.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, panel.isVisible else { return }
                // A closed notch opens on a real pointer move, never because
                // it grew under a pointer at rest.
                if model.panelMode == .compact, !pointerInsideIntendedFrame { return }
                refreshPointerPresence()
            }
            .store(in: &cancellables)

        // The panel takes the keyboard only for the "Other…" answer field
        // (or a click on selectable text). Once that field is gone, or the
        // notch closes, the keyboard goes back, so later keystrokes reach the
        // app the owner is looking at and not a card in the notch.
        model.$sessionQuestions
            .map { $0.values.contains(where: \.isEnteringCustomAnswer) }
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.releaseKeyboard() }
            .store(in: &cancellables)
        model.$panelMode
            .removeDuplicates()
            .filter { $0 == .compact }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.releaseKeyboard() }
            .store(in: &cancellables)
    }

    /// Gives up key status, which a non-activating panel otherwise keeps
    /// until the owner clicks another window. Taking the panel off screen and
    /// straight back is how AppKit hands the keyboard to the window that had
    /// it before.
    private func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func updateHostFrame() {
        screen = chooseScreen()
        guard let screen else { return }
        refreshLayout()
        let target = IslandGeometry.hostFrame(
            on: screen,
            hasCameraHousing: model.islandLayout.hasCameraHousing,
            atScreenTop: anchorsAtScreenTop
        )
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
    }

    /// The display the owner chose in Settings (`NotchScreenChoice`): by
    /// default the one with a notch, else the primary display.
    private func chooseScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let index = NotchScreenChoice.index(
            preference: model.preferredDisplay,
            screens: screens.map {
                NotchScreenChoice.Screen(frame: $0.frame, hasNotch: $0.safeAreaInsets.top > 0)
            },
            pointer: NSEvent.mouseLocation
        )
        return index.map { screens[$0] }
    }

    private func refreshLayout() {
        guard let screen else { return }
        let leftArea = screen.auxiliaryTopLeftArea
        let rightArea = screen.auxiliaryTopRightArea
        let safeTopInset = max(
            screen.safeAreaInsets.top,
            leftArea?.height ?? 0,
            rightArea?.height ?? 0
        )
        model.updateDisplayMetrics(
            IslandDisplayMetrics(
                screenWidth: screen.frame.width,
                screenHeight: screen.frame.height,
                visibleTop: screen.visibleFrame.maxY,
                safeTopInset: safeTopInset,
                cameraHousingLeftEdge: leftArea?.maxX,
                cameraHousingRightEdge: rightArea?.minX,
                menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY)
            )
        )
    }
}

private enum IslandGeometry {
    private static let hostHeight: CGFloat = 750

    static func hostFrame(on screen: NSScreen, hasCameraHousing: Bool, atScreenTop: Bool) -> CGRect {
        frame(
            for: CGSize(width: screen.frame.width, height: min(hostHeight, screen.frame.height)),
            on: screen,
            hasCameraHousing: hasCameraHousing,
            atScreenTop: atScreenTop
        )
    }

    static func frame(for size: CGSize, on screen: NSScreen, hasCameraHousing: Bool, atScreenTop: Bool) -> CGRect {
        let top = hasCameraHousing || atScreenTop ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        let cameraCenter: CGFloat?
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            cameraCenter = (leftArea.maxX + rightArea.minX) / 2
        } else {
            cameraCenter = nil
        }
        let x = (cameraCenter ?? screen.frame.midX) - size.width / 2
        let proposed = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        return screen.backingAlignedRect(proposed, options: [.alignAllEdgesNearest])
    }
}

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let model: ApplicationModel
    private var window: NSWindow?

    init(model: ApplicationModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 680, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Claude Overhead"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.minSize = NSSize(width: 640, height: 440)
            window.tabbingMode = .disallowed
            window.setFrameAutosaveName("ChimloSettingsWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ChimloSettingsView(model: model))
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
