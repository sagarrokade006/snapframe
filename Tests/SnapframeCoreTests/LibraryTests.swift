import CoreGraphics
import XCTest

@testable import SnapframeCore

final class LibraryIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, kind: String = "Area", daysOld: Double = 0, pinned: Bool = false, tags: [String] = []) -> CaptureItem {
        CaptureItem(
            name: name, kind: kind, createdAt: now.addingTimeInterval(-daysOld * 86_400),
            pixelWidth: 100, pixelHeight: 50, scale: 2, formatTitle: "PNG", byteCount: 10,
            savedPath: nil, tags: tags, isPinned: pinned
        )
    }

    func testAddPutsNewestFirst() {
        var index = LibraryIndex()
        index.add(item("old"))
        index.add(item("new"))
        XCTAssertEqual(index.items.map(\.name), ["new", "old"])
    }

    func testFiltersCombine() {
        let index = LibraryIndex(items: [
            item("Launch notes", kind: "Area", tags: ["Design"]),
            item("Pricing", kind: "Window", pinned: true),
            item("Launch page", kind: "Window", tags: ["design"]),
        ])
        XCTAssertEqual(index.filtered(kind: "Window", tag: nil, query: "", pinnedOnly: false).count, 2)
        XCTAssertEqual(index.filtered(kind: nil, tag: nil, query: "launch", pinnedOnly: false).count, 2)
        XCTAssertEqual(index.filtered(kind: nil, tag: nil, query: "", pinnedOnly: true).map(\.name), ["Pricing"])
        XCTAssertEqual(index.filtered(kind: nil, tag: "Design", query: "", pinnedOnly: false).map(\.name), ["Launch notes"])
        XCTAssertEqual(index.filtered(kind: nil, tag: nil, query: "design", pinnedOnly: false).count, 2)
    }

    func testPurgeKeepsPinnedAndRecent() {
        var index = LibraryIndex(items: [item("recent", daysOld: 2), item("old", daysOld: 40), item("oldPinned", daysOld: 40, pinned: true)])
        let removed = index.purge(olderThanDays: 30, now: now)
        XCTAssertEqual(removed.map(\.name), ["old"])
        XCTAssertEqual(index.items.map(\.name), ["recent", "oldPinned"])
    }

    func testPurgeZeroKeepsEverything() {
        var index = LibraryIndex(items: [item("old", daysOld: 4000)])
        XCTAssertTrue(index.purge(olderThanDays: 0, now: now).isEmpty)
        XCTAssertEqual(index.items.count, 1)
    }

    func testTagsAreUniqueIgnoringCaseAndTrimmed() {
        let thing = item("a")
        var index = LibraryIndex(items: [thing])
        index.addTag("  Bugs ", to: thing.id)
        index.addTag("bugs", to: thing.id)
        index.addTag("   ", to: thing.id)
        XCTAssertEqual(index.items[0].tags, ["Bugs"])
        index.removeTag("Bugs", from: thing.id)
        XCTAssertTrue(index.items[0].tags.isEmpty)
    }

    func testAllTagsMergesCase() {
        let index = LibraryIndex(items: [item("a", tags: ["Design"]), item("b", tags: ["design", "Bugs"])])
        XCTAssertEqual(index.allTags, ["Bugs", "Design"])
    }

    func testIndexRoundTripsThroughJSON() throws {
        let index = LibraryIndex(items: [item("a", tags: ["x"])])
        let decoded = try JSONDecoder().decode(LibraryIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(decoded, index)
    }
}

final class AspectSelectionTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testRatioIsKept() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 500, y: 150),
            aspect: CaptureAspect.sixteenNine.value, bounds: bounds)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
    }

    func testTallDragDrivesWidth() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 100, y: 100), current: CGPoint(x: 120, y: 400),
            aspect: CaptureAspect.fourThree.value, bounds: bounds)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
    }

    func testRatioStaysInsideDisplay() {
        let rect = SelectionGeometry.rect(
            anchor: CGPoint(x: 900, y: 700), current: CGPoint(x: 2000, y: 2000),
            aspect: CaptureAspect.sixteenNine.value, bounds: bounds)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.001)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.001)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
    }
}

final class ChipAndChangelogTests: XCTestCase {
    func testChipsRoundTrip() {
        let chips = NameTemplate.chips(from: "Snapframe {date}  at {time}")
        XCTAssertEqual(chips, ["Snapframe", "{date}", "at", "{time}"])
        XCTAssertEqual(NameTemplate.pattern(from: chips), "Snapframe {date} at {time}")
    }

    func testChipTitles() {
        XCTAssertEqual(NameTemplate.chipTitle("{date}"), "Date")
        XCTAssertEqual(NameTemplate.chipTitle("Snapframe"), "Snapframe")
    }

    func testChangelogLabels() {
        let entries = Changelog.parse("""
        ## Changelog

        Intro sentence.

        - Fixed: shortcuts after restart
        - Added the app icon
        - Improved overlay speed
        - Screenshots in the README
        """)
        XCTAssertEqual(entries, [
            ChangelogEntry(kind: .fixed, text: "Shortcuts after restart"),
            ChangelogEntry(kind: .new, text: "Added the app icon"),
            ChangelogEntry(kind: .better, text: "Improved overlay speed"),
            ChangelogEntry(kind: .note, text: "Screenshots in the README"),
        ])
    }

    func testChangelogWithoutBulletsUsesLines() {
        XCTAssertEqual(Changelog.parse("# Title\nJust text"), [ChangelogEntry(kind: .note, text: "Just text")])
    }

    func testShortcutParts() {
        XCTAssertEqual(Shortcut(keyCode: 21, modifiers: [.control, .option]).keyParts, ["⌃", "⌥", "4"])
    }
}
