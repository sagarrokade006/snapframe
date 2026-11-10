import CoreGraphics
import XCTest

@testable import SnapframeCore

final class ScrollMatcherTests: XCTestCase {
    private func page(_ count: Int, seed: UInt64 = 7) -> [RowSignature] {
        (0..<count).map { RowSignature(hash: UInt64($0) &* 2_654_435_761 &+ seed, isFlat: false) }
    }

    private func flat() -> RowSignature { RowSignature(hash: 1, isFlat: true) }

    private func frame(_ content: [RowSignature], top: Int, height: Int, header: [RowSignature] = [], footer: [RowSignature] = []) -> [RowSignature] {
        header + Array(content[top..<(top + height)]) + footer
    }

    func testUnchanged() {
        let rows = page(600)
        XCTAssertEqual(ScrollMatcher.compare(previous: rows, current: rows), .unchanged)
    }

    func testPlainScroll() {
        let content = page(2000)
        let a = frame(content, top: 0, height: 600), b = frame(content, top: 137, height: 600)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .moved(offset: 137, footer: 0))
    }

    func testFixedHeaderAndFooter() {
        let content = page(2000)
        let header = page(50, seed: 99), footer = page(30, seed: 123)
        let a = frame(content, top: 0, height: 500, header: header, footer: footer)
        let b = frame(content, top: 80, height: 500, header: header, footer: footer)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .moved(offset: 80, footer: 30))
    }

    func testSolidPartsOfBarsCountAsFixed() {
        let content = page(4000)
        let solid = RowSignature(hash: 5, isFlat: true)
        let header = Array(repeating: solid, count: 20) + page(10, seed: 3) + Array(repeating: solid, count: 30)
        let footer = Array(repeating: solid, count: 18) + page(8, seed: 4) + Array(repeating: solid, count: 14)
        let a = frame(content, top: 0, height: 700, header: header, footer: footer)
        let b = frame(content, top: 410, height: 700, header: header, footer: footer)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .moved(offset: 410, footer: 40))
    }

    func testScrollingUpIsReported() {
        let content = page(2000)
        let a = frame(content, top: 200, height: 600), b = frame(content, top: 100, height: 600)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .reversed)
    }

    func testNoOverlapIsLost() {
        let content = page(3000)
        let a = frame(content, top: 0, height: 600), b = frame(content, top: 1500, height: 600)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .lost)
    }

    func testToleratesSmallChange() {
        let content = page(2000)
        let a = frame(content, top: 0, height: 600)
        var b = frame(content, top: 90, height: 600)
        b[200] = RowSignature(hash: 42, isFlat: false)
        b[201] = RowSignature(hash: 43, isFlat: false)
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .moved(offset: 90, footer: 0))
    }

    func testBlankMarginIsNotAFixedBar() {
        var content = page(2000)
        for index in 0..<40 { content[index] = flat() }
        let a = frame(content, top: 0, height: 600)
        var b = frame(content, top: 20, height: 600)
        for index in 0..<20 { b[index] = flat() }
        guard case .moved(let offset, _) = ScrollMatcher.compare(previous: a, current: b) else { return XCTFail("Should move") }
        XCTAssertEqual(offset, 20)
    }

    func testAllBlankFramesAreNotAMove() {
        let blank = Array(repeating: flat(), count: 600)
        XCTAssertEqual(ScrollMatcher.compare(previous: blank, current: blank), .unchanged)
    }

    func testSmallPixelDifferencesStillMatch() {
        let profile = { (row: Int) -> [UInt8] in (0..<40).map { UInt8((row &* 31 &+ $0 &* 17) % 200 + 20) } }
        let a = (0..<600).map { RowSignature(hash: UInt64($0), isFlat: false, profile: profile($0 + 100)) }
        let b = (0..<600).map { row -> RowSignature in
            var noisy = profile(row + 100 + 75)
            noisy[row % 40] &+= 2
            return RowSignature(hash: UInt64(row + 5000), isFlat: false, profile: noisy)
        }
        XCTAssertEqual(ScrollMatcher.compare(previous: a, current: b), .moved(offset: 75, footer: 0))
    }

    func testDifferentSizesAreLost() {
        XCTAssertEqual(ScrollMatcher.compare(previous: page(10), current: page(11)), .lost)
    }

    func testNewRowsSitAboveFooter() {
        XCTAssertEqual(ScrollMatcher.newRows(rowCount: 600, offset: 80, footer: 30), 490..<570)
    }
}

final class TextComposerTests: XCTestCase {
    func testReadingOrder() {
        let fragments = [
            TextFragment(text: "world", x: 100, y: 10, height: 20),
            TextFragment(text: "Second", x: 10, y: 50, height: 20),
            TextFragment(text: "Hello", x: 10, y: 12, height: 20),
        ]
        XCTAssertEqual(TextComposer.compose(fragments, keepLineBreaks: true), "Hello world\nSecond")
        XCTAssertEqual(TextComposer.compose(fragments, keepLineBreaks: false), "Hello world Second")
    }

    func testEmpty() {
        XCTAssertEqual(TextComposer.compose([], keepLineBreaks: true), "")
    }
}

final class CapturedLinkTests: XCTestCase {
    func testOnlyWebLinksOpen() {
        XCTAssertNotNil(CapturedLink.openableURL(" https://example.com/a "))
        XCTAssertNotNil(CapturedLink.openableURL("HTTP://example.com"))
        XCTAssertNil(CapturedLink.openableURL("file:///etc/passwd"))
        XCTAssertNil(CapturedLink.openableURL("javascript:alert(1)"))
        XCTAssertNil(CapturedLink.openableURL("snapframe://capture-area"))
        XCTAssertNil(CapturedLink.openableURL("https://"))
        XCTAssertNil(CapturedLink.openableURL("just text"))
    }
}

final class AutomationCommandTests: XCTestCase {
    private func parse(_ text: String) -> AutomationCommand? { AutomationCommand.parse(URL(string: text)!) }

    func testCaptureCommands() {
        XCTAssertEqual(parse("snapframe://capture-window"), .capture(.window))
        XCTAssertEqual(parse("snapframe://scrolling-capture"), .capture(.scrolling))
        XCTAssertEqual(parse("snapframe://capture-text"), .capture(.text))
        XCTAssertEqual(parse("snapframe://record-screen"), .capture(.record))
        XCTAssertEqual(parse("SNAPFRAME://Capture-Fullscreen"), .capture(.fullscreen))
    }

    func testAreaWithoutRegionUsesOverlay() {
        XCTAssertEqual(parse("snapframe://capture-area"), .capture(.area))
    }

    func testRegion() {
        XCTAssertEqual(parse("snapframe://capture-area?x=10&y=20&width=300&height=200&display=1"), .captureRegion(CGRect(x: 10, y: 20, width: 300, height: 200), display: 1))
    }

    func testBadRegionIsRejected() {
        XCTAssertNil(parse("snapframe://capture-area?x=10&y=20&width=0&height=200"))
        XCTAssertNil(parse("snapframe://capture-area?x=-5&y=20&width=10&height=200"))
    }

    func testIconsAndWindows() {
        XCTAssertEqual(parse("snapframe://toggle-desktop-icons"), .icons(.toggle))
        XCTAssertEqual(parse("snapframe://hide-desktop-icons"), .icons(.hide))
        XCTAssertEqual(parse("snapframe://open-home"), .openHome)
    }

    func testUnknownIsRejected() {
        XCTAssertNil(parse("snapframe://delete-everything"))
        XCTAssertNil(parse("https://capture-area"))
    }
}
