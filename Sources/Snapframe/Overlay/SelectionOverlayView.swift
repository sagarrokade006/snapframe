import AppKit
import SnapframeCore

enum Palette {
    static let accent = NSColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 1)
    static let panel = NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.227, green: 0.231, blue: 0.251, alpha: 1)
    static let text = NSColor(srgbRed: 0.949, green: 0.945, blue: 0.933, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.769, green: 0.773, blue: 0.796, alpha: 1)
    static let onAccent = NSColor(srgbRed: 0.09, green: 0.094, blue: 0.102, alpha: 1)
    static let dim = NSColor(srgbRed: 0.04, green: 0.043, blue: 0.051, alpha: 0.55)
}

/// One per display. Coordinates are display-local points with y pointing down.
final class SelectionOverlayView: NSView {
    private enum BarAction {
        case mode(OverlaySession.Mode)
        case timer
        case close
    }

    private struct BarItem {
        let action: BarAction
        let label: String
        let key: String?
        let selected: Bool
        let rect: CGRect
    }

    let session: OverlaySession
    let snapshot: DisplaySnapshot

    private let backdrop: NSImage
    private var trackingArea: NSTrackingArea?

    private static let loupeSize: CGFloat = 124
    private static let loupeSamples = 13

    init(frame: CGRect, session: OverlaySession, snapshot: DisplaySnapshot) {
        self.session = session
        self.snapshot = snapshot
        self.backdrop = NSImage(cgImage: snapshot.image, size: frame.size)
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private var showsBar: Bool { session.cursorDisplay == snapshot.displayID && !session.isDrawing }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        let overBar = showsBar && barItems.contains { $0.rect.contains(point) }
        (overBar ? NSCursor.arrow : NSCursor.crosshair).set()
        session.mouseMoved(to: point, on: snapshot)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        window?.makeKey()
        if showsBar, let item = barItems.first(where: { $0.rect.contains(point) }) {
            switch item.action {
            case .mode(let mode): session.setMode(mode)
            case .timer: session.cycleTimer()
            case .close: session.cancel()
            }
            return
        }
        session.mouseDown(at: point, on: snapshot)
    }

    override func mouseDragged(with event: NSEvent) {
        session.mouseDragged(to: location(of: event), on: snapshot)
    }

    override func mouseUp(with event: NSEvent) {
        session.mouseUp(on: snapshot)
    }

    override func keyDown(with event: NSEvent) {
        session.keyDown(event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        if session.freeze {
            backdrop.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        switch session.mode {
        case .area: drawAreaMode()
        case .window: drawWindowMode()
        case .fullscreen: drawFullscreenMode()
        }

        if showsBar { drawBar() }
    }

    private func fillDim(cutout: CGRect?, cornerRadius: CGFloat = 0) {
        let path = NSBezierPath(rect: bounds)
        if let cutout {
            path.append(NSBezierPath(roundedRect: cutout, xRadius: cornerRadius, yRadius: cornerRadius))
            path.windingRule = .evenOdd
        }
        Palette.dim.setFill()
        path.fill()
    }

    private func drawAreaMode() {
        let isSelectionHere = session.selectionDisplay == snapshot.displayID
        let selection = isSelectionHere ? session.selection : nil
        fillDim(cutout: selection)

        if let selection {
            Palette.accent.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1.5
            outline.stroke()
            drawHandles(selection)
            drawSizeBadge(selection)
            if session.isAdjusting { drawAdjustHint(selection) }
        }

        guard session.cursorDisplay == snapshot.displayID, let cursor = session.cursorPoint,
              !session.isAdjusting
        else { return }

        if selection == nil, !barItems.contains(where: { $0.rect.contains(cursor) }) {
            drawCrosshair(at: cursor)
        }
        drawLoupe(at: cursor)
    }

    private func drawHandles(_ rect: CGRect) {
        let handles: [SelectionHandle] = session.isAdjusting
            ? SelectionHandle.allCases
            : [.topLeft, .topRight, .bottomLeft, .bottomRight]
        Palette.accent.setFill()
        for handle in handles {
            let center = SelectionGeometry.point(of: handle, in: rect)
            CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8).fill()
        }
    }

    private func drawSizeBadge(_ rect: CGRect) {
        let text = "\(Int((rect.width * snapshot.scale).rounded())) × \(Int((rect.height * snapshot.scale).rounded()))"
        let hasRoomAbove = rect.minY >= 32
        let origin = CGPoint(x: rect.minX, y: hasRoomAbove ? rect.minY - 30 : rect.minY + 8)
        drawPill(text: text, at: origin, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    }

    private func drawAdjustHint(_ rect: CGRect) {
        let text = "Return to capture, Esc to cancel"
        let attributed = attributes(font: .systemFont(ofSize: 12), color: Palette.text)
        let size = (text as NSString).size(withAttributes: attributed)
        let fitsBelow = rect.maxY + 40 <= bounds.maxY
        drawPill(
            text: text,
            at: CGPoint(x: rect.midX - size.width / 2 - 8, y: fitsBelow ? rect.maxY + 10 : rect.maxY - 36),
            font: .systemFont(ofSize: 12)
        )
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        path.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        path.stroke()
    }

    private func drawLoupe(at cursor: CGPoint) {
        let size = Self.loupeSize
        let samples = Self.loupeSamples
        let origin = SelectionGeometry.loupeOrigin(cursor: cursor, size: size + 28, offset: 22, bounds: bounds)
        let circle = CGRect(x: origin.x, y: origin.y, width: size, height: size)

        let image = snapshot.image
        let centerX = Int(cursor.x * snapshot.scale)
        let centerY = Int(cursor.y * snapshot.scale)
        let cropX = min(max(centerX - samples / 2, 0), max(image.width - samples, 0))
        let cropY = min(max(centerY - samples / 2, 0), max(image.height - samples, 0))
        let crop = CGRect(x: cropX, y: cropY, width: samples, height: samples)

        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(ovalIn: circle)
        ring.addClip()
        if let sample = image.cropping(to: crop) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: sample, size: circle.size).draw(
                in: circle, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil
            )
        }

        let cell = size / CGFloat(samples)
        NSColor.black.withAlphaComponent(0.14).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for index in 1..<samples {
            let offset = CGFloat(index) * cell
            grid.move(to: CGPoint(x: circle.minX + offset, y: circle.minY))
            grid.line(to: CGPoint(x: circle.minX + offset, y: circle.maxY))
            grid.move(to: CGPoint(x: circle.minX, y: circle.minY + offset))
            grid.line(to: CGPoint(x: circle.maxX, y: circle.minY + offset))
        }
        grid.stroke()

        Palette.accent.setStroke()
        let marker = NSBezierPath(rect: CGRect(
            x: circle.minX + CGFloat(centerX - cropX) * cell,
            y: circle.minY + CGFloat(centerY - cropY) * cell,
            width: cell,
            height: cell
        ))
        marker.lineWidth = 2
        marker.stroke()
        NSGraphicsContext.restoreGraphicsState()

        Palette.text.setStroke()
        ring.lineWidth = 2
        ring.stroke()

        let label = "x \(Int(cursor.x)), y \(Int(cursor.y))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let width = (label as NSString).size(withAttributes: attributes(font: font, color: Palette.text)).width
        drawPill(text: label, at: CGPoint(x: circle.midX - width / 2 - 8, y: circle.maxY + 6), font: font)
    }

    private func drawWindowMode() {
        guard let hovered = session.hoveredWindow else {
            fillDim(cutout: nil)
            return
        }
        let rect = hovered.frame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
        fillDim(cutout: rect, cornerRadius: 10)

        Palette.accent.setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        outline.lineWidth = 2
        outline.stroke()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        if bounds.contains(center) {
            let title = hovered.title.isEmpty ? hovered.appName : "\(hovered.appName): \(hovered.title)"
            drawInfoCard(
                title: title,
                detail: "Click to capture. Hold Shift to include the wallpaper.",
                center: center
            )
        }
    }

    private func drawFullscreenMode() {
        let isTarget = session.cursorDisplay == snapshot.displayID
        fillDim(cutout: isTarget ? bounds.insetBy(dx: 2, dy: 2) : nil)
        guard isTarget else { return }

        Palette.accent.withAlphaComponent(0.12).setFill()
        bounds.fill(using: .sourceOver)
        Palette.accent.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        let screenName = NSScreen.screens.first { $0.displayID == snapshot.displayID }?.localizedName ?? "This display"
        drawInfoCard(
            title: screenName,
            detail: "Click to capture this screen, or move to another display.",
            center: CGPoint(x: bounds.midX, y: bounds.midY)
        )
    }

    private func drawInfoCard(title: String, detail: String, center: CGPoint) {
        let width: CGFloat = 400
        let height: CGFloat = 76
        let card = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        Palette.panel.setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(
            in: CGRect(x: card.minX + 16, y: card.minY + 15, width: width - 32, height: 22),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: Palette.text,
                .paragraphStyle: paragraph,
            ]
        )
        (detail as NSString).draw(
            in: CGRect(x: card.minX + 16, y: card.minY + 41, width: width - 32, height: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: Palette.secondary,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private func drawPill(text: String, at origin: CGPoint, font: NSFont) {
        let attrs = attributes(font: font, color: Palette.text)
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 16, height: size.height + 8)
        Palette.panel.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attrs)
    }

    // MARK: Mode bar

    private var barItems: [BarItem] {
        let timerLabel = session.timer == 0 ? "Timer" : "Timer \(session.timer)s"
        let specs: [(BarAction, String, String?, Bool, CGFloat)] = [
            (.mode(.area), OverlaySession.Mode.area.title, "A", session.mode == .area, 100),
            (.mode(.window), OverlaySession.Mode.window.title, "W", session.mode == .window, 116),
            (.mode(.fullscreen), OverlaySession.Mode.fullscreen.title, "F", session.mode == .fullscreen, 136),
            (.timer, timerLabel, "T", session.timer != 0, 124),
            (.close, "×", nil, false, 44),
        ]

        let gap: CGFloat = 4
        let inset: CGFloat = 6
        let total = specs.reduce(0) { $0 + $1.4 } + gap * CGFloat(specs.count - 1)
        var x = bounds.midX - total / 2
        let y = bounds.maxY - 28 - inset - 48

        return specs.map { spec in
            defer { x += spec.4 + gap }
            return BarItem(
                action: spec.0, label: spec.1, key: spec.2, selected: spec.3,
                rect: CGRect(x: x, y: y, width: spec.4, height: 48)
            )
        }
    }

    private func drawBar() {
        let items = barItems
        guard let first = items.first, let last = items.last else { return }
        let background = CGRect(
            x: first.rect.minX - 6, y: first.rect.minY - 6,
            width: last.rect.maxX - first.rect.minX + 12, height: 60
        )
        Palette.panel.setFill()
        let shape = NSBezierPath(roundedRect: background, xRadius: 14, yRadius: 14)
        shape.fill()
        Palette.hairline.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        for item in items {
            let foreground = item.selected ? Palette.onAccent : Palette.text
            if item.selected {
                Palette.accent.setFill()
                NSBezierPath(roundedRect: item.rect, xRadius: 9, yRadius: 9).fill()
            }

            let font = NSFont.systemFont(ofSize: item.key == nil ? 18 : 13, weight: .medium)
            let attrs = attributes(font: font, color: foreground)
            let labelSize = (item.label as NSString).size(withAttributes: attrs)
            let keyFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let keyAttrs = attributes(font: keyFont, color: foreground)
            let keyWidth = item.key.map { ($0 as NSString).size(withAttributes: keyAttrs).width + 12 + 8 } ?? 0

            let startX = item.rect.midX - (labelSize.width + keyWidth) / 2
            (item.label as NSString).draw(
                at: CGPoint(x: startX, y: item.rect.midY - labelSize.height / 2),
                withAttributes: attrs
            )

            if let key = item.key {
                let chip = CGRect(x: startX + labelSize.width + 8, y: item.rect.midY - 9, width: keyWidth - 8, height: 18)
                foreground.setStroke()
                let chipPath = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                chipPath.lineWidth = 1
                chipPath.stroke()
                let keySize = (key as NSString).size(withAttributes: keyAttrs)
                (key as NSString).draw(
                    at: CGPoint(x: chip.midX - keySize.width / 2, y: chip.midY - keySize.height / 2),
                    withAttributes: keyAttrs
                )
            }
        }
    }
}
