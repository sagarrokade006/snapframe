import AppKit
import AVFoundation
import AVKit
import SnapframeCore

/// Trims a recording with the system's trim controls.
@MainActor
final class TrimController: NSObject, NSWindowDelegate {
    static let shared = TrimController()

    private var window: NSWindow?

    func open(_ item: CaptureItem) {
        guard let path = item.savedPath, FileManager.default.fileExists(atPath: path) else {
            show("The recording file was moved or deleted.")
            return
        }
        window?.close()

        let url = URL(fileURLWithPath: path)
        let playerView = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 1000, height: 640))
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline

        let window = NSWindow(
            contentRect: playerView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Trim \(item.name)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = playerView
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Task { await beginTrimming(playerView, url: url, item: item) }
    }

    private func beginTrimming(_ playerView: AVPlayerView, url: URL, item: CaptureItem) async {
        for _ in 0..<40 {
            if playerView.player?.currentItem?.status == .readyToPlay, playerView.canBeginTrimming { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard playerView.canBeginTrimming else {
            show("This recording can't be trimmed.")
            window?.close()
            return
        }

        let result = await playerView.beginTrimming()
        defer {
            playerView.player?.pause()
            playerView.player = nil
            window?.close()
            window = nil
        }
        guard result == .okButton, let current = playerView.player?.currentItem else { return }

        let start = current.reversePlaybackEndTime.isValid ? current.reversePlaybackEndTime : .zero
        let end = current.forwardPlaybackEndTime.isValid ? current.forwardPlaybackEndTime : current.duration
        playerView.player?.replaceCurrentItem(with: nil)

        do {
            try await RecordingExport.trim(url, range: CMTimeRange(start: start, end: end))
            await CaptureLibrary.shared.refreshVideo(item)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
