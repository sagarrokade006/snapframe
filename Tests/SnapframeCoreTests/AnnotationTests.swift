import CoreGraphics
import XCTest

@testable import SnapframeCore

final class AnnotationGeometryTests: XCTestCase {
    private func make(_ shape: AnnotationShape, lineWidth: CGFloat = 4) -> Annotation {
        Annotation(shape: shape, color: 0xFF0000, lineWidth: lineWidth)
    }

    func testBoundsOfLineAndFreehand() {
        XCTAssertEqual(make(.line(from: CGPoint(x: 50, y: 10), to: CGPoint(x: 10, y: 40))).bounds, CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertEqual(make(.freehand([CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 2), CGPoint(x: 8, y: 20)])).bounds, CGRect(x: 5, y: 2, width: 10, height: 18))
    }

    func testCounterBounds() {
        XCTAssertEqual(make(.counter(center: CGPoint(x: 20, y: 20), number: 1, radius: 10)).bounds, CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testLineHitNearButNotFar() {
        let line = make(.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)))
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 20), tolerance: 4))
        XCTAssertFalse(line.hitTest(CGPoint(x: 120, y: 0), tolerance: 4))
    }

    func testHollowRectangleIgnoresItsMiddle() {
        let rect = make(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 100), filled: false))
        XCTAssertTrue(rect.hitTest(CGPoint(x: 1, y: 50), tolerance: 4))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))
    }

    func testFilledRectangleHitsMiddle() {
        XCTAssertTrue(make(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 100), filled: true)).hitTest(CGPoint(x: 50, y: 50), tolerance: 4))
    }

    func testEllipseHitsOutlineOnly() {
        let ellipse = make(.ellipse(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 100, y: 50), tolerance: 4))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))
    }

    func testTranslateMovesEveryPoint() {
        let moved = make(.freehand([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])).translated(dx: 10, dy: 20)
        XCTAssertEqual(moved.shape, .freehand([CGPoint(x: 11, y: 22), CGPoint(x: 13, y: 24)]))
    }

    func testResizeRescalesToTarget() {
        let arrow = make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(arrow.resized(to: CGRect(x: 100, y: 100, width: 40, height: 20)).shape, .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 120)))
    }

    func testResizeScalesTextFont() {
        let text = make(.text(CGRect(x: 0, y: 0, width: 100, height: 20), string: "Hi", fontSize: 16))
        guard case .text(let rect, _, let fontSize) = text.resized(to: CGRect(x: 0, y: 0, width: 200, height: 40)).shape else { return XCTFail("Not text") }
        XCTAssertEqual(rect.height, 40)
        XCTAssertEqual(fontSize, 32)
    }

    func testAngleSnap() {
        let end = SelectionGeometry.snappedToAngle(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(end.y, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, hypot(100, 8), accuracy: 0.001)
    }
}

final class AnnotateDocumentTests: XCTestCase {
    private func doc() -> AnnotateDocument { AnnotateDocument(imageSize: CGSize(width: 800, height: 600)) }

    func testPaddingOnlyWithBackground() {
        var document = doc()
        XCTAssertEqual(document.outputSize, CGSize(width: 800, height: 600))
        document.style.fill = .color(0x112233)
        document.style.padding = 40
        XCTAssertEqual(document.outputSize, CGSize(width: 880, height: 680))
    }

    func testCropChangesOutput() {
        var document = doc()
        document.crop = CGRect(x: 10, y: 10, width: 200, height: 100)
        XCTAssertEqual(document.outputSize, CGSize(width: 200, height: 100))
    }

    func testCounterContinuesFromHighest() {
        var document = doc()
        XCTAssertEqual(document.nextCounterNumber, 1)
        document.objects = [Annotation(shape: .counter(center: .zero, number: 4, radius: 10), color: 0, lineWidth: 1)]
        XCTAssertEqual(document.nextCounterNumber, 5)
    }

    func testTopMostObjectWins() {
        var document = doc()
        let bottom = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 50, height: 50), filled: true), color: 0, lineWidth: 1)
        let top = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 50, height: 50), filled: true), color: 1, lineWidth: 1)
        document.objects = [bottom, top]
        XCTAssertEqual(document.object(at: CGPoint(x: 10, y: 10), tolerance: 2)?.id, top.id)
    }

    func testDuplicateMakesOffsetCopy() {
        var document = doc()
        let item = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 10, height: 10)), color: 0, lineWidth: 1)
        document.objects = [item]
        let copy = document.duplicate(id: item.id, offset: 12)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy, item.id)
        XCTAssertEqual(document.objects.last?.bounds.origin, CGPoint(x: 12, y: 12))
    }
}

final class EditHistoryTests: XCTestCase {
    func testUndoRedo() {
        var history = EditHistory(1)
        history.record(2)
        history.record(3)
        XCTAssertEqual(history.undo(), 2)
        XCTAssertEqual(history.undo(), 1)
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.redo(), 2)
        XCTAssertEqual(history.current, 2)
    }

    func testRecordingClearsRedo() {
        var history = EditHistory(1)
        history.record(2)
        _ = history.undo()
        history.record(9)
        XCTAssertFalse(history.canRedo)
    }

    func testIdenticalStateIsNotAStep() {
        var history = EditHistory(1)
        history.record(1)
        XCTAssertFalse(history.canUndo)
    }

    func testLimitDropsOldest() {
        var history = EditHistory(0, limit: 2)
        (1...5).forEach { history.record($0) }
        XCTAssertEqual(history.undo(), 4)
        XCTAssertEqual(history.undo(), 3)
        XCTAssertNil(history.undo())
    }
}

final class ProjectAndPDFTests: XCTestCase {
    private func sampleImage() -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return context.makeImage()!
    }

    func testProjectRoundTripsEveryShape() throws {
        let document = AnnotateDocument(
            imageSize: CGSize(width: 100, height: 50),
            crop: CGRect(x: 1, y: 2, width: 30, height: 40),
            objects: [
                Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 5, y: 5)), color: 1, lineWidth: 2),
                Annotation(shape: .text(CGRect(x: 0, y: 0, width: 5, height: 5), string: "Note", fontSize: 12), color: 2, lineWidth: 2),
                Annotation(shape: .redaction(CGRect(x: 0, y: 0, width: 5, height: 5), mode: .blackout), color: 3, lineWidth: 2),
                Annotation(shape: .image(CGRect(x: 0, y: 0, width: 5, height: 5), png: Data([1, 2, 3])), color: 4, lineWidth: 2),
            ],
            style: CanvasStyle(fill: .gradient(1, 2), padding: 20, cornerRadius: 4, shadow: 0.2)
        )
        let project = SnapframeProject(document: document, scale: 2, basePNG: Data([9, 8]))
        XCTAssertEqual(try SnapframeProject.decode(project.encoded()), project)
    }

    func testNewerProjectIsRefused() throws {
        var project = SnapframeProject(document: AnnotateDocument(imageSize: .zero), scale: 1, basePNG: Data())
        project.formatVersion = 99
        XCTAssertThrowsError(try SnapframeProject.decode(project.encoded()))
    }

    func testPDFNeedsThePassword() throws {
        let data = try ProtectedPDF.data(image: sampleImage(), scale: 2, password: "correct horse")
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        XCTAssertTrue(document.isEncrypted)
        XCTAssertFalse(document.isUnlocked)
        XCTAssertFalse(document.unlockWithPassword("wrong"))
        XCTAssertTrue(document.unlockWithPassword("correct horse"))
        XCTAssertEqual(document.numberOfPages, 1)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).width, 20)
    }

    func testPDFRefusesEmptyPassword() {
        XCTAssertThrowsError(try ProtectedPDF.data(image: sampleImage(), scale: 1, password: "")) {
            XCTAssertEqual($0 as? ProtectedPDF.PDFError, .emptyPassword)
        }
    }
}
