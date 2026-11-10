import AppKit
import AVFoundation
import Combine
import SnapframeCore
import SwiftUI

/// Owns the Studio window.
@MainActor
final class StudioController: NSObject, NSWindowDelegate {
    static let shared = StudioController()

    private var window: NSWindow?
    private(set) var session: StudioSession?

    func open(_ item: CaptureItem) {
        guard let path = item.savedPath else { return }
        open(package: URL(fileURLWithPath: path))
    }

    func open(package: URL) {
        guard let project = StudioPackage.load(package) else {
            let alert = NSAlert()
            alert.messageText = "This Studio project could not be opened."
            alert.runModal()
            return
        }
        closeWindow()

        let session = StudioSession(project: project, package: package)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = project.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let host = NSHostingView(rootView: StudioView(session: session))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(CGSize(width: 1280, height: 800))
        window.center()

        self.window = window
        self.session = session
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await session.load() }
    }

    private func closeWindow() {
        session?.teardown()
        window?.delegate = nil
        window?.close()
        window = nil
        session = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow()
        return false
    }
}

enum StudioTab: String, CaseIterable {
    case zoom = "Zoom", cursor = "Cursor", keys = "Keys", camera = "Camera", canvas = "Canvas", audio = "Audio"
}

@MainActor
final class StudioSession: ObservableObject {
    @Published var project: StudioProject
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var tab = StudioTab.zoom
    @Published var selectedClip: UUID?
    @Published var selectedZoom: UUID?
    @Published var waveform: [Float] = []
    @Published var message: String?
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var isLoading = true
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let player = AVPlayer()
    let package: URL

    private var history: EditHistory<StudioProject>
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private var videoComposition: AVMutableVideoComposition?
    private var exportSession: AVAssetExportSession?

    init(project: StudioProject, package: URL) {
        self.project = project
        self.package = package
        history = EditHistory(project)
        StudioRenderState.shared.project = project
    }

    func load() async {
        await rebuild()
        isLoading = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = time.seconds
            }
        }
        waveform = await StudioComposition.waveform(package: package, buckets: 500)
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        exportSession?.cancelExport()
        save()
    }

    private func save() { StudioPackage.save(project, to: package) }

    // MARK: Playback

    /// Needed whenever clips change, since the movie's structure is different.
    private func rebuild() async {
        StudioRenderState.shared.project = project
        do {
            let built = try await StudioComposition.build(project: project, package: package)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.video
            item.audioMix = built.audio
            videoComposition = built.video
            player.replaceCurrentItem(with: item)

            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isPlaying = false
                    self?.seek(to: 0)
                }
            }
            playhead = min(playhead, project.editedDuration)
            seek(to: playhead)
        } catch {
            message = error.localizedDescription
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= project.editedDuration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        playhead = min(max(time, 0), project.editedDuration)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Redraws the current frame after a style change. Quick repeated changes are combined.
    private func refreshFrame() {
        StudioRenderState.shared.project = project
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard let self, !Task.isCancelled, let item = self.player.currentItem, let current = self.videoComposition else { return }
            let size = StudioComposition.renderSize(for: self.project)
            if current.renderSize != size { current.renderSize = size }
            item.videoComposition = current.mutableCopy() as? AVVideoComposition
            if !self.isPlaying { self.seek(to: self.playhead) }
        }
    }

    // MARK: Edits

    /// Call when a gesture ends, so one drag counts as one undo step.
    func commit() {
        history.record(project)
        canUndo = history.canUndo
        canRedo = history.canRedo
        save()
    }

    func liveChange() { refreshFrame() }

    func changed() {
        refreshFrame()
        commit()
    }

    private func restore(_ state: StudioProject?) {
        guard let state else { return }
        let structureChanged = state.clips != project.clips
        project = state
        selectedClip = nil
        selectedZoom = nil
        canUndo = history.canUndo
        canRedo = history.canRedo
        save()
        if structureChanged {
            Task { await rebuild() }
        } else {
            refreshFrame()
        }
    }

    func undo() { restore(history.undo()) }
    func redo() { restore(history.redo()) }

    func splitAtPlayhead() {
        guard project.split(atTimeline: playhead) else {
            message = "Move the playhead further from the edge of the clip."
            return
        }
        commit()
        Task { await rebuild() }
    }

    func deleteSelectedClip() {
        guard let selectedClip, project.deleteClip(id: selectedClip) else { return }
        self.selectedClip = nil
        commit()
        Task { await rebuild() }
    }

    func trimEnded() {
        commit()
        Task { await rebuild() }
    }

    func addZoomAtPlayhead() {
        let start = project.sourceTime(at: playhead)
        let end = min(start + 2.5, project.duration)
        guard end - start >= 0.3 else { return }
        let zoom = ZoomSegment(start: start, end: end, level: 1.8)
        project.zooms.append(zoom)
        project.zooms.sort { $0.start < $1.start }
        selectedZoom = zoom.id
        tab = .zoom
        changed()
    }

    func deleteSelectedZoom() {
        guard let selectedZoom else { return }
        project.zooms.removeAll { $0.id == selectedZoom }
        self.selectedZoom = nil
        changed()
    }

    func autoZoom() {
        project.zooms = SmartZoom.analyze(clicks: project.clicks, mouse: project.mouse, duration: project.duration)
        selectedZoom = nil
        changed()
        if project.zooms.isEmpty { message = "No clicks to zoom into were found in this recording." }
    }

    func removeAllZooms() {
        project.zooms.removeAll()
        selectedZoom = nil
        changed()
    }

    var selectedZoomBinding: Binding<ZoomSegment>? {
        guard let selectedZoom, project.zooms.contains(where: { $0.id == selectedZoom }) else { return nil }
        return Binding(
            get: { self.project.zooms.first { $0.id == selectedZoom } ?? ZoomSegment(start: 0, end: 0, level: 1) },
            set: { value in
                guard let index = self.project.zooms.firstIndex(where: { $0.id == selectedZoom }) else { return }
                self.project.zooms[index] = value
                self.liveChange()
            }
        )
    }

    // MARK: Export

    func export(maximumHeight: Int) {
        guard !exporting else { return }
        player.pause()
        isPlaying = false
        exporting = true
        exportProgress = 0
        StudioRenderState.shared.project = project
        save()

        Task {
            defer { exporting = false }
            do {
                let settings = AppSettings.shared
                let manager = FileManager.default
                try manager.createDirectory(at: settings.exportDirectory, withIntermediateDirectories: true)
                let destination = NameTemplate.uniqueURL(directory: settings.exportDirectory, baseName: project.name, fileExtension: "mp4") {
                    manager.fileExists(atPath: $0.path)
                }

                let built = try await StudioComposition.build(project: project, package: package, maximumHeight: maximumHeight)
                guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                    throw RecordingError.writerFailed("The video could not be exported.")
                }
                session.videoComposition = built.video
                session.audioMix = built.audio
                session.outputURL = destination
                session.outputFileType = .mp4
                exportSession = session

                let poll = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.exportProgress = Double(session.progress)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                await session.export()
                poll.cancel()
                exportSession = nil

                guard session.status == .completed else {
                    if session.status != .cancelled {
                        throw RecordingError.writerFailed(session.error?.localizedDescription ?? "")
                    }
                    try? manager.removeItem(at: destination)
                    return
                }

                let library = CaptureLibrary.shared
                if let poster = await RecordingExport.poster(of: destination),
                   let item = await library.add(image: poster, scale: 1, kind: CaptureItem.recordingKind, name: project.name, formatTitle: "MP4", savedURL: destination) {
                    QuickAccessController.shared.show(item, message: "Exported to \(destination.deletingLastPathComponent().lastPathComponent)")
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancelExport() { exportSession?.cancelExport() }
}
