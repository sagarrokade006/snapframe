import CoreGraphics
import XCTest

@testable import SnapframeCore

final class StudioTimelineTests: XCTestCase {
    private func project(_ duration: Double = 10) -> StudioProject {
        StudioProject(name: "t", duration: duration, pixelWidth: 100, pixelHeight: 100, scale: 2)
    }

    func testStartsAsOneClip() {
        XCTAssertEqual(project().clips.count, 1)
        XCTAssertEqual(project().editedDuration, 10)
    }

    func testSplitCreatesTwoClips() {
        var p = project()
        XCTAssertTrue(p.split(atTimeline: 4))
        XCTAssertEqual(p.clips.map(\.start), [0, 4])
        XCTAssertEqual(p.clips.map(\.end), [4, 10])
    }

    func testSplitTooCloseToEdgeIsRefused() {
        var p = project()
        XCTAssertFalse(p.split(atTimeline: 0.1))
        XCTAssertFalse(p.split(atTimeline: 9.95))
    }

    func testDeletingAClipShiftsTime() {
        var p = project()
        p.split(atTimeline: 3)
        p.split(atTimeline: 6)
        XCTAssertTrue(p.deleteClip(id: p.clips[1].id))
        XCTAssertEqual(p.editedDuration, 7)
        XCTAssertEqual(p.sourceTime(at: 2), 2)
        XCTAssertEqual(p.sourceTime(at: 3.5), 6.5)
        XCTAssertNil(p.timelineTime(forSource: 4))
        XCTAssertEqual(p.timelineTime(forSource: 7), 4)
    }

    func testLastClipCannotBeDeleted() {
        var p = project()
        XCTAssertFalse(p.deleteClip(id: p.clips[0].id))
    }

    func testSourceTimePastEndIsClamped() {
        XCTAssertEqual(project().sourceTime(at: 50), 10)
    }

    func testTrimStopsAtNeighborAndMinimum() {
        var p = project()
        p.split(atTimeline: 5)
        let second = p.clips[1].id
        p.trimClip(id: second, start: 1)
        XCTAssertEqual(p.clips[1].start, 5)
        p.trimClip(id: second, start: 7)
        XCTAssertEqual(p.clips[1].start, 7)
        p.trimClip(id: second, end: 7.05)
        XCTAssertEqual(p.clips[1].end, 7 + StudioProject.minimumClip, accuracy: 0.0001)
    }

    func testProjectRoundTrip() throws {
        var p = project()
        p.mouse = [MouseSample(t: 1, x: 0.1, y: 0.2)]
        p.clicks = [ClickEvent(t: 1, x: 0.1, y: 0.2)]
        p.keys = [KeyEvent(t: 2, parts: ["⌘", "K"])]
        p.windows = [WindowSample(t: 1, rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        p.zooms = [ZoomSegment(start: 1, end: 2, level: 1.5)]
        p.appearance.cursorStyle = .ring
        XCTAssertEqual(try StudioProject.decode(p.encoded()), p)
    }
}

final class SmartZoomTests: XCTestCase {
    func testOneClickMakesOneZoomAroundIt() {
        let zooms = SmartZoom.analyze(clicks: [ClickEvent(t: 5, x: 0.3, y: 0.4)], mouse: [], duration: 20)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].start, 4.5)
        XCTAssertEqual(zooms[0].end, 6.6, accuracy: 0.0001)
        XCTAssertEqual(zooms[0].centerX, 0.3)
        XCTAssertEqual(zooms[0].level, 1.5)
    }

    func testBusyAreaZoomsCloser() {
        let clicks = [ClickEvent(t: 5, x: 0.3, y: 0.4), ClickEvent(t: 5.5, x: 0.31, y: 0.41), ClickEvent(t: 6, x: 0.3, y: 0.42)]
        let zooms = SmartZoom.analyze(clicks: clicks, mouse: [], duration: 20)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].level, 1.9)
    }

    func testDistantMomentsStaySeparate() {
        let zooms = SmartZoom.analyze(clicks: [ClickEvent(t: 2, x: 0.2, y: 0.2), ClickEvent(t: 12, x: 0.8, y: 0.8)], mouse: [], duration: 20)
        XCTAssertEqual(zooms.count, 2)
    }

    func testCloseZoomsMerge() {
        let zooms = SmartZoom.analyze(clicks: [ClickEvent(t: 2, x: 0.2, y: 0.2), ClickEvent(t: 4.2, x: 0.8, y: 0.8)], mouse: [], duration: 20)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].end, 5.8, accuracy: 0.0001)
    }

    func testZoomStaysWithinRecording() {
        let zooms = SmartZoom.analyze(clicks: [ClickEvent(t: 0.1, x: 0.5, y: 0.5), ClickEvent(t: 9.9, x: 0.5, y: 0.5)], mouse: [], duration: 10)
        XCTAssertEqual(zooms.first?.start, 0)
        XCTAssertLessThanOrEqual(zooms.last?.end ?? 99, 10)
    }

    func testNoActivityNoZooms() {
        XCTAssertTrue(SmartZoom.analyze(clicks: [], mouse: [], duration: 10).isEmpty)
    }

    func testRestingAloneDoesNotZoom() {
        var mouse: [MouseSample] = [MouseSample(t: 0, x: 0.1, y: 0.1)]
        for step in 1...40 { mouse.append(MouseSample(t: Double(step) * 0.1, x: 0.5, y: 0.5)) }
        mouse.append(MouseSample(t: 4.5, x: 0.9, y: 0.9))
        XCTAssertTrue(SmartZoom.analyze(clicks: [], mouse: mouse, duration: 10).isEmpty)
    }

    func testRestingNearAClickBoostsIt() {
        var mouse: [MouseSample] = [MouseSample(t: 0, x: 0.1, y: 0.1)]
        for step in 1...40 { mouse.append(MouseSample(t: Double(step) * 0.1, x: 0.5, y: 0.5)) }
        mouse.append(MouseSample(t: 4.5, x: 0.9, y: 0.9))
        let zooms = SmartZoom.analyze(clicks: [ClickEvent(t: 0.6, x: 0.5, y: 0.5)], mouse: mouse, duration: 10)
        XCTAssertEqual(zooms.count, 1)
    }
}

final class StudioMotionTests: XCTestCase {
    private let samples = [MouseSample(t: 0, x: 0, y: 0), MouseSample(t: 1, x: 1, y: 0.5)]

    func testInterpolationAndEnds() {
        let middle = StudioMotion.interpolated(samples, at: 0.5)
        XCTAssertEqual(middle?.x, 0.5)
        XCTAssertEqual(middle?.y, 0.25)
        XCTAssertEqual(StudioMotion.interpolated(samples, at: -1)?.x, 0)
        XCTAssertEqual(StudioMotion.interpolated(samples, at: 9)?.x, 1)
        XCTAssertNil(StudioMotion.interpolated([], at: 0))
    }

    func testSmoothingStaysOnAStraightLine() {
        let smooth = StudioMotion.cursor(samples, at: 0.5, smooth: true)
        XCTAssertEqual(smooth?.x ?? 0, 0.5, accuracy: 0.0001)
    }

    func testSmoothingSoftensAJump() {
        let jump = [MouseSample(t: 0, x: 0, y: 0), MouseSample(t: 1, x: 0, y: 0), MouseSample(t: 1.001, x: 1, y: 0), MouseSample(t: 2, x: 1, y: 0)]
        let value = StudioMotion.cursor(jump, at: 1, smooth: true)?.x ?? 0
        XCTAssertGreaterThan(value, 0.2)
        XCTAssertLessThan(value, 0.8)
    }

    func testCursorFadesWhenIdle() {
        let moving = [MouseSample(t: 0, x: 0, y: 0), MouseSample(t: 1, x: 0.5, y: 0.5), MouseSample(t: 10, x: 0.5, y: 0.5)]
        XCTAssertEqual(StudioMotion.cursorOpacity(moving, at: 1.5), 1)
        XCTAssertEqual(StudioMotion.cursorOpacity(moving, at: 8), 0, accuracy: 0.001)
    }

    func testCameraOutsideZoomIsWide() {
        let camera = StudioMotion.camera(zooms: [ZoomSegment(start: 2, end: 4, level: 2)], cursor: (0.1, 0.1), at: 1)
        XCTAssertEqual(camera, StudioMotion.Camera(level: 1, x: 0.5, y: 0.5))
    }

    func testCameraReachesFullLevelInTheMiddle() {
        let zoom = ZoomSegment(start: 2, end: 6, level: 2, centerX: 0.5, centerY: 0.5)
        XCTAssertEqual(StudioMotion.camera(zooms: [zoom], cursor: nil, at: 4).level, 2)
    }

    func testCameraEasesInAndOut() {
        let zoom = ZoomSegment(start: 2, end: 6, level: 2, centerX: 0.5, centerY: 0.5)
        let early = StudioMotion.camera(zooms: [zoom], cursor: nil, at: 2.2).level
        XCTAssertGreaterThan(early, 1)
        XCTAssertLessThan(early, 2)
        XCTAssertEqual(StudioMotion.camera(zooms: [zoom], cursor: nil, at: 5.8).level, early, accuracy: 0.0001)
    }

    func testCameraNeverShowsPastTheEdge() {
        let zoom = ZoomSegment(start: 0, end: 10, level: 2)
        let camera = StudioMotion.camera(zooms: [zoom], cursor: (0.01, 0.99), at: 5)
        XCTAssertEqual(camera.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(camera.y, 0.75, accuracy: 0.0001)
    }

    func testFixedZoomIgnoresCursor() {
        let zoom = ZoomSegment(start: 0, end: 10, level: 2, centerX: 0.6, centerY: 0.4)
        let camera = StudioMotion.camera(zooms: [zoom], cursor: (0.9, 0.9), at: 5)
        XCTAssertEqual(camera.x, 0.6, accuracy: 0.0001)
    }

    func testClickProgress() {
        let clicks = [ClickEvent(t: 1, x: 0, y: 0)]
        XCTAssertEqual(StudioMotion.clickProgress(clicks, at: 1.225)?.progress ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertNil(StudioMotion.clickProgress(clicks, at: 2))
    }

    func testActiveKeysExpire() {
        let keys = [KeyEvent(t: 1, parts: ["⌘", "K"])]
        XCTAssertNotNil(StudioMotion.activeKeys(keys, at: 2))
        XCTAssertNil(StudioMotion.activeKeys(keys, at: 3))
    }
}
