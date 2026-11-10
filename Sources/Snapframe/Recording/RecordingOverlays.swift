import AppKit
import AVFoundation
import SnapframeCore
import SwiftUI

/// A round, draggable camera view that appears in the recording.
@MainActor
final class CameraBubble {
    private let panel: KeylessPanel
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var recorder: CameraFileDelegate?
    private var file: URL?
    private let startQueue = DispatchQueue(label: "app.snapframe.camera-start")

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    /// With a file, the camera is also saved separately so Studio can restyle it later.
    init(region: CGRect, recordingTo file: URL? = nil) {
        let side = min(180, min(region.width, region.height) / 2)
        panel = KeylessPanel(size: CGSize(width: side, height: side))
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true

        let view = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        view.layer?.cornerRadius = side / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            view.layer?.addSublayer(preview)
            if let file, session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
                recorder = CameraFileDelegate()
                self.file = file
            }
            let running = session
            startQueue.async { running.startRunning() }
        }

        panel.contentView = view
        panel.setFrameOrigin(CGPoint(x: region.maxX - side - 24, y: region.minY + 24))
        panel.orderFrontRegardless()
    }

    /// Starts the camera file, and reports the moment it really begins so it can be lined up with the screen.
    func startFile(onStart: @escaping () -> Void) {
        guard let file, let recorder else { return }
        recorder.started = onStart
        let output = movieOutput
        startQueue.async { output.startRecording(to: file, recordingDelegate: recorder) }
    }

    func pauseFile() { if movieOutput.isRecording { movieOutput.pauseRecording() } }
    func resumeFile() { if movieOutput.isRecordingPaused { movieOutput.resumeRecording() } }

    /// Waits for the camera file to be fully written.
    func finishFile() async {
        guard let recorder, movieOutput.isRecording else { return }
        await withCheckedContinuation { continuation in
            recorder.finished = { continuation.resume() }
            movieOutput.stopRecording()
        }
    }

    func close() {
        let running = session
        DispatchQueue.global(qos: .userInitiated).async { running.stopRunning() }
        panel.close()
    }
}

private final class CameraFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var started: (() -> Void)?
    var finished: (() -> Void)?

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        guard let started else { return }
        self.started = nil
        DispatchQueue.main.async { started() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        finished?()
        finished = nil
    }
}

/// Draws click ripples and pressed shortcuts on top of the recorded area.
@MainActor
final class ActivityOverlay {
    private let panel: KeylessPanel
    private let canvas = ActivityCanvas()
    private var monitors: [Any] = []
    private let region: CGRect

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(region: CGRect, clicks: Bool, keys: Bool) {
        self.region = region
        panel = KeylessPanel(size: region.size)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.contentView = canvas
        panel.setFrameOrigin(region.origin)
        panel.orderFrontRegardless()

        if clicks {
            addMonitor(.leftMouseDown) { [weak self] _ in self?.recordClick() }
            addMonitor(.rightMouseDown) { [weak self] _ in self?.recordClick() }
        }
        if keys {
            addMonitor(.keyDown) { [weak self] event in self?.recordKey(event) }
        }
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        }
    }

    private func recordClick() {
        let location = NSEvent.mouseLocation
        guard region.contains(location) else { return }
        canvas.addRipple(at: CGPoint(x: location.x - region.minX, y: location.y - region.minY))
    }

    /// Only shortcuts are shown, so ordinary typing such as passwords never appears on screen.
    private func recordKey(_ event: NSEvent) {
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        guard !modifiers.isEmpty else { return }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        canvas.showKeys(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers).keyParts)
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        canvas.stop()
        panel.close()
    }
}

private final class ActivityCanvas: NSView {
    private struct Ripple {
        let center: CGPoint
        let start: Date
    }

    private var ripples: [Ripple] = []
    private var keys: [String] = []
    private var keysShownAt = Date.distantPast
    private var timer: Timer?

    private static let rippleDuration = 0.45
    private static let keysDuration = 1.3

    override var isOpaque: Bool { false }

    func addRipple(at point: CGPoint) {
        ripples.append(Ripple(center: point, start: Date()))
        startTimer()
    }

    func showKeys(_ parts: [String]) {
        keys = parts
        keysShownAt = Date()
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.start) > Self.rippleDuration }
        if now.timeIntervalSince(keysShownAt) > Self.keysDuration { keys = [] }
        needsDisplay = true
        if ripples.isEmpty, keys.isEmpty { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        let now = Date()
        for ripple in ripples {
            let progress = min(now.timeIntervalSince(ripple.start) / Self.rippleDuration, 1)
            let radius = 12 + 26 * progress
            let box = CGRect(x: ripple.center.x - radius, y: ripple.center.y - radius, width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: box)
            Palette.accent.withAlphaComponent(0.28 * (1 - progress)).setFill()
            circle.fill()
            Palette.accent.withAlphaComponent(1 - progress).setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }

        guard !keys.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.text]
        let sizes = keys.map { ($0 as NSString).size(withAttributes: attributes) }
        let widths = sizes.map { max($0.width + 18, 38) }
        let total = widths.reduce(0, +) + CGFloat(keys.count - 1) * 8 + 24
        let pill = CGRect(x: bounds.midX - total / 2, y: 36, width: total, height: 60)

        Palette.panel.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()

        var x = pill.minX + 12
        for (index, key) in keys.enumerated() {
            let cap = CGRect(x: x, y: pill.minY + 10, width: widths[index], height: 40)
            Palette.hairline.setFill()
            NSBezierPath(roundedRect: cap, xRadius: 7, yRadius: 7).fill()
            (key as NSString).draw(at: CGPoint(x: cap.midX - sizes[index].width / 2, y: cap.midY - sizes[index].height / 2), withAttributes: attributes)
            x += widths[index] + 8
        }
    }
}
