import AppKit
import ScreenCaptureKit
import SnapframeCore

/// Runs one capture from trigger to delivered file. Only one capture can be active at a time.
@MainActor
final class CaptureCoordinator {
    private let service = CaptureService()
    private let settings = AppSettings.shared
    private var isBusy = false
    private let library = CaptureLibrary.shared
    private var activeToast: PillPanel?

    var onPermissionNeeded: (() -> Void)?

    private var options: CaptureOptions {
        CaptureOptions(
            showsCursor: settings.showCursor,
            convertToSRGB: settings.convertToSRGB,
            windowShadow: settings.windowShadow
        )
    }

    func begin(_ action: ShortcutAction) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await run(action)
            } catch {
                report(error)
            }
        }
    }

    private func run(_ action: ShortcutAction) async throws {
        switch action {
        case .allInOne:
            try await runOverlay(mode: settings.lastOverlayMode, timer: 0)
        case .area:
            try await runOverlay(mode: .area, timer: 0)
        case .window:
            try await runOverlay(mode: .window, timer: 0)
        case .selfTimer:
            try await runOverlay(mode: .area, timer: settings.timerSeconds)
        case .fullscreen:
            if NSScreen.screens.count == 1, let id = NSScreen.screens.first?.displayID {
                let shot = try await service.captureDisplay(id: id, options: options)
                try await deliver(shot.image, scale: shot.scale, modeName: "Fullscreen", copyOnly: false)
            } else {
                try await runOverlay(mode: .fullscreen, timer: 0)
            }
        case .previousArea:
            if let previous = settings.previousArea {
                let shot = try await service.captureRegion(displayID: previous.displayID, rect: previous.rect, options: options)
                try await deliver(shot.image, scale: shot.scale, modeName: "Area", copyOnly: false)
            } else {
                try await runOverlay(mode: .area, timer: 0)
            }
        }
    }

    private func runOverlay(mode: OverlaySession.Mode, timer: Int) async throws {
        let environment = try await service.environment(options: options)
        let session = OverlaySession(
            environment: environment,
            mode: mode,
            timer: timer,
            freeze: settings.freezeScreen,
            adjustBeforeCapture: settings.adjustBeforeCapture,
            afterCapture: settings.afterCapture
        )

        let outcome: OverlaySession.Outcome? = await withCheckedContinuation { continuation in
            session.onFinish = { continuation.resume(returning: $0) }
            session.present()
        }
        guard let outcome else { return }
        settings.lastOverlayMode = outcome.mode
        settings.afterCapture = outcome.afterCapture

        if outcome.timer > 0 {
            guard await CountdownController.run(seconds: outcome.timer) else { return }
        }
        try await captureTarget(outcome)
    }

    private func captureTarget(_ outcome: OverlaySession.Outcome) async throws {
        // A countdown means the screen is meant to have changed, so frozen pixels would be stale.
        let useFrozen = settings.freezeScreen && outcome.timer == 0

        switch outcome.target {
        case .area(let snapshot, let rect):
            settings.previousArea = PreviousArea(displayID: snapshot.displayID, rect: rect)
            if useFrozen {
                let crop = SelectionGeometry.pixelCrop(
                    rect,
                    scale: snapshot.scale,
                    imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
                )
                guard let image = snapshot.image.cropping(to: crop) else { throw CaptureError.emptySelection }
                try await deliver(image, scale: snapshot.scale, modeName: "Area", copyOnly: outcome.copyOnly)
            } else {
                let shot = try await service.captureRegion(displayID: snapshot.displayID, rect: rect, options: options)
                try await deliver(shot.image, scale: shot.scale, modeName: "Area", copyOnly: outcome.copyOnly)
            }

        case .window(let window):
            let shot = try await service.captureWindow(
                id: window.windowID,
                includeWallpaper: outcome.includeWallpaper,
                options: options
            )
            try await deliver(shot.image, scale: shot.scale, modeName: "Window", copyOnly: outcome.copyOnly)

        case .fullscreen(let snapshot):
            if useFrozen {
                try await deliver(snapshot.image, scale: snapshot.scale, modeName: "Fullscreen", copyOnly: outcome.copyOnly)
            } else {
                let shot = try await service.captureDisplay(id: snapshot.displayID, options: options)
                try await deliver(shot.image, scale: shot.scale, modeName: "Fullscreen", copyOnly: outcome.copyOnly)
            }
        }
    }

    private func deliver(_ image: CGImage, scale: CGFloat, modeName: String, copyOnly: Bool) async throws {
        let result = try await OutputService.process(OutputRequest(
            image: image,
            scale: scale,
            modeName: modeName,
            saves: settings.afterCapture.saves && !copyOnly,
            copies: settings.afterCapture.copies || copyOnly,
            format: settings.format,
            quality: settings.quality,
            scaleTo1x: settings.scaleTo1x,
            namePattern: settings.namePattern,
            directory: settings.exportDirectory
        ))

        if settings.playSound {
            NSSound(named: "Tink")?.play()
        }

        let name = result.savedURL?.deletingPathExtension().lastPathComponent
            ?? NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: modeName)
        let item = await library.add(
            image: image,
            scale: scale,
            kind: modeName,
            name: name,
            formatTitle: result.savedURL == nil ? "PNG" : settings.format.title,
            savedURL: result.savedURL
        )

        let message: String
        if result.saveError != nil {
            message = "Could not save. Copied instead."
        } else if let url = result.savedURL {
            let folder = url.deletingLastPathComponent().lastPathComponent
            message = result.copied ? "Saved to \(folder) and copied" : "Saved to \(folder)"
        } else {
            message = "Copied to clipboard"
        }

        if let item, settings.afterCapture == .annotate, !copyOnly {
            AnnotateController.shared.open(item)
        } else if let item {
            QuickAccessController.shared.show(item, message: message)
        } else {
            showToast(message, reveal: result.savedURL)
        }
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        let declined = nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue
        if declined || !PermissionManager.isScreenRecordingGranted {
            onPermissionNeeded?()
        } else {
            showToast("Capture failed: \(error.localizedDescription)", reveal: nil)
        }
    }

    private func showToast(_ message: String, reveal url: URL?) {
        activeToast?.close()
        let toast = PillPanel(message: message, fontSize: 13)
        toast.onClick = { [weak toast] in
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            toast?.close()
        }
        toast.showBottomLeft()
        activeToast = toast

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak toast] in
            MainActor.assumeIsolated {
                guard let toast else { return }
                toast.close()
                if self?.activeToast === toast { self?.activeToast = nil }
            }
        }
    }
}

/// Counts down in a floating pill. Clicking the pill cancels.
@MainActor
enum CountdownController {
    static func run(seconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            var remaining = seconds
            var finished = false
            let pill = PillPanel(message: label(remaining), fontSize: 22)
            var timer: Timer?

            @MainActor func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                timer?.invalidate()
                pill.close()
                continuation.resume(returning: result)
            }

            pill.onClick = { finish(false) }
            pill.showCentered()

            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    remaining -= 1
                    if remaining <= 0 {
                        finish(true)
                    } else {
                        pill.update(message: label(remaining))
                    }
                }
            }
        }
    }

    private static func label(_ remaining: Int) -> String {
        "\(remaining)  ·  Click to cancel"
    }
}
