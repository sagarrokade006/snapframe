import AppKit
import SnapframeCore

/// Shared state of one capture overlay across every display.
@MainActor
final class OverlaySession {
    enum Mode: String, CaseIterable {
        case area, window, fullscreen

        var title: String {
            switch self {
            case .area: return "Area"
            case .window: return "Window"
            case .fullscreen: return "Fullscreen"
            }
        }

        var key: String {
            switch self {
            case .area: return "A"
            case .window: return "W"
            case .fullscreen: return "F"
            }
        }
    }

    enum Target {
        case area(DisplaySnapshot, CGRect)
        case window(VisibleWindow)
        case fullscreen(DisplaySnapshot)
    }

    struct Outcome {
        let target: Target
        let timer: Int
        let copyOnly: Bool
        let includeWallpaper: Bool
        let mode: Mode
    }

    private enum Gesture {
        case none
        case drawing(anchor: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(SelectionHandle)
    }

    static let timerSteps = [0, 3, 5, 10]
    private static let snapThreshold: CGFloat = 6
    private static let minimumSelection: CGFloat = 4

    let environment: CaptureEnvironment
    let freeze: Bool
    let adjustBeforeCapture: Bool
    var onFinish: ((Outcome?) -> Void)?

    private(set) var mode: Mode
    private(set) var timer: Int
    private(set) var selection: CGRect?
    private(set) var selectionDisplay: CGDirectDisplayID?
    private(set) var cursorDisplay: CGDirectDisplayID?
    private(set) var cursorPoint: CGPoint?
    private(set) var hoveredWindow: VisibleWindow?
    private(set) var isAdjusting = false

    private var gesture = Gesture.none
    private var panels: [OverlayPanel] = []
    private var finished = false

    init(environment: CaptureEnvironment, mode: Mode, timer: Int, freeze: Bool, adjustBeforeCapture: Bool) {
        self.environment = environment
        self.mode = mode
        self.timer = timer
        self.freeze = freeze
        self.adjustBeforeCapture = adjustBeforeCapture
    }

    var isDrawing: Bool {
        if case .drawing = gesture { return true }
        return false
    }

    func present() {
        let location = NSEvent.mouseLocation
        for snapshot in environment.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == snapshot.displayID }) else { continue }
            let panel = OverlayPanel(screen: screen)
            panel.contentView = SelectionOverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                session: self,
                snapshot: snapshot
            )
            panels.append(panel)

            if screen.frame.contains(location) {
                cursorDisplay = snapshot.displayID
                cursorPoint = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)
            }
        }

        for panel in panels { panel.orderFrontRegardless() }
        let keyPanel = panels.first { panel in
            (panel.contentView as? SelectionOverlayView)?.snapshot.displayID == cursorDisplay
        } ?? panels.first
        keyPanel?.makeKey()
        keyPanel?.makeFirstResponder(keyPanel?.contentView)
        NSCursor.crosshair.set()
        if let cursorPoint, let cursorDisplay,
           let snapshot = environment.displays.first(where: { $0.displayID == cursorDisplay }) {
            updateHover(point: cursorPoint, snapshot: snapshot)
        }
        invalidate()
    }

    private func invalidate() {
        for panel in panels { panel.contentView?.needsDisplay = true }
    }

    // MARK: Mode bar actions

    func setMode(_ newMode: Mode) {
        mode = newMode
        clearSelection()
        if let cursorPoint, let snapshot = cursorSnapshot {
            updateHover(point: cursorPoint, snapshot: snapshot)
        }
        invalidate()
    }

    func cycleTimer() {
        let index = Self.timerSteps.firstIndex(of: timer) ?? 0
        timer = Self.timerSteps[(index + 1) % Self.timerSteps.count]
        invalidate()
    }

    func cancel() {
        finish(nil)
    }

    private var cursorSnapshot: DisplaySnapshot? {
        environment.displays.first { $0.displayID == cursorDisplay }
    }

    private func clearSelection() {
        selection = nil
        selectionDisplay = nil
        isAdjusting = false
        gesture = .none
    }

    // MARK: Pointer

    func mouseMoved(to point: CGPoint, on snapshot: DisplaySnapshot) {
        cursorDisplay = snapshot.displayID
        cursorPoint = point
        updateHover(point: point, snapshot: snapshot)
        invalidate()
    }

    private func updateHover(point: CGPoint, snapshot: DisplaySnapshot) {
        guard mode == .window else {
            hoveredWindow = nil
            return
        }
        let global = CGPoint(x: snapshot.frame.minX + point.x, y: snapshot.frame.minY + point.y)
        hoveredWindow = environment.windows.first { $0.frame.contains(global) }
    }

    func mouseDown(at point: CGPoint, on snapshot: DisplaySnapshot) {
        switch mode {
        case .window:
            updateHover(point: point, snapshot: snapshot)
            if let hoveredWindow { finish(target: .window(hoveredWindow)) }
        case .fullscreen:
            finish(target: .fullscreen(snapshot))
        case .area:
            if isAdjusting, selectionDisplay == snapshot.displayID, let selection {
                if let handle = SelectionGeometry.handle(at: point, in: selection, radius: 9) {
                    gesture = .resizing(handle)
                    return
                }
                if selection.contains(point) {
                    gesture = .moving(grab: point, original: selection)
                    return
                }
            }
            isAdjusting = false
            selection = nil
            selectionDisplay = snapshot.displayID
            gesture = .drawing(anchor: snappedPoint(point, on: snapshot))
            invalidate()
        }
    }

    func mouseDragged(to point: CGPoint, on snapshot: DisplaySnapshot) {
        cursorDisplay = snapshot.displayID
        cursorPoint = SelectionGeometry.clamp(point, to: snapshot.localBounds)
        let flags = NSEvent.modifierFlags

        switch gesture {
        case .none:
            return
        case .drawing(let anchor):
            selection = SelectionGeometry.rect(
                anchor: anchor,
                current: snappedPoint(point, on: snapshot),
                square: flags.contains(.shift),
                bounds: snapshot.localBounds
            )
        case .moving(let grab, let original):
            selection = SelectionGeometry.moved(
                original,
                by: CGVector(dx: point.x - grab.x, dy: point.y - grab.y),
                bounds: snapshot.localBounds
            )
        case .resizing(let handle):
            if let selection {
                self.selection = SelectionGeometry.resized(
                    selection, handle: handle, to: point,
                    minSize: Self.minimumSelection, bounds: snapshot.localBounds
                )
            }
        }
        invalidate()
    }

    func mouseUp(on snapshot: DisplaySnapshot) {
        defer { gesture = .none }
        guard case .drawing = gesture else { return }

        guard let selection, selection.width >= Self.minimumSelection, selection.height >= Self.minimumSelection else {
            clearSelection()
            invalidate()
            return
        }
        if adjustBeforeCapture {
            isAdjusting = true
            invalidate()
        } else {
            finish(target: .area(snapshot, selection))
        }
    }

    /// Holding Command turns snapping off for free-form selections.
    private func snappedPoint(_ point: CGPoint, on snapshot: DisplaySnapshot) -> CGPoint {
        guard !NSEvent.modifierFlags.contains(.command) else { return point }
        let frames = environment.windows.map { $0.frame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY) }
        return SelectionGeometry.snapped(
            point,
            xs: frames.flatMap { [$0.minX, $0.maxX] },
            ys: frames.flatMap { [$0.minY, $0.maxY] },
            threshold: Self.snapThreshold
        )
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: confirm()
        case 0: setMode(.area)
        case 13: setMode(.window)
        case 3: setMode(.fullscreen)
        case 17: cycleTimer()
        case 123: nudge(dx: -1, dy: 0, event)
        case 124: nudge(dx: 1, dy: 0, event)
        case 125: nudge(dx: 0, dy: 1, event)
        case 126: nudge(dx: 0, dy: -1, event)
        default: break
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat, _ event: NSEvent) {
        guard isAdjusting, let selection,
              let snapshot = environment.displays.first(where: { $0.displayID == selectionDisplay })
        else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        self.selection = SelectionGeometry.moved(
            selection, by: CGVector(dx: dx * step, dy: dy * step), bounds: snapshot.localBounds
        )
        invalidate()
    }

    private func confirm() {
        switch mode {
        case .area:
            if isAdjusting, let selection,
               let snapshot = environment.displays.first(where: { $0.displayID == selectionDisplay }) {
                finish(target: .area(snapshot, selection))
            }
        case .window:
            if let hoveredWindow { finish(target: .window(hoveredWindow)) }
        case .fullscreen:
            if let snapshot = cursorSnapshot { finish(target: .fullscreen(snapshot)) }
        }
    }

    // MARK: Finish

    private func finish(target: Target) {
        let flags = NSEvent.modifierFlags
        finish(Outcome(
            target: target,
            timer: timer,
            copyOnly: flags.contains(.control),
            includeWallpaper: flags.contains(.shift),
            mode: mode
        ))
    }

    private func finish(_ outcome: Outcome?) {
        guard !finished else { return }
        finished = true
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        onFinish?(outcome)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// A non-activating panel keeps the app you are capturing frontmost, while still receiving keys.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
