import AppKit
import SnapframeCore

enum Palette {
    static let accent = NSColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 1)
    static let panel = NSColor(srgbRed: 0.09, green: 0.094, blue: 0.106, alpha: 1)
    static let control = NSColor(srgbRed: 0.149, green: 0.157, blue: 0.176, alpha: 1)
    static let hairline = NSColor(srgbRed: 0.212, green: 0.22, blue: 0.243, alpha: 1)
    static let text = NSColor(srgbRed: 0.957, green: 0.953, blue: 0.941, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.659, green: 0.671, blue: 0.702, alpha: 1)
    static let onAccent = NSColor(srgbRed: 0.09, green: 0.094, blue: 0.102, alpha: 1)
    static let dim = NSColor(srgbRed: 0.04, green: 0.043, blue: 0.051, alpha: 0.62)
}

extension DisplaySnapshot {
    /// The color of the pixel under a display-local point, such as `#F7F7F5`.
    func hexColor(at point: CGPoint) -> String? {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2]) : nil
    }
}

/// One per display. Coordinates are display-local points with y pointing down.
final class SelectionOverlayView: NSView {
    private enum BarAction {
        case mode(OverlaySession.Mode)
        case timer
        case close
        case aspect(CaptureAspect)
        case then(AfterCapture)
    }

    private enum BarStyle { case mode, tool, chip }

    private struct BarItem {
        let action: BarAction
        let label: String
        var key: String?
        var symbol: String?
        let selected: Bool
        let style: BarStyle
        let rect: CGRect
    }

    let session: OverlaySession
    let snapshot: DisplaySnapshot

    private let backdrop: NSImage
    private var trackingArea: NSTrackingArea?

    private static let barSize = CGSize(width: 960, height: 116)
    private static let loupeColumns = 13
    private static let loupeRows = 11

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

    private var barRect: CGRect {
        CGRect(
            x: bounds.midX - Self.barSize.width / 2,
            y: bounds.maxY - 24 - Self.barSize.height,
            width: Self.barSize.width,
            height: Self.barSize.height
        )
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        (showsBar && barRect.contains(point) ? NSCursor.arrow : NSCursor.crosshair).set()
        session.mouseMoved(to: point, on: snapshot)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        window?.makeKey()
        if showsBar, barRect.contains(point) {
            guard let item = barItems.first(where: { $0.rect.contains(point) }) else { return }
            switch item.action {
            case .mode(let mode): session.setMode(mode)
            case .timer: session.cycleTimer()
            case .close: session.cancel()
            case .aspect(let aspect): session.setAspect(aspect)
            case .then(let value): session.setAfterCapture(value)
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
        case .area, .scrolling, .text: drawAreaMode()
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
        let selection = session.selectionDisplay == snapshot.displayID ? session.selection : nil
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
              !session.isAdjusting, !(showsBar && barRect.contains(cursor))
        else { return }

        if selection == nil { drawCrosshair(at: cursor) }
        drawLoupe(at: cursor)
    }

    private func drawHandles(_ rect: CGRect) {
        let handles: [SelectionHandle] = session.isAdjusting
            ? SelectionHandle.allCases
            : [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for handle in handles {
            let center = SelectionGeometry.point(of: handle, in: rect)
            let box = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            let shape = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            Palette.text.setFill()
            shape.fill()
            Palette.accent.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }

    private func drawSizeBadge(_ rect: CGRect) {
        let size = "\(Int((rect.width * snapshot.scale).rounded())) × \(Int((rect.height * snapshot.scale).rounded()))"
        let ratio = session.aspect == .free ? "Freeform" : session.aspect.title
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let ratioFont = NSFont.systemFont(ofSize: 13)
        let sizeWidth = textSize(size, sizeFont).width
        let ratioWidth = textSize(ratio, ratioFont).width

        let badge = CGRect(
            x: rect.minX,
            y: rect.minY >= 42 ? rect.minY - 38 : rect.minY + 8,
            width: sizeWidth + ratioWidth + 30,
            height: 30
        )
        fillRounded(badge, Palette.panel, radius: 8)
        draw(size, at: CGPoint(x: badge.minX + 10, y: badge.midY), sizeFont, Palette.text)
        draw(ratio, at: CGPoint(x: badge.minX + 20 + sizeWidth, y: badge.midY), ratioFont, Palette.secondary)
    }

    private func drawAdjustHint(_ rect: CGRect) {
        let text = "Return to capture, Esc to cancel"
        let font = NSFont.systemFont(ofSize: 12)
        let width = textSize(text, font).width + 20
        let fitsBelow = rect.maxY + 42 <= barRect.minY
        let pill = CGRect(x: rect.midX - width / 2, y: fitsBelow ? rect.maxY + 10 : rect.maxY - 38, width: width, height: 28)
        fillRounded(pill, Palette.panel, radius: 7)
        draw(text, at: CGPoint(x: pill.minX + 10, y: pill.midY), font, Palette.text)
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

    /// A card with magnified pixels, the color under the cursor and its position.
    private func drawLoupe(at cursor: CGPoint) {
        let origin = SelectionGeometry.loupeOrigin(cursor: cursor, size: 214, offset: 22, bounds: bounds)
        let card = CGRect(x: origin.x, y: origin.y, width: 180, height: 214)
        fillRounded(card, Palette.panel, radius: 16)

        let lens = CGRect(x: card.minX + 10, y: card.minY + 10, width: 160, height: 136)
        let columns = Self.loupeColumns, rows = Self.loupeRows
        let image = snapshot.image
        let centerX = Int(cursor.x * snapshot.scale), centerY = Int(cursor.y * snapshot.scale)
        let cropX = min(max(centerX - columns / 2, 0), max(image.width - columns, 0))
        let cropY = min(max(centerY - rows / 2, 0), max(image.height - rows, 0))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: lens, xRadius: 10, yRadius: 10).addClip()
        if let sample = image.cropping(to: CGRect(x: cropX, y: cropY, width: columns, height: rows)) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: sample, size: lens.size).draw(
                in: lens, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil
            )
        }

        let cellWidth = lens.width / CGFloat(columns), cellHeight = lens.height / CGFloat(rows)
        NSColor.black.withAlphaComponent(0.14).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for column in 1..<columns {
            grid.move(to: CGPoint(x: lens.minX + CGFloat(column) * cellWidth, y: lens.minY))
            grid.line(to: CGPoint(x: lens.minX + CGFloat(column) * cellWidth, y: lens.maxY))
        }
        for row in 1..<rows {
            grid.move(to: CGPoint(x: lens.minX, y: lens.minY + CGFloat(row) * cellHeight))
            grid.line(to: CGPoint(x: lens.maxX, y: lens.minY + CGFloat(row) * cellHeight))
        }
        grid.stroke()

        Palette.accent.setStroke()
        let marker = NSBezierPath(rect: CGRect(
            x: lens.minX + CGFloat(centerX - cropX) * cellWidth,
            y: lens.minY + CGFloat(centerY - cropY) * cellHeight,
            width: cellWidth,
            height: cellHeight
        ))
        marker.lineWidth = 2
        marker.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let hex = snapshot.hexColor(at: cursor) ?? "—"
        let rowY = lens.maxY + 19
        if let color = NSColor(hexString: hex) {
            let swatch = CGRect(x: card.minX + 12, y: rowY - 9, width: 18, height: 18)
            fillRounded(swatch, color, radius: 5)
            Palette.secondary.setStroke()
            NSBezierPath(roundedRect: swatch, xRadius: 5, yRadius: 5).stroke()
        }
        let numbers = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        draw(hex, at: CGPoint(x: card.minX + 38, y: rowY), numbers, Palette.text)
        let copyLabel = session.colorCopied ? "Copied" : "⌘C"
        let small = NSFont.systemFont(ofSize: 12)
        draw(copyLabel, at: CGPoint(x: card.maxX - 12 - textSize(copyLabel, small).width, y: rowY), small, Palette.secondary)

        let positionY = rowY + 26
        let positionFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        draw("x \(Int(cursor.x))", at: CGPoint(x: card.minX + 12, y: positionY), positionFont, Palette.secondary)
        let yLabel = "y \(Int(cursor.y))"
        draw(yLabel, at: CGPoint(x: card.maxX - 12 - textSize(yLabel, positionFont).width, y: positionY), positionFont, Palette.secondary)
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
            drawInfoCard(title: title, detail: "Click to capture. Hold Shift to add the wallpaper.", center: center)
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
        drawInfoCard(title: screenName, detail: "Click to capture this screen, or move to another display.", center: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func drawInfoCard(title: String, detail: String, center: CGPoint) {
        let card = CGRect(x: center.x - 240, y: center.y - 42, width: 480, height: 84)
        fillRounded(card, Palette.panel, radius: 16)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(
            in: CGRect(x: card.minX + 18, y: card.minY + 18, width: card.width - 36, height: 22),
            withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: Palette.text, .paragraphStyle: paragraph]
        )
        (detail as NSString).draw(
            in: CGRect(x: card.minX + 18, y: card.minY + 46, width: card.width - 36, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.secondary, .paragraphStyle: paragraph]
        )
    }

    // MARK: Helpers

    private func textSize(_ text: String, _ font: NSFont) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    /// Draws text vertically centered on `point.y`, starting at `point.x`.
    private func draw(_ text: String, at point: CGPoint, _ font: NSFont, _ color: NSColor) {
        let height = textSize(text, font).height
        (text as NSString).draw(at: CGPoint(x: point.x, y: point.y - height / 2), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func fillRounded(_ rect: CGRect, _ color: NSColor, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func symbolImage(_ name: String, _ color: NSColor, pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    // MARK: Toolbar

    private var barItems: [BarItem] {
        let bar = barRect
        var items: [BarItem] = []

        let timerWidth: CGFloat = 112, closeWidth: CGFloat = 52, gap: CGFloat = 6, divider: CGFloat = 17
        let modeWidth = (bar.width - 16 - timerWidth - closeWidth - divider - gap * 5) / 5
        var x = bar.minX + 8
        let topY = bar.minY + 8

        let modes: [(OverlaySession.Mode, String)] = [(.area, "viewfinder"), (.window, "macwindow"), (.fullscreen, "display"), (.scrolling, "scroll"), (.text, "text.viewfinder")]
        for (mode, symbol) in modes {
            items.append(BarItem(
                action: .mode(mode), label: mode.title, key: mode.key, symbol: symbol,
                selected: session.mode == mode, style: .mode,
                rect: CGRect(x: x, y: topY, width: modeWidth, height: 52)
            ))
            x += modeWidth + gap
        }
        x += divider - gap + gap

        items.append(BarItem(
            action: .timer, label: session.timer == 0 ? "No timer" : "\(session.timer) sec", key: nil, symbol: "timer",
            selected: session.timer != 0, style: .tool,
            rect: CGRect(x: x, y: topY, width: timerWidth, height: 52)
        ))
        x += timerWidth + gap
        items.append(BarItem(
            action: .close, label: "", key: nil, symbol: "xmark", selected: false, style: .tool,
            rect: CGRect(x: x, y: topY, width: closeWidth, height: 52)
        ))

        let chipY = bar.minY + 76
        var left = bar.minX + 58
        for aspect in CaptureAspect.allCases {
            items.append(BarItem(
                action: .aspect(aspect), label: aspect.title, selected: session.aspect == aspect, style: .chip,
                rect: CGRect(x: left, y: chipY, width: 52, height: 30)
            ))
            left += 55
        }

        var right = bar.maxX - 14
        for value in AfterCapture.allCases.reversed() {
            let width: CGFloat = value == .saveAndCopy ? 96 : 58
            right -= width
            items.append(BarItem(
                action: .then(value), label: value.shortTitle, selected: session.afterCapture == value, style: .chip,
                rect: CGRect(x: right, y: chipY, width: width, height: 30)
            ))
            right -= 3
        }
        return items
    }

    private func drawBar() {
        let bar = barRect
        fillRounded(bar, Palette.panel, radius: 18)
        Palette.hairline.setStroke()
        let edge = NSBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        edge.lineWidth = 1
        edge.stroke()

        Palette.hairline.setFill()
        CGRect(x: bar.minX, y: bar.minY + 68, width: bar.width, height: 1).fill()

        let items = barItems
        if let timer = items.first(where: { if case .timer = $0.action { return true } else { return false } }) {
            CGRect(x: timer.rect.minX - 11, y: timer.rect.midY - 16, width: 1, height: 32).fill()
        }

        let labelFont = NSFont.systemFont(ofSize: 13)
        draw("Ratio", at: CGPoint(x: bar.minX + 14, y: bar.minY + 91), labelFont, Palette.secondary)
        let firstThen = items.compactMap { item -> CGFloat? in
            if case .then = item.action { return item.rect.minX } else { return nil }
        }.min() ?? bar.maxX
        draw("Then", at: CGPoint(x: firstThen - 10 - textSize("Then", labelFont).width, y: bar.minY + 91), labelFont, Palette.secondary)

        for item in items { drawItem(item) }
    }

    private func drawItem(_ item: BarItem) {
        let fill: NSColor
        let foreground: NSColor
        switch (item.style, item.selected) {
        case (.mode, true): (fill, foreground) = (Palette.accent, Palette.onAccent)
        case (_, true): (fill, foreground) = (Palette.text, Palette.onAccent)
        default: (fill, foreground) = (Palette.control, Palette.text)
        }

        let radius: CGFloat = item.style == .chip ? 7 : 12
        fillRounded(item.rect, fill, radius: radius)

        let font = item.style == .chip
            ? NSFont.systemFont(ofSize: 13, weight: .medium)
            : NSFont.systemFont(ofSize: 14, weight: .semibold)
        let labelWidth = item.label.isEmpty ? 0 : textSize(item.label, font).width
        let iconWidth: CGFloat = item.symbol == nil ? 0 : 20
        let iconGap: CGFloat = item.symbol != nil && !item.label.isEmpty ? 9 : 0
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let keyWidth = item.key.map { textSize($0, keyFont).width + 12 } ?? 0
        let keyGap: CGFloat = item.key == nil ? 0 : 9

        var x = item.rect.midX - (iconWidth + iconGap + labelWidth + keyGap + keyWidth) / 2

        if let symbol = item.symbol, let image = symbolImage(symbol, foreground, pointSize: 16) {
            let size = image.size
            let box = CGRect(x: x + (iconWidth - size.width) / 2, y: item.rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconWidth + iconGap
        }

        draw(item.label, at: CGPoint(x: x, y: item.rect.midY), font, foreground)
        x += labelWidth + keyGap

        if let key = item.key {
            let chip = CGRect(x: x, y: item.rect.midY - 9, width: keyWidth, height: 18)
            fillRounded(chip, item.selected ? Palette.onAccent.withAlphaComponent(0.16) : Palette.hairline, radius: 5)
            draw(key, at: CGPoint(x: chip.minX + 6, y: chip.midY), keyFont, foreground)
        }
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        guard hexString.hasPrefix("#"), let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
