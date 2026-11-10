#if DEBUG
import AppKit
import SnapframeCore
import SwiftUI

/// Debug-only checks for the Annotate editor, using simulated input and a synthetic image.
@MainActor
enum PreviewAnnotate {
    static func sampleSession(base: CGImage, scale: CGFloat) -> AnnotateSession {
        var document = AnnotateDocument(
            imageSize: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale),
            style: CanvasStyle(fill: .gradient(0xFF8A63, 0xC7A6E8), padding: 56, cornerRadius: 14, shadow: 0.6)
        )
        document.objects = [
            Annotation(shape: .marker([CGPoint(x: 240, y: 262), CGPoint(x: 720, y: 262)]), color: 0xFFD60A, lineWidth: 4),
            Annotation(shape: .rectangle(CGRect(x: 225, y: 90, width: 280, height: 60), filled: false), color: 0xFF6B3D, lineWidth: 4),
            Annotation(shape: .arrow(from: CGPoint(x: 900, y: 320), to: CGPoint(x: 730, y: 210)), color: 0xFF6B3D, lineWidth: 4),
            Annotation(shape: .counter(center: CGPoint(x: 530, y: 120), number: 1, radius: 16), color: 0x3D8BFF, lineWidth: 4),
            Annotation(shape: .redaction(CGRect(x: 240, y: 400, width: 400, height: 28), mode: .secure), color: 0, lineWidth: 4),
            Annotation(shape: .redaction(CGRect(x: 240, y: 440, width: 320, height: 28), mode: .blackout), color: 0, lineWidth: 4),
            Annotation(shape: .ellipse(CGRect(x: 760, y: 420, width: 220, height: 110)), color: 0x2FB5A6, lineWidth: 4),
            Annotation(shape: .text(CGRect(x: 780, y: 340, width: 260, height: 34), string: "Confirm before release", fontSize: 22), color: 0xFF6B3D, lineWidth: 4),
        ]
        return AnnotateSession(base: base, scale: scale, document: document, itemID: nil)
    }

    static func checkBurning(base: CGImage, scale: CGFloat) {
        let session = sampleSession(base: base, scale: scale)
        let document = session.document
        guard let burned = session.renderer.burningRedactions(document) else {
            print("burn: FAILED")
            return
        }
        let point = CGPoint(x: 300, y: 450)
        let snapshot = { (image: CGImage) in
            DisplaySnapshot(displayID: 0, frame: CGRect(origin: .zero, size: document.imageSize), scale: scale, image: image).hexColor(at: point) ?? "?"
        }
        let remaining = burned.document.objects.filter(\.isRedaction).count
        print("burn: original \(snapshot(base)), burned \(snapshot(burned.image)), redaction objects left \(remaining), other objects \(burned.document.objects.count)")

        if let flat = session.renderer.flatten(document) {
            print("flatten: \(flat.width)x\(flat.height), expected \(Int(document.outputSize.width * scale))x\(Int(document.outputSize.height * scale))")
        }
    }

    static func checkStoredEdit(base: CGImage, scale: CGFloat) async {
        let library = CaptureLibrary.shared
        guard let item = await library.add(image: base, scale: scale, kind: "Area", name: "Edit check", formatTitle: "PNG", savedURL: nil) else {
            print("store: FAILED to add")
            return
        }
        let session = sampleSession(base: base, scale: scale)
        guard let flat = session.renderer.flatten(session.document),
              let burned = session.renderer.burningRedactions(session.document),
              let png = try? OutputService.encode(burned.image, format: .png, quality: 1, scale: scale),
              let data = try? SnapframeProject(document: burned.document, scale: Double(scale), basePNG: png).encoded()
        else {
            print("store: FAILED to prepare")
            return
        }
        await library.storeEdit(flat, scale: scale, projectData: data, itemID: item.id)
        let updated = library.index.items.first { $0.id == item.id }
        let reloaded = (try? Data(contentsOf: library.projectURL(id: item.id))).flatMap { try? SnapframeProject.decode($0) }
        print("store: item now \(updated?.pixelWidth ?? 0)x\(updated?.pixelHeight ?? 0), project objects \(reloaded?.document.objects.count ?? -1), redactions in project \(reloaded?.document.objects.filter(\.isRedaction).count ?? -1)")
        library.delete(item)
        print("store: project removed with item: \(!FileManager.default.fileExists(atPath: library.projectURL(id: item.id).path))")
    }

    /// Sends real mouse and key events through the canvas view.
    static func checkCanvas(base: CGImage, scale: CGFloat) {
        let size = CGSize(width: 1280, height: 760)
        let document = AnnotateDocument(imageSize: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale))
        let session = AnnotateSession(base: base, scale: scale, document: document, itemID: nil)
        let canvas = AnnotationCanvasView(session: session)
        canvas.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.makeFirstResponder(canvas)

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: point.x, y: size.height - point.y), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }
        func drag(_ from: CGPoint, _ to: CGPoint, flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: mouse(.leftMouseDown, from, flags: flags))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), flags: flags))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, to, flags: flags))
            canvas.mouseUp(with: mouse(.leftMouseUp, to, flags: flags))
        }
        func click(_ point: CGPoint) {
            canvas.mouseDown(with: mouse(.leftMouseDown, point))
            canvas.mouseUp(with: mouse(.leftMouseUp, point))
        }
        func key(_ code: UInt16) {
            canvas.keyDown(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
            )!)
        }

        var results: [String] = []
        func check(_ name: String, _ passed: Bool) { results.append("\(passed ? "ok" : "FAIL") \(name)") }

        for (tool, count) in [(AnnotateTool.arrow, 1), (.line, 2), (.rectangle, 3), (.filled, 4), (.ellipse, 5), (.draw, 6), (.marker, 7), (.spotlight, 8), (.redact, 9)] {
            session.tool = tool
            drag(CGPoint(x: 200 + CGFloat(count) * 40, y: 150), CGPoint(x: 330 + CGFloat(count) * 40, y: 260))
            check("draw \(tool.title)", session.document.objects.count == count)
        }

        session.document.objects.removeAll()
        session.commit()

        session.tool = .counter
        click(CGPoint(x: 300, y: 300))
        click(CGPoint(x: 360, y: 300))
        let numbers = session.document.objects.compactMap { object -> Int? in
            if case .counter(_, let number, _) = object.shape { return number }
            return nil
        }
        check("counters number themselves", numbers == [1, 2])

        session.tool = .text
        click(CGPoint(x: 500, y: 300))
        (canvas.subviews.first as? NSTextField)?.stringValue = "Hello"
        session.tool = .select
        click(CGPoint(x: 900, y: 600))
        let hasText = session.document.objects.contains { object in
            if case .text(_, let string, _) = object.shape { return string == "Hello" }
            return false
        }
        check("text is placed", hasText)
        check("text field removed", canvas.subviews.isEmpty)

        session.tool = .arrow
        drag(CGPoint(x: 400, y: 500), CGPoint(x: 700, y: 500))
        let arrowID = session.document.objects.last!.id
        let countWithArrow = session.document.objects.count

        session.tool = .select
        click(CGPoint(x: 550, y: 500))
        check("click selects", session.selectionID == arrowID)

        let before = session.selected!.bounds
        drag(CGPoint(x: 550, y: 500), CGPoint(x: 550, y: 560))
        check("drag moves", session.selected!.bounds.minY > before.minY)

        session.undo()
        check("undo restores position", session.document.objects.first { $0.id == arrowID }?.bounds == before)
        session.redo()
        check("redo reapplies", session.document.objects.first { $0.id == arrowID }?.bounds != before)

        click(CGPoint(x: 550, y: 560))
        key(51)
        check("delete removes", session.document.objects.count == countWithArrow - 1)
        session.undo()
        check("undo brings it back", session.document.objects.count == countWithArrow)

        session.tool = .crop
        drag(CGPoint(x: 300, y: 200), CGPoint(x: 800, y: 500))
        check("crop preview", session.pendingCrop != nil)
        key(36)
        check("return applies crop", session.document.crop != nil && session.pendingCrop == nil)
        session.undo()
        check("crop undoes", session.document.crop == nil)

        print("canvas: \(results.filter { $0.hasPrefix("ok") }.count) passed, \(results.filter { $0.hasPrefix("FAIL") }.count) failed")
        results.filter { $0.hasPrefix("FAIL") }.forEach { print($0) }
    }
}
#endif
