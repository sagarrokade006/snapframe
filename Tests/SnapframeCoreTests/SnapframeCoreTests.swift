import CoreGraphics
import XCTest

@testable import SnapframeCore

final class NameTemplateTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let date = Date(timeIntervalSince1970: 1_794_269_000)  // 2026-11-10 00:03:20 UTC

    func testRendersAllDateTokens() {
        let template = NameTemplate(pattern: "{year}|{month}|{day}|{hour}|{minute}|{second}".replacingOccurrences(of: "|", with: "_"))
        XCTAssertEqual(template.render(date: date, mode: "Area", timeZone: utc), "2026_11_10_00_03_20")
    }

    func testDefaultPatternAndMode() {
        let template = NameTemplate(pattern: "{mode} {date} at {time}")
        XCTAssertEqual(template.render(date: date, mode: "Window", timeZone: utc), "Window 2026-11-10 at 00.03.20")
    }

    func testUnsafeCharactersAreReplaced() {
        XCTAssertEqual(NameTemplate.sanitize("a/b:c\nd"), "a-b-c-d")
        XCTAssertEqual(NameTemplate.sanitize("...hidden"), "hidden")
    }

    func testEmptyNameFallsBack() {
        XCTAssertEqual(NameTemplate.sanitize("   "), "Snapframe")
        XCTAssertEqual(NameTemplate.sanitize("..."), "Snapframe")
    }

    func testLongNameIsCut() {
        XCTAssertEqual(NameTemplate.sanitize(String(repeating: "x", count: 500)).count, 200)
    }

    func testUniqueURLAddsNumber() {
        let directory = URL(fileURLWithPath: "/tmp/shots")
        let taken: Set<String> = ["/tmp/shots/a.png", "/tmp/shots/a 2.png"]
        let url = NameTemplate.uniqueURL(directory: directory, baseName: "a", fileExtension: "png") {
            taken.contains($0.path)
        }
        XCTAssertEqual(url.lastPathComponent, "a 3.png")
    }
}

final class SelectionGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testRectNormalizesDragDirection() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 300, y: 400), current: CGPoint(x: 100, y: 200), aspect: nil, bounds: bounds)
        XCTAssertEqual(rect, CGRect(x: 100, y: 200, width: 200, height: 200))
    }

    func testRectClampsToDisplay() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 900, y: 700), current: CGPoint(x: 1400, y: 950), aspect: nil, bounds: bounds)
        XCTAssertEqual(rect, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    func testSquareStaysSquareAtEdge() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 950, y: 100), current: CGPoint(x: 1200, y: 500), aspect: 1, bounds: bounds)
        XCTAssertEqual(rect.width, rect.height)
        XCTAssertEqual(rect.maxX, 1000)
    }

    func testSquareDragUpLeft() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 500, y: 500), current: CGPoint(x: 400, y: 450), aspect: 1, bounds: bounds)
        XCTAssertEqual(rect, CGRect(x: 400, y: 400, width: 100, height: 100))
    }

    func testSnapOnlyWithinThreshold() {
        let result = SelectionGeometry.snapped(CGPoint(x: 103, y: 220), xs: [100, 500], ys: [200], threshold: 6)
        XCTAssertEqual(result, CGPoint(x: 100, y: 220))
    }

    func testResizeCornerKeepsOppositeCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let result = SelectionGeometry.resized(
            rect, handle: .bottomRight, to: CGPoint(x: 500, y: 450), minSize: 10, bounds: bounds)
        XCTAssertEqual(result, CGRect(x: 100, y: 100, width: 400, height: 350))
    }

    func testResizePastFarEdgeStopsAtMinimum() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        let result = SelectionGeometry.resized(
            rect, handle: .left, to: CGPoint(x: 900, y: 150), minSize: 10, bounds: bounds)
        XCTAssertEqual(result, CGRect(x: 290, y: 100, width: 10, height: 200))
    }

    func testMoveStaysInsideDisplay() {
        let rect = CGRect(x: 900, y: 10, width: 100, height: 100)
        let result = SelectionGeometry.moved(rect, by: CGVector(dx: 50, dy: -50), bounds: bounds)
        XCTAssertEqual(result, CGRect(x: 900, y: 0, width: 100, height: 100))
    }

    func testPixelCropCoversFractionalSelection() {
        let crop = SelectionGeometry.pixelCrop(
            CGRect(x: 10.25, y: 20.75, width: 100.5, height: 50),
            scale: 2,
            imageSize: CGSize(width: 2000, height: 1600))
        XCTAssertEqual(crop, CGRect(x: 20, y: 41, width: 202, height: 101))
    }

    func testPixelCropStaysInsideImage() {
        let crop = SelectionGeometry.pixelCrop(
            CGRect(x: 990, y: 790, width: 100, height: 100),
            scale: 2,
            imageSize: CGSize(width: 2000, height: 1600))
        XCTAssertEqual(crop, CGRect(x: 1980, y: 1580, width: 20, height: 20))
    }

    func testHandleHitTest() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertEqual(SelectionGeometry.handle(at: CGPoint(x: 303, y: 297), in: rect, radius: 8), .bottomRight)
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 200, y: 180), in: rect, radius: 8))
    }

    func testLoupeFlipsAtEdges() {
        let origin = SelectionGeometry.loupeOrigin(
            cursor: CGPoint(x: 990, y: 790), size: 124, offset: 20, bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 846, y: 646))
    }
}

final class ShortcutTests: XCTestCase {
    func testDisplayStringOrder() {
        let shortcut = Shortcut(keyCode: 21, modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘4")
    }

    func testValidity() {
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: []).isValidGlobalShortcut)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [.shift]).isValidGlobalShortcut)
        XCTAssertTrue(Shortcut(keyCode: 0, modifiers: [.option]).isValidGlobalShortcut)
        XCTAssertTrue(Shortcut(keyCode: 122, modifiers: []).isValidGlobalShortcut)
    }

    func testDefaultsAreUniqueValidAndFreeOfSystemShortcuts() {
        let defaults = ShortcutAction.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(defaults).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy(\.isValidGlobalShortcut))
        XCTAssertTrue(SystemShortcuts.reserved(from: nil).isDisjoint(with: defaults))
    }

    func testMenuEquivalentOnlyForPlainKeys() {
        XCTAssertEqual(Shortcut(keyCode: 0, modifiers: [.command]).menuKeyEquivalent, "a")
        XCTAssertNil(Shortcut(keyCode: 123, modifiers: [.command]).menuKeyEquivalent)
        XCTAssertNil(Shortcut(keyCode: 122, modifiers: []).menuKeyEquivalent)
    }

    func testSystemDefaultsReservedWithoutPreferences() {
        XCTAssertTrue(SystemShortcuts.reserved(from: nil).contains(Shortcut(keyCode: 21, modifiers: [.shift, .command])))
    }

    func testDisabledSystemShortcutIsFree() {
        let prefs: [String: Any] = ["30": ["enabled": false]]
        XCTAssertFalse(SystemShortcuts.reserved(from: prefs).contains(Shortcut(keyCode: 21, modifiers: [.shift, .command])))
    }

    func testCustomSystemShortcutIsParsed() {
        let prefs: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [32, 49, 1048576], "type": "standard"]]
        ]
        XCTAssertTrue(SystemShortcuts.reserved(from: prefs).contains(Shortcut(keyCode: 49, modifiers: [.command])))
    }
}
