#if DEBUG
import Foundation
import SnapframeCore

/// Debug-only check: runs a whole update, without the UI or relaunch, from a local feed file.
@MainActor
enum UpdateSelfTest {
    static func run(feed: URL) async {
        do {
            guard let release = try await UpdateService.fetchLatest(from: feed, requiredPrefix: nil) else {
                print("no release")
                exit(0)
            }
            guard release.version > UpdateService.currentVersion else {
                print("up to date: \(UpdateService.currentVersion)")
                exit(0)
            }
            let diskImage = try await UpdateService.download(release)
            try UpdateService.install(diskImage: diskImage, release: release)
            print("installed \(release.version)")
            exit(0)
        } catch {
            print("refused: \(error.localizedDescription)")
            exit(3)
        }
    }
}
#endif
