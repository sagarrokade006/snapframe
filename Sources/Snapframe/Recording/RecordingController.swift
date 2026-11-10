import ApplicationServices
import AVFoundation
import AppKit
import Combine
import ScreenCaptureKit
import SnapframeCore
import SwiftUI

struct RecordingOutput {
    let movie: URL
    let mode: RecordMode
    var isGIF: Bool { mode == .gif }
}

/// Runs a recording from setup to stop. Only the HUD and setup panel stay out of the video.
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var level: Float = 0
    @Published private(set) var usesMicrophone = false

    private enum Command { case stop, discard, restart }

    private var writer: RecordingWriter?
    private var commandContinuation: CheckedContinuation<Command, Never>?
    private var setupContinuation: CheckedContinuation<Bool, Never>?
    private var outline: NSPanel?
    private var hud: NSPanel?
    private var setup: NSPanel?
    private var ticker: Timer?
    private var activeCamera: CameraBubble?

    private static let minimumStartBytes: Int64 = 1_000_000_000
    private static let minimumRunningBytes: Int64 = 300_000_000

    // MARK: Commands from the HUD

    func requestStop() { send(.stop) }
    func discard() { send(.discard) }
    func restart() { send(.restart) }

    private func send(_ command: Command) {
        commandContinuation?.resume(returning: command)
        commandContinuation = nil
    }

    func togglePause() {
        guard let writer else { return }
        if isPaused {
            writer.resume()
            activeCamera?.resumeFile()
        } else {
            writer.pause()
            activeCamera?.pauseFile()
        }
        isPaused.toggle()
    }

    func finishSetup(start: Bool) {
        setupContinuation?.resume(returning: start)
        setupContinuation = nil
    }

    // MARK: Flow

    func run(displayID: CGDirectDisplayID, rect: CGRect, showsCursor: Bool) async throws -> RecordingOutput? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { throw RecordingError.displayNotFound }
        guard RecordingExport.hasEnoughSpace(minimumBytes: Self.minimumStartBytes) else { throw RecordingError.lowDisk }

        let region = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        showOutline(region)
        defer { closeOutline() }

        guard await askForOptions(region: region, screen: screen) else { return nil }

        let settings = AppSettings.shared
        let mode = settings.recordMode
        let isGIF = mode == .gif
        var useMicrophone = false
        if !isGIF && settings.recordMicrophone { useMicrophone = await AVCaptureDevice.requestAccess(for: .audio) }
        var useCamera = false
        if !isGIF && settings.recordCamera { useCamera = await AVCaptureDevice.requestAccess(for: .video) }
        let useSystem = !isGIF && settings.recordSystemAudio
        if settings.recordKeystrokes {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }

        while true {
            guard await CountdownController.run(seconds: 3) else { return nil }
            let result = try await record(
                displayID: displayID, rect: rect, region: region, screen: screen, showsCursor: showsCursor,
                mode: mode, useSystem: useSystem, useMicrophone: useMicrophone, useCamera: useCamera
            )
            switch result {
            case .finished(let output): return output
            case .discarded: return nil
            case .restart: continue
            }
        }
    }

    private enum Result {
        case finished(RecordingOutput)
        case discarded
        case restart
    }

    private func record(
        displayID: CGDirectDisplayID, rect: CGRect, region: CGRect, screen: NSScreen, showsCursor: Bool,
        mode: RecordMode, useSystem: Bool, useMicrophone: Bool, useCamera: Bool
    ) async throws -> Result {
        let settings = AppSettings.shared
        let isGIF = mode == .gif
        let isStudio = mode == .studio
        let workspace = try isStudio ? StudioPackage.create() : RecordingExport.makeWorkspace(isGIF: isGIF)

        // Studio redraws the cursor, clicks, keys and camera later, so they stay out of the screen video.
        let cameraFile = isStudio && useCamera ? workspace.appendingPathComponent(StudioProject.cameraFile) : nil
        let camera = useCamera ? CameraBubble(region: region, recordingTo: cameraFile) : nil
        let activity = isStudio ? nil : ActivityOverlay(region: region, clicks: settings.recordClicks, keys: settings.recordKeystrokes)
        activeCamera = camera
        defer {
            camera?.close()
            activity?.close()
            activeCamera = nil
        }
        let included = Set(isStudio ? [] : [camera?.windowID, activity?.windowID].compactMap { $0 })

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw RecordingError.displayNotFound }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == getpid() },
            exceptingWindows: content.windows.filter { included.contains($0.windowID) || DesktopIconCover.shared.windowIDs.contains($0.windowID) }
        )
        let scale = CGFloat(filter.pointPixelScale)
        let size = RecordingFormat.outputSize(
            width: Int(rect.width * scale), height: Int(rect.height * scale), maximumHeight: settings.recordMaximumHeight
        )
        let frameRate = isGIF ? min(settings.recordFramesPerSecond, 30) : settings.recordFramesPerSecond

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = showsCursor && !isStudio
        configuration.capturesAudio = useSystem
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let movie = isStudio ? workspace.appendingPathComponent(StudioProject.screenFile) : RecordingExport.movieURL(in: workspace)
        let writer = try RecordingWriter(
            url: movie, width: size.width, height: size.height, framesPerSecond: frameRate,
            system: useSystem, microphone: useMicrophone
        )
        let recorder = ScreenRecorder(writer: writer, filter: filter, configuration: configuration)
        recorder.onLevel = { [weak self] value in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.level = value } }
        }
        recorder.onFailure = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestStop() } }
        }

        do {
            try await recorder.start(system: useSystem, useMicrophone: useMicrophone)
        } catch {
            writer.cancel()
            RecordingExport.removeWorkspace(of: movie)
            throw error
        }

        var tracker: StudioTracker?
        var project = StudioProject(
            name: NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: "Studio"),
            duration: 0, pixelWidth: size.width, pixelHeight: size.height, scale: Double(size.width) / Double(rect.width)
        )
        project.hasCamera = cameraFile != nil
        project.hasSystemAudio = useSystem
        project.hasMicrophone = useMicrophone

        func saveProgress() {
            guard let tracker else { return }
            project.mouse = tracker.mouse
            project.clicks = tracker.clicks
            project.keys = tracker.keys
            project.windows = tracker.windows
            StudioPackage.save(project, to: workspace)
        }
        if isStudio {
            tracker = StudioTracker(
                region: region, elapsed: { writer.elapsed }, isPaused: { [weak self] in self?.isPaused ?? false },
                logsKeys: settings.recordKeystrokes, autosave: { saveProgress() }
            )
            saveProgress()
            tracker?.start()
            camera?.startFile { project.cameraOffset = writer.elapsed }
        }

        self.writer = writer
        isPaused = false
        elapsed = 0
        usesMicrophone = useMicrophone
        isRecording = true
        showHUD(region: region, screen: screen)
        startTicker()

        let command = await withCheckedContinuation { self.commandContinuation = $0 }

        stopTicker()
        closeHUD()
        isRecording = false
        self.writer = nil
        await recorder.stop()
        tracker?.stop()
        if command == .stop { await camera?.finishFile() }

        switch command {
        case .stop:
            do {
                try await writer.finish()
            } catch {
                RecordingExport.removeWorkspace(of: movie)
                throw error
            }
            if isStudio { saveProgress() }
            return .finished(RecordingOutput(movie: movie, mode: mode))
        case .discard:
            writer.cancel()
            RecordingExport.removeWorkspace(of: movie)
            return .discarded
        case .restart:
            writer.cancel()
            RecordingExport.removeWorkspace(of: movie)
            return .restart
        }
    }

    private func startTicker() {
        var checks = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let writer = self.writer else { return }
                self.elapsed = writer.elapsed
                checks += 1
                if checks % 20 == 0, !RecordingExport.hasEnoughSpace(minimumBytes: Self.minimumRunningBytes) {
                    self.requestStop()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Panels

    private func showOutline(_ region: CGRect) {
        let panel = KeylessPanel(size: CGSize(width: region.width + 8, height: region.height + 8))
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: Rectangle().stroke(Color.snapAccent, lineWidth: 2).padding(1))
        panel.setFrameOrigin(CGPoint(x: region.minX - 4, y: region.minY - 4))
        panel.orderFrontRegardless()
        outline = panel
    }

    private func closeOutline() {
        outline?.close()
        outline = nil
    }

    private func askForOptions(region: CGRect, screen: NSScreen) async -> Bool {
        let size = CGSize(width: 300, height: 392)
        let panel = KeylessPanel(size: size)
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: RecordingSetupView(controller: self))

        let area = screen.visibleFrame
        var x = region.maxX + 16
        if x + size.width > area.maxX { x = region.minX - 16 - size.width }
        if x < area.minX { x = area.midX - size.width / 2 }
        let y = min(max(region.midY - size.height / 2, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
        setup = panel

        let start = await withCheckedContinuation { self.setupContinuation = $0 }
        setup?.close()
        setup = nil
        return start
    }

    private func showHUD(region: CGRect, screen: NSScreen) {
        let size = CGSize(width: 480, height: 64)
        let panel = KeylessPanel(size: size)
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: RecordingHUDView(controller: self))

        let area = screen.visibleFrame
        let below = region.minY - size.height - 12
        let y = below >= area.minY + 8 ? below : area.minY + 24
        panel.setFrameOrigin(CGPoint(x: region.midX - size.width / 2, y: y))
        panel.orderFrontRegardless()
        hud = panel
    }

    private func closeHUD() {
        hud?.close()
        hud = nil
    }
}

struct RecordingSetupView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Record").font(.snapDisplay(18))

            PillSegment(
                options: RecordMode.allCases.map { ($0, $0.title) },
                selection: $settings.recordMode,
                activeFill: .snapText
            )

            VStack(spacing: 2) {
                row("Microphone", "mic", $settings.recordMicrophone, enabled: settings.recordMode != .gif)
                row("System audio", "speaker.wave.2", $settings.recordSystemAudio, enabled: settings.recordMode != .gif)
                row("Camera", "video", $settings.recordCamera, enabled: settings.recordMode != .gif)
                row("Highlight clicks", "cursorarrow.click", $settings.recordClicks, enabled: settings.recordMode != .studio)
                row("Show shortcuts pressed", "command", $settings.recordKeystrokes, enabled: true)
            }

            Text(modeNote)
                .font(.system(size: 12))
                .foregroundStyle(Color.snapMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { controller.finishSetup(start: false) }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Start Recording") { controller.finishSetup(start: true) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 300, height: 392)
        .background(Color.snapSidebar)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: 0x36383E)))
        .snapWindowStyle()
    }

    private var modeNote: String {
        switch settings.recordMode {
        case .video: return "Saves an MP4 with separate voice and system audio tracks."
        case .gif: return "Records silently and saves an optimized GIF."
        case .studio: return "Opens in the editor. Zoom, cursor, clicks and camera can all be changed after recording."
        }
    }

    private func row(_ title: String, _ symbol: String, _ value: Binding<Bool>, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.snapAccent)
        }
        .frame(height: 34)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

struct RecordingHUDView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(controller.isPaused ? Color.snapMuted : Color.snapAccent).frame(width: 10, height: 10)
                Text(verbatim: RecordingFormat.clock(controller.elapsed)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 8)

            if controller.usesMicrophone {
                LevelMeter(level: controller.level).frame(width: 40, height: 24)
            }
            Spacer(minLength: 2)
            Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }.buttonStyle(QuietButtonStyle())
            Button("Restart") { controller.restart() }.buttonStyle(QuietButtonStyle())
            Button("Discard") { controller.discard() }.buttonStyle(QuietButtonStyle())
            Button("Stop") { controller.requestStop() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 10)
        .frame(width: 480, height: 64)
        .background(Color.snapSidebar)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: 0x36383E)))
        .snapWindowStyle()
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<6, id: \.self) { index in
                let active = Float(index) / 6 < level
                RoundedRectangle(cornerRadius: 1)
                    .fill(active ? (index > 3 ? Color.snapAccent : Color.snapText) : Color.snapRaised)
                    .frame(width: 4, height: CGFloat(8 + index * 3))
            }
        }
        .accessibilityLabel("Microphone level")
    }
}
