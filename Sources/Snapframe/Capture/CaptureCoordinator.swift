import AppKit
import AVFoundation
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
        if action == .record, RecordingController.shared.isRecording {
            RecordingController.shared.requestStop()
            return
        }
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            let cover = DesktopIconCover.shared
            let hideForCapture = settings.hideIconsWhileCapturing && action != .toggleDesktopIcons && !cover.isVisible
            if hideForCapture { await cover.show() }
            do {
                try await run(action)
            } catch {
                report(error)
            }
            if hideForCapture { cover.hide() }
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
        case .scrolling:
            try await runOverlay(mode: .scrolling, timer: 0)
        case .text:
            try await runOverlay(mode: .text, timer: 0)
        case .record:
            try await runOverlay(mode: .record, timer: 0)
        case .toggleDesktopIcons:
            await DesktopIconCover.shared.toggle()
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
        if outcome.mode == .record {
            try await captureRecording(outcome)
            return
        }

        if case .area(let snapshot, let rect) = outcome.target {
            if outcome.mode == .scrolling {
                try await captureScrolling(snapshot: snapshot, rect: rect, copyOnly: outcome.copyOnly)
                return
            }
            if outcome.mode == .text {
                try await captureText(snapshot: snapshot, rect: rect)
                return
            }
        }

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

    private func captureRecording(_ outcome: OverlaySession.Outcome) async throws {
        let displayID: CGDirectDisplayID
        let rect: CGRect
        switch outcome.target {
        case .area(let snapshot, let selection):
            displayID = snapshot.displayID
            rect = selection
        case .fullscreen(let snapshot):
            displayID = snapshot.displayID
            rect = snapshot.localBounds
        case .window:
            return
        }
        guard let output = try await RecordingController.shared.run(displayID: displayID, rect: rect, showsCursor: true) else { return }
        if output.mode == .studio {
            await finishStudio(package: output.movie.deletingLastPathComponent(), recovered: false, open: true)
        } else {
            try await finishRecording(movie: output.movie, isGIF: output.isGIF, recovered: false)
        }
    }

    /// Turns a finished or rescued movie into a file in the export folder and a library entry.
    private func finishRecording(movie: URL, isGIF: Bool, recovered: Bool) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: settings.exportDirectory, withIntermediateDirectories: true)
        let mode = recovered ? "Recovered" : (isGIF ? "GIF" : "Recording")
        let name = NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: mode)
        let destination = NameTemplate.uniqueURL(
            directory: settings.exportDirectory, baseName: name, fileExtension: isGIF ? "gif" : "mp4"
        ) { manager.fileExists(atPath: $0.path) }

        if isGIF {
            try await RecordingExport.makeGIF(from: movie, to: destination)
        } else {
            try await RecordingExport.makeMP4(from: movie, to: destination)
        }
        let poster = await RecordingExport.poster(of: movie)
        RecordingExport.removeWorkspace(of: movie)

        if settings.afterCapture.copies {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([destination as NSURL])
        }
        if settings.playSound { NSSound(named: "Tink")?.play() }

        let message = recovered ? "Recording recovered after an unexpected quit" : "Saved to \(destination.deletingLastPathComponent().lastPathComponent)"
        guard let poster, let item = await library.add(
            image: poster, scale: 1, kind: isGIF ? CaptureItem.gifKind : CaptureItem.recordingKind,
            name: name, formatTitle: isGIF ? "GIF" : "MP4", savedURL: destination
        ) else {
            showToast(message, reveal: destination)
            return
        }
        QuickAccessController.shared.show(item, message: message)
    }

    /// Turns a finished or rescued Studio recording into a project with automatic zooms.
    private func finishStudio(package: URL, recovered: Bool, open: Bool) async {
        let movie = package.appendingPathComponent(StudioProject.screenFile)
        let duration = (try? await AVURLAsset(url: movie).load(.duration))?.seconds ?? 0
        guard duration >= 0.5, var project = StudioPackage.load(package) else {
            try? FileManager.default.removeItem(at: package)
            if !recovered { showToast("The recording was too short to edit.", reveal: nil) }
            return
        }
        project.duration = duration
        project.clips = [StudioClip(start: 0, end: duration)]
        project.zooms = SmartZoom.analyze(clicks: project.clicks, mouse: project.mouse, duration: duration)
        project.isComplete = true
        StudioPackage.save(project, to: package)

        guard let poster = await RecordingExport.poster(of: movie),
              let item = await library.add(image: poster, scale: 1, kind: CaptureItem.studioKind, name: project.name, formatTitle: "Studio", savedURL: package)
        else { return }
        if open {
            StudioController.shared.open(item)
        } else if recovered {
            QuickAccessController.shared.show(item, message: "Studio recording recovered after an unexpected quit")
        }
    }

    /// Rescues recordings left behind by a crash or forced quit.
    func recoverRecordings() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            for package in StudioPackage.unfinished() {
                await finishStudio(package: package, recovered: true, open: false)
            }
            for movie in await RecordingExport.recoverableMovies() {
                do {
                    try await finishRecording(movie: movie, isGIF: false, recovered: true)
                } catch {
                    report(error)
                }
            }
        }
    }

    private func captureScrolling(snapshot: DisplaySnapshot, rect: CGRect, copyOnly: Bool) async throws {
        let displayID = snapshot.displayID
        let options = self.options
        let service = self.service
        let stitched = try await ScrollCaptureController.run(displayID: displayID, rect: rect) {
            try await service.captureRegion(displayID: displayID, rect: rect, options: options)
        }
        if let stitched {
            try await deliver(stitched.image, scale: stitched.scale, modeName: "Scrolling", copyOnly: copyOnly)
        }
    }

    private func captureText(snapshot: DisplaySnapshot, rect: CGRect) async throws {
        let image: CGImage
        if settings.freezeScreen {
            let crop = SelectionGeometry.pixelCrop(rect, scale: snapshot.scale, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
            guard let cropped = snapshot.image.cropping(to: crop) else { throw CaptureError.emptySelection }
            image = cropped
        } else {
            image = try await service.captureRegion(displayID: snapshot.displayID, rect: rect, options: options).image
        }

        let content = await TextCapture.recognize(image, detectLanguage: settings.detectTextLanguage)
        let text = TextComposer.compose(content.fragments, keepLineBreaks: settings.keepLineBreaks)
        if let value = text.isEmpty ? content.codes.first : text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        if settings.playSound { NSSound(named: "Tink")?.play() }
        TextResultController.shared.show(content)
    }

    /// Used by URL automation to capture exact coordinates without showing the overlay.
    func captureRegion(_ rect: CGRect, displayIndex: Int) {
        guard !isBusy, NSScreen.screens.indices.contains(displayIndex), let id = NSScreen.screens[displayIndex].displayID else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let shot = try await service.captureRegion(displayID: id, rect: rect, options: options)
                try await deliver(shot.image, scale: shot.scale, modeName: "Area", copyOnly: false)
            } catch {
                report(error)
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
