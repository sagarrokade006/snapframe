import AppKit
import Combine
import SnapframeCore
import SwiftUI

struct AnnotationCanvas: NSViewRepresentable {
    let session: AnnotateSession

    func makeNSView(context: Context) -> AnnotationCanvasView { AnnotationCanvasView(session: session) }
    func updateNSView(_ view: AnnotationCanvasView, context: Context) { view.needsDisplay = true }
}

/// The interactive drawing surface. Document points are image points with y pointing down.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    private enum Gesture {
        case none
        case drawing(start: CGPoint)
        case moving(start: CGPoint, original: Annotation)
        case resizing(handle: SelectionHandle, original: Annotation)
        case cropping(anchor: CGPoint)
    }

    private let session: AnnotateSession
    private var observer: AnyCancellable?
    private var gesture = Gesture.none
    private var textField: NSTextField?
    private var editingTextID: UUID?
    private var textOrigin = CGPoint.zero

    private static let margin: CGFloat = 24
    private static let handleRadius: CGFloat = 9

    init(session: AnnotateSession) {
        self.session = session
        super.init(frame: .zero)
        observer = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor private var isCropping: Bool { session.tool == .crop }

    // MARK: Coordinates

    @MainActor
    private var layoutInfo: (scale: CGFloat, origin: CGPoint, offset: CGPoint, size: CGSize) {
        let document = session.document
        let visible = isCropping ? CGRect(origin: .zero, size: document.imageSize) : document.visibleRect
        let padding = isCropping ? 0 : document.style.effectivePadding
        let output = CGSize(width: visible.width + padding * 2, height: visible.height + padding * 2)
        let available = CGSize(width: max(bounds.width - Self.margin * 2, 1), height: max(bounds.height - Self.margin * 2, 1))
        let scale = min(available.width / output.width, available.height / output.height, 1)
        let origin = CGPoint(x: (bounds.width - output.width * scale) / 2, y: (bounds.height - output.height * scale) / 2)
        return (scale, origin, CGPoint(x: padding - visible.minX, y: padding - visible.minY), output)
    }

    @MainActor
    private func documentPoint(_ point: CGPoint) -> CGPoint {
        let info = layoutInfo
        return CGPoint(x: (point.x - info.origin.x) / info.scale - info.offset.x, y: (point.y - info.origin.y) / info.scale - info.offset.y)
    }

    @MainActor
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        let info = layoutInfo
        return CGPoint(x: (point.x + info.offset.x) * info.scale + info.origin.x, y: (point.y + info.offset.y) * info.scale + info.origin.y)
    }

    @MainActor
    private func viewRect(_ rect: CGRect) -> CGRect {
        let a = viewPoint(CGPoint(x: rect.minX, y: rect.minY))
        let b = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    @MainActor private var tolerance: CGFloat { 6 / layoutInfo.scale }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MainActor.assumeIsolated { paint(context) }
    }

    @MainActor
    private func paint(_ context: CGContext) {
        let info = layoutInfo
        context.saveGState()
        context.translateBy(x: info.origin.x, y: info.origin.y)
        context.scaleBy(x: info.scale, y: info.scale)
        session.renderer.render(session.document, draft: session.draft, in: context, showFullImage: isCropping)
        context.restoreGState()

        if let crop = session.pendingCrop { paintCrop(crop, context: context) }
        if let selected = session.selected { paintSelection(selected.bounds, context: context) }
    }

    @MainActor
    private func paintCrop(_ crop: CGRect, context: CGContext) {
        let info = layoutInfo
        let image = CGRect(origin: info.origin, size: CGSize(width: info.size.width * info.scale, height: info.size.height * info.scale))
        let selection = viewRect(crop)
        let path = CGMutablePath()
        path.addRect(image)
        path.addRect(selection)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(Palette.accent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(selection)
    }

    /// Thin objects such as straight lines only get corners, so their middle stays draggable.
    private func handles(for rect: CGRect) -> [SelectionHandle] {
        rect.width < 30 || rect.height < 30 ? [.topLeft, .topRight, .bottomLeft, .bottomRight] : SelectionHandle.allCases
    }

    @MainActor
    private func paintSelection(_ bounds: CGRect, context: CGContext) {
        let rect = viewRect(bounds)
        context.setStrokeColor(Palette.accent.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        for handle in handles(for: rect) {
            let center = SelectionGeometry.point(of: handle, in: rect)
            let box = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.setFillColor(Palette.handle.cgColor)
            context.fill(box)
            context.setStrokeColor(Palette.accent.cgColor)
            context.setLineWidth(1.5)
            context.stroke(box)
        }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            window?.makeFirstResponder(self)
            commitText()
            begin(at: location, clickCount: event.clickCount)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        MainActor.assumeIsolated { update(to: location, shift: shift) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { end() }
    }

    @MainActor
    private func begin(at location: CGPoint, clickCount: Int) {
        let point = documentPoint(location)
        switch session.tool {
        case .select:
            beginSelecting(location: location, point: point, clickCount: clickCount)
        case .crop:
            gesture = .cropping(anchor: point)
            session.pendingCrop = CGRect(origin: point, size: .zero)
        case .text:
            if let object = session.document.object(at: point, tolerance: tolerance), case .text = object.shape {
                beginEditing(object)
            } else {
                beginText(at: point, string: "", id: nil)
            }
        case .counter:
            let radius: CGFloat = 16
            session.document.objects.append(Annotation(
                shape: .counter(center: point, number: session.document.nextCounterNumber, radius: radius),
                color: session.color, lineWidth: session.lineWidth
            ))
            session.commit()
        case .image:
            break
        default:
            gesture = .drawing(start: point)
            session.draft = makeDraft(start: point, end: point, shift: false)
        }
    }

    @MainActor
    private func beginSelecting(location: CGPoint, point: CGPoint, clickCount: Int) {
        if let selected = session.selected,
           let handle = handles(for: viewRect(selected.bounds)).first(where: {
               let center = SelectionGeometry.point(of: $0, in: viewRect(selected.bounds))
               return abs(center.x - location.x) <= Self.handleRadius && abs(center.y - location.y) <= Self.handleRadius
           }) {
            gesture = .resizing(handle: handle, original: selected)
            return
        }
        guard let object = session.selected.flatMap({ $0.bounds.contains(point) ? $0 : nil })
                ?? session.document.object(at: point, tolerance: tolerance)
        else {
            session.selectionID = nil
            return
        }
        if clickCount == 2, case .text = object.shape {
            beginEditing(object)
            return
        }
        session.selectionID = object.id
        session.color = object.color
        gesture = .moving(start: point, original: object)
    }

    @MainActor
    private func update(to location: CGPoint, shift: Bool) {
        let point = documentPoint(location)
        switch gesture {
        case .none:
            return
        case .drawing(let start):
            if case .freehand(let points)? = session.draft?.shape {
                session.draft?.shape = .freehand(points + [point])
            } else if case .marker(let points)? = session.draft?.shape {
                session.draft?.shape = .marker(points + [point])
            } else {
                session.draft = makeDraft(start: start, end: point, shift: shift)
            }
        case .moving(let start, let original):
            session.document.replace(original.translated(dx: point.x - start.x, dy: point.y - start.y))
        case .resizing(let handle, let original):
            let target = SelectionGeometry.resized(original.bounds, handle: handle, to: point, minSize: 4, bounds: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
            session.document.replace(original.resized(to: target))
        case .cropping(let anchor):
            session.pendingCrop = SelectionGeometry.rect(
                anchor: anchor, current: point,
                aspect: shift ? 1 : nil,
                bounds: CGRect(origin: .zero, size: session.document.imageSize)
            )
        }
    }

    @MainActor
    private func end() {
        defer { gesture = .none }
        switch gesture {
        case .drawing:
            if let draft = session.draft, draft.bounds.width >= 3 || draft.bounds.height >= 3 {
                session.document.objects.append(draft)
                session.commit()
            }
            session.draft = nil
        case .moving, .resizing:
            session.commit()
        default:
            break
        }
    }

    @MainActor
    private func makeDraft(start: CGPoint, end rawEnd: CGPoint, shift: Bool) -> Annotation {
        let angled = shift ? SelectionGeometry.snappedToAngle(from: start, to: rawEnd) : rawEnd
        let box = SelectionGeometry.rect(
            anchor: start, current: rawEnd, aspect: shift ? 1 : nil,
            bounds: CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
        )

        let shape: AnnotationShape
        switch session.tool {
        case .arrow: shape = .arrow(from: start, to: angled)
        case .line: shape = .line(from: start, to: angled)
        case .filled: shape = .rectangle(box, filled: true)
        case .ellipse: shape = .ellipse(box)
        case .draw: shape = .freehand([start])
        case .marker: shape = .marker([start])
        case .spotlight: shape = .spotlight(box, oval: session.spotlightOval)
        case .redact: shape = .redaction(box, mode: session.redactionMode)
        default: shape = .rectangle(box, filled: false)
        }
        return Annotation(shape: shape, color: session.color, lineWidth: session.lineWidth)
    }

    // MARK: Text

    @MainActor private var newTextSize: CGFloat { 12 + session.lineWidth * 3 }

    @MainActor
    private func beginEditing(_ object: Annotation) {
        guard case .text(let rect, let string, let fontSize) = object.shape else { return }
        session.selectionID = nil
        session.document.objects.removeAll { $0.id == object.id }
        session.color = object.color
        beginText(at: rect.origin, string: string, id: object.id, fontSize: fontSize)
    }

    @MainActor
    private func beginText(at point: CGPoint, string: String, id: UUID?, fontSize: CGFloat? = nil) {
        textOrigin = point
        editingTextID = id
        let size = fontSize ?? newTextSize
        let scale = layoutInfo.scale
        let origin = viewPoint(point)

        let field = NSTextField(string: string)
        field.font = AnnotationRenderer.textFont(size: size * scale)
        field.textColor = NSColor(cgColor: snapCGColor(session.color))
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Type here"
        field.tag = Int(size * 100)
        field.frame = CGRect(x: origin.x, y: origin.y, width: max(240, bounds.maxX - origin.x - 12), height: ceil(size * scale * 1.35))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        MainActor.assumeIsolated { commitText() }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated { commitText() }
    }

    @MainActor
    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = CGFloat(field.tag) / 100
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        if !string.isEmpty {
            let size = AnnotationRenderer.textSize(string, fontSize: fontSize)
            session.document.objects.append(Annotation(
                id: editingTextID ?? UUID(),
                shape: .text(CGRect(origin: textOrigin, size: size), string: string, fontSize: fontSize),
                color: session.color, lineWidth: session.lineWidth
            ))
        }
        editingTextID = nil
        session.commit()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let code = event.keyCode
        var handled = true
        MainActor.assumeIsolated {
            switch code {
            case 51, 117: session.deleteSelection()
            case 53:
                session.selectionID = nil
                session.pendingCrop = nil
            case 36, 76:
                if session.tool == .crop { session.applyCrop() }
            case 123: session.nudgeSelection(dx: -step, dy: 0)
            case 124: session.nudgeSelection(dx: step, dy: 0)
            case 125: session.nudgeSelection(dx: 0, dy: step)
            case 126: session.nudgeSelection(dx: 0, dy: -step)
            default: handled = false
            }
        }
        if !handled { super.keyDown(with: event) }
    }
}
