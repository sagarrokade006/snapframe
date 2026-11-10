import CoreGraphics
import XCTest

@testable import SnapframeCore

final class ThemeTests: XCTestCase {
    private let themes: [ThemePalette] = [.graphite, .daylight, .safelight, .deepSea, .aurora]

    func testEveryTextColorIsReadableOnEverySurface() {
        for theme in themes {
            for surface in [theme.ground, theme.sidebar, theme.card, theme.control, theme.raised] {
                for ink in [theme.text, theme.soft, theme.muted] {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(ink, surface), 4.5, String(format: "%06X on %06X", ink, surface))
                }
            }
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(theme.onText, theme.text), 4.5)
        }
    }

    func testAccentsWorkAsFillsAndAsText() {
        for accent in ThemeAccent.allCases {
            XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(0x17181A, accent.hex), 4.5, accent.title)
            for theme in themes {
                let text = theme.accentText(accent.hex)
                for surface in [theme.ground, theme.sidebar, theme.card, theme.raised] {
                    XCTAssertGreaterThanOrEqual(ThemeContrast.ratio(text, surface), 4.5, "\(accent.title) \(String(format: "%06X", surface))")
                }
            }
        }
    }

    func testSystemFollowsTheMac() {
        XCTAssertEqual(AppThemeID.system.palette(systemIsDark: true), .graphite)
        XCTAssertEqual(AppThemeID.system.palette(systemIsDark: false), .daylight)
        XCTAssertEqual(AppThemeID.aurora.palette(systemIsDark: false), .aurora)
    }

    func testDefaultLookIsUnchanged() {
        XCTAssertEqual(ThemePalette.graphite.ground, 0x101113)
        XCTAssertEqual(ThemePalette.graphite.text, 0xF4F3F0)
        XCTAssertEqual(ThemePalette.graphite.accentText(0xFF6B3D), 0xFF6B3D)
    }

    func testContrastOfBlackAndWhite() {
        XCTAssertEqual(ThemeContrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }
}

final class BackgroundTests: XCTestCase {
    func testCatalogSizes() {
        XCTAssertEqual(BackgroundCatalog.brandSolids.count, 8)
        XCTAssertEqual(BackgroundCatalog.solids.count, 40)
        XCTAssertEqual(BackgroundCatalog.brandGradients.count, 6)
        XCTAssertEqual(BackgroundCatalog.gradients.count, 24)
    }

    func testNoPresetIsRepeatedAndAllAreNamed() {
        let all = BackgroundCatalog.brandSolids + BackgroundCatalog.solids + BackgroundCatalog.brandGradients + BackgroundCatalog.gradients
        for (index, preset) in all.enumerated() {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertFalse(all[..<index].contains { $0.fill == preset.fill }, preset.name)
        }
    }

    func testOldProjectsStillOpen() throws {
        let old = CanvasStyle(fill: .gradient(1, 2), padding: 20, cornerRadius: 4, shadow: 0.5)
        let decoded = try JSONDecoder().decode(CanvasStyle.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded, old)
    }

    func testCustomGradientRoundTrip() throws {
        let fill = CanvasFill.linear([0x112233, 0x445566, 0x778899], angle: 40)
        XCTAssertEqual(try JSONDecoder().decode(CanvasFill.self, from: JSONEncoder().encode(fill)), fill)
        XCTAssertEqual(fill.gradientColors?.count, 3)
        XCTAssertTrue(fill.isGradient)
    }

    func testGradientLineDirections() {
        let size = CGSize(width: 100, height: 100)
        let right = CanvasFill.gradientLine(angle: 90, size: size)
        XCTAssertEqual(right.start.x, 0, accuracy: 0.001)
        XCTAssertEqual(right.end.x, 100, accuracy: 0.001)
        XCTAssertEqual(right.end.y, 50, accuracy: 0.001)

        let up = CanvasFill.gradientLine(angle: 0, size: size)
        XCTAssertEqual(up.start.y, 100, accuracy: 0.001)
        XCTAssertEqual(up.end.y, 0, accuracy: 0.001)

        let corner = CanvasFill.gradientLine(angle: 135, size: size)
        XCTAssertEqual(corner.start.x, 0, accuracy: 0.001)
        XCTAssertEqual(corner.start.y, 0, accuracy: 0.001)
        XCTAssertEqual(corner.end.x, 100, accuracy: 0.001)
    }

    func testSavingPutsNewestFirstWithoutDuplicates() {
        let first = CanvasFill.color(1), second = CanvasFill.color(2)
        XCTAssertEqual(BackgroundCatalog.saving(first, in: [second, first]), [first, second])
        XCTAssertEqual(BackgroundCatalog.saving(.none, in: [first]), [first])
    }

    func testSavingKeepsTheLimit() {
        let many = (0..<30).map { CanvasFill.color(UInt32($0)) }
        let saved = many.reduce([CanvasFill]()) { BackgroundCatalog.saving($1, in: $0) }
        XCTAssertEqual(saved.count, BackgroundCatalog.savedLimit)
        XCTAssertEqual(saved.first, .color(29))
    }
}
