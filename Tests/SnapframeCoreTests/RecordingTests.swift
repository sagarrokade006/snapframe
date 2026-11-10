import XCTest

@testable import SnapframeCore

final class PauseClockTests: XCTestCase {
    func testPositionsStartAtZero() {
        var clock = PauseClock()
        clock.begin(at: 100)
        XCTAssertEqual(clock.position(of: 100), 0)
        XCTAssertEqual(clock.position(of: 102.5), 2.5)
    }

    func testBeginOnlyOnce() {
        var clock = PauseClock()
        clock.begin(at: 100)
        clock.begin(at: 200)
        XCTAssertEqual(clock.start, 100)
    }

    func testSamplesBeforeStartAreDropped() {
        var clock = PauseClock()
        XCTAssertNil(clock.position(of: 50))
        clock.begin(at: 100)
        XCTAssertNil(clock.position(of: 99))
    }

    func testPausedSamplesAreDropped() {
        var clock = PauseClock()
        clock.begin(at: 100)
        clock.pause(at: 105)
        XCTAssertNil(clock.position(of: 106))
        XCTAssertTrue(clock.isPaused)
    }

    func testPausedTimeIsRemoved() {
        var clock = PauseClock()
        clock.begin(at: 100)
        clock.pause(at: 105)
        clock.resume(at: 110)
        XCTAssertEqual(clock.position(of: 111), 6)
        clock.pause(at: 112)
        clock.resume(at: 120)
        XCTAssertEqual(clock.position(of: 121), 8)
    }

    func testElapsedFreezesWhilePaused() {
        var clock = PauseClock()
        clock.begin(at: 100)
        XCTAssertEqual(clock.elapsed(at: 103), 3)
        clock.pause(at: 104)
        XCTAssertEqual(clock.elapsed(at: 150), 4)
        clock.resume(at: 200)
        XCTAssertEqual(clock.elapsed(at: 201), 5)
    }

    func testRepeatedPauseKeepsFirst() {
        var clock = PauseClock()
        clock.begin(at: 100)
        clock.pause(at: 101)
        clock.pause(at: 150)
        clock.resume(at: 160)
        XCTAssertEqual(clock.pausedTotal, 59)
    }

    func testPauseBeforeStartDoesNothing() {
        var clock = PauseClock()
        clock.pause(at: 10)
        XCTAssertFalse(clock.isPaused)
    }
}

final class RecordingFormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(RecordingFormat.clock(0), "00:00")
        XCTAssertEqual(RecordingFormat.clock(65.9), "01:05")
        XCTAssertEqual(RecordingFormat.clock(3725), "1:02:05")
        XCTAssertEqual(RecordingFormat.clock(-3), "00:00")
    }

    func testOutputSizeIsEven() {
        let size = RecordingFormat.outputSize(width: 1201, height: 661, maximumHeight: 0)
        XCTAssertEqual(size.width, 1200)
        XCTAssertEqual(size.height, 660)
    }

    func testOutputSizeRespectsLimit() {
        let size = RecordingFormat.outputSize(width: 3840, height: 2160, maximumHeight: 1080)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testSmallerThanLimitIsUnchanged() {
        let size = RecordingFormat.outputSize(width: 800, height: 600, maximumHeight: 1080)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testGIFTimes() {
        XCTAssertEqual(RecordingFormat.gifFrameTimes(duration: 2, framesPerSecond: 2, maximumFrames: 100), [0, 0.5, 1, 1.5])
    }

    func testGIFRespectsFrameLimit() {
        let times = RecordingFormat.gifFrameTimes(duration: 100, framesPerSecond: 15, maximumFrames: 300)
        XCTAssertEqual(times.count, 300)
        XCTAssertEqual(times[1], 100.0 / 300.0, accuracy: 0.0001)
    }

    func testGIFEmptyForNoDuration() {
        XCTAssertTrue(RecordingFormat.gifFrameTimes(duration: 0, framesPerSecond: 15, maximumFrames: 10).isEmpty)
    }

    func testManifestRoundTrip() throws {
        let manifest = RecordingManifest(startedAt: Date(timeIntervalSince1970: 100), isGIF: true)
        XCTAssertEqual(try JSONDecoder().decode(RecordingManifest.self, from: JSONEncoder().encode(manifest)), manifest)
    }

    func testVideoKinds() {
        func item(_ kind: String) -> CaptureItem {
            CaptureItem(name: "a", kind: kind, createdAt: Date(), pixelWidth: 1, pixelHeight: 1, scale: 1, formatTitle: "MP4", byteCount: 1, savedPath: nil)
        }
        XCTAssertTrue(item(CaptureItem.recordingKind).isVideo)
        XCTAssertTrue(item(CaptureItem.recordingKind).canTrim)
        XCTAssertTrue(item(CaptureItem.gifKind).isVideo)
        XCTAssertFalse(item(CaptureItem.gifKind).canTrim)
        XCTAssertFalse(item("Area").isVideo)
    }
}
