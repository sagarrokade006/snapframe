import XCTest

@testable import SnapframeCore

final class AppVersionTests: XCTestCase {
    func testOrdering() {
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("v1.2")!, AppVersion("1.2.1")!)
        XCTAssertGreaterThan(AppVersion("2.0")!, AppVersion("1.99.99")!)
    }

    func testTrailingZerosAreEqual() {
        XCTAssertEqual(AppVersion("1.2.0")!, AppVersion("v1.2")!)
        XCTAssertFalse(AppVersion("1.2.0")! > AppVersion("1.2")!)
    }

    func testRejectsNonNumericVersions() {
        XCTAssertNil(AppVersion("1.2-beta"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
    }

    func testDescription() {
        XCTAssertEqual(AppVersion("v0.2.0")!.description, "0.2.0")
        XCTAssertEqual(AppVersion("2.0.0")!.description, "2.0.0")
        XCTAssertEqual(AppVersion("1.4.3")!.description, "1.4.3")
    }
}

final class ReleaseFeedTests: XCTestCase {
    private let prefix = ReleaseFeed.downloadPrefix(repository: "me/app")

    private func json(tag: String = "v1.2.0", assets: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","body":"Notes","assets":[\#(assets)]}"#.utf8)
    }

    private let dmg = #"{"name":"App.dmg","browser_download_url":"https://github.com/me/app/releases/download/v1.2.0/App.dmg","size":42}"#

    func testPicksDiskImage() throws {
        let zip = #"{"name":"App.zip","browser_download_url":"https://github.com/me/app/releases/download/v1.2.0/App.zip","size":9}"#
        let release = try ReleaseFeed.parse(json(assets: "\(zip),\(dmg)"), requiredPrefix: prefix)
        XCTAssertEqual(release.version, AppVersion("1.2.0"))
        XCTAssertEqual(release.size, 42)
        XCTAssertEqual(release.notes, "Notes")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "App.dmg")
    }

    func testMissingDiskImageFails() {
        XCTAssertThrowsError(try ReleaseFeed.parse(json(assets: ""), requiredPrefix: prefix)) {
            XCTAssertEqual($0 as? ReleaseFeedError, .missingDiskImage)
        }
    }

    func testBadTagFails() {
        XCTAssertThrowsError(try ReleaseFeed.parse(json(tag: "newest", assets: dmg), requiredPrefix: prefix)) {
            XCTAssertEqual($0 as? ReleaseFeedError, .invalidVersion("newest"))
        }
    }

    func testForeignDownloadIsRejected() {
        let other = #"{"name":"App.dmg","browser_download_url":"https://example.com/App.dmg","size":42}"#
        XCTAssertThrowsError(try ReleaseFeed.parse(json(assets: other), requiredPrefix: prefix)) {
            XCTAssertEqual($0 as? ReleaseFeedError, .untrustedDownload)
        }
    }

    func testOtherRepositoryIsRejected() {
        let other = #"{"name":"App.dmg","browser_download_url":"https://github.com/someone/else/releases/download/v1/App.dmg","size":42}"#
        XCTAssertThrowsError(try ReleaseFeed.parse(json(assets: other), requiredPrefix: prefix))
    }
}
