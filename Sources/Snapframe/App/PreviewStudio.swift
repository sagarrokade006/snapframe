#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit
import SnapframeCore
import SwiftUI

/// Debug-only checks for Studio. Nothing here runs in release builds.
enum PreviewStudio {
    private static func pixelBuffer(width: Int, height: Int, draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        draw(context)
        return buffer
    }

    private static func writeMovie(_ url: URL, width: Int, height: Int, seconds: Double, draw: @escaping (CGContext, Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let t = Double(frame) / 30
            guard let buffer = pixelBuffer(width: width, height: height, draw: { draw($0, t) }) else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func export(_ project: StudioProject, package: URL, to destination: URL, maximumHeight: Int = 0) async throws {
        try? FileManager.default.removeItem(at: destination)
        StudioRenderState.shared.project = project
        let built = try await StudioComposition.build(project: project, package: package, maximumHeight: maximumHeight)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else { throw RecordingError.nothingRecorded }
        session.videoComposition = built.video
        session.audioMix = built.audio
        session.outputURL = destination
        session.outputFileType = .mp4
        await session.export()
        if session.status != .completed { throw session.error ?? RecordingError.nothingRecorded }
    }

    private static func describe(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? -1
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = (try? await track?.load(.naturalSize)) ?? .zero
        return String(format: "%.2fs %dx%d", duration, Int(size.width), Int(size.height))
    }

    private static func frames(of url: URL, at times: [Double], directory: URL, prefix: String) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1100, height: 1100)
        for time in times {
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else {
                print("studio: no frame at \(time)")
                continue
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(prefix)-\(String(format: "%.1f", time)).png"))
        }
    }

    /// A synthetic project with every layer on, exported through the real compositor.
    static func synthetic(directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let package = directory.appendingPathComponent("sample.\(StudioProject.packageExtension)", isDirectory: true)
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

            let width = 1600, height = 1000
            try await writeMovie(package.appendingPathComponent(StudioProject.screenFile), width: width, height: height, seconds: 8) { c, t in
                c.setFillColor(CGColor(gray: 0.93, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                c.setFillColor(CGColor(gray: 0.72, alpha: 1))
                for x in stride(from: 0, to: width, by: 100) { c.fill(CGRect(x: x, y: 0, width: 2, height: height)) }
                for y in stride(from: 0, to: height, by: 100) { c.fill(CGRect(x: 0, y: y, width: width, height: 2)) }
                // Red marks the top-left corner, so a flipped frame is obvious.
                c.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
                c.fill(CGRect(x: 0, y: height - 120, width: 120, height: 120))
                c.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
                c.fill(CGRect(x: 200 + t * 120, y: 400, width: 160, height: 160))
            }
            try await writeMovie(package.appendingPathComponent(StudioProject.cameraFile), width: 640, height: 480, seconds: 8) { c, t in
                c.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.5, alpha: 1))
                c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fillEllipse(in: CGRect(x: 240, y: 160, width: 160, height: 160))
            }

            var project = StudioProject(name: "Sample", duration: 8, pixelWidth: width, pixelHeight: height, scale: 2)
            project.isComplete = true
            project.hasCamera = true
            for step in 0...480 {
                let t = Double(step) / 60
                project.mouse.append(MouseSample(t: t, x: 0.2 + t / 8 * 0.5, y: 0.3 + 0.1 * sin(t)))
            }
            project.clicks = [ClickEvent(t: 2, x: 0.3, y: 0.35)]
            project.keys = [KeyEvent(t: 3.2, parts: ["⌘", "K"])]
            project.zooms = SmartZoom.analyze(clicks: project.clicks, mouse: project.mouse, duration: 8)
            print("studio: zooms \(project.zooms.map { String(format: "%.1f-%.1f @%.1f", $0.start, $0.end, $0.level) })")
            StudioPackage.save(project, to: package)

            let plain = directory.appendingPathComponent("sample.mp4")
            try await export(project, package: package, to: plain)
            print("studio: full \(await describe(plain))")
            await frames(of: plain, at: [0.5, 2.2, 3.5, 7.5], directory: directory, prefix: "full")

            // A cut in the middle, a different look, and a smaller size.
            var edited = project
            edited.split(atTimeline: 4)
            edited.split(atTimeline: 6)
            edited.deleteClip(id: edited.clips[1].id)
            edited.appearance.canvas.fill = .linear([0xF2C14E, 0xF97316, 0xE11D48], angle: 45)
            edited.appearance.cursorStyle = .ring
            edited.appearance.cameraCorner = .topLeft
            let cut = directory.appendingPathComponent("edited.mp4")
            try await export(edited, package: package, to: cut, maximumHeight: 720)
            print("studio: edited \(await describe(cut)) (expected 6.00s at 720 tall)")
            await frames(of: cut, at: [2.2, 5], directory: directory, prefix: "edited")

            print("studio: reloaded matches \(StudioPackage.load(package) == project)")
        } catch {
            print("studio: FAILED \(error)")
        }
    }

    /// Real screen content and a real cursor log, without a window in the way.
    static func real(rect: CGRect, seconds: Double, directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let package = directory.appendingPathComponent("real.\(StudioProject.packageExtension)", isDirectory: true)
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let movie = package.appendingPathComponent(StudioProject.screenFile)

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = NSScreen.main?.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let size = RecordingFormat.outputSize(width: Int(rect.width * scale), height: Int(rect.height * scale), maximumHeight: 0)

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect
            configuration.width = size.width
            configuration.height = size.height
            configuration.scalesToFit = true
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 8
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false

            let writer = try RecordingWriter(url: movie, width: size.width, height: size.height, framesPerSecond: 30, system: false, microphone: false)
            let recorder = ScreenRecorder(writer: writer, filter: filter, configuration: configuration)
            try await recorder.start(system: false, useMicrophone: false)

            let height = NSScreen.main?.frame.height ?? 0
            let region = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            let tracker = await StudioTracker(region: region, elapsed: { writer.elapsed }, isPaused: { false }, autosave: {})
            await tracker.start()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await tracker.stop()
            await recorder.stop()
            try await writer.finish()

            var project = StudioProject(name: "Real", duration: (try await AVURLAsset(url: movie).load(.duration)).seconds, pixelWidth: size.width, pixelHeight: size.height, scale: Double(scale))
            project.mouse = await tracker.mouse
            project.windows = await tracker.windows
            project.isComplete = true
            project.zooms = [ZoomSegment(start: 1, end: project.duration - 0.5, level: 1.8)]
            StudioPackage.save(project, to: package)
            print("studio: real \(await describe(movie)), \(project.mouse.count) mouse samples, \(project.windows.count) window samples")

            let output = directory.appendingPathComponent("real.mp4")
            try await export(project, package: package, to: output)
            print("studio: real export \(await describe(output))")
            await frames(of: output, at: [0.4, project.duration / 2], directory: directory, prefix: "real")
        } catch {
            print("studio: FAILED \(error)")
        }
    }

    private static func captureWindow(_ name: String, directory: URL, minimumWidth: CGFloat = 1000) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("studio: listing failed for \(name): \(error)")
            return
        }
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == getpid() && $0.frame.width > minimumWidth }) else {
            print("studio: window not found for \(name), \(content.windows.filter { $0.owningApplication?.processID == getpid() }.map(\.frame))")
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width) * 2
        configuration.height = Int(window.frame.height) * 2
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else {
            print("studio: capture failed for \(name)")
            return
        }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("window-\(name).png"))
    }

    /// A tidy sample project for the website and README.
    @MainActor
    static func showcase(directory: URL) async {
        do {
            let package = directory.appendingPathComponent("showcase.\(StudioProject.packageExtension)", isDirectory: true)
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let screen = PreviewRenderer.syntheticScreen()
            let width = 2560, height = 1600
            try await writeMovie(package.appendingPathComponent(StudioProject.screenFile), width: width, height: height, seconds: 12) { c, _ in
                c.draw(screen, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var project = StudioProject(name: "Product walkthrough", duration: 12, pixelWidth: width, pixelHeight: height, scale: 2)
            project.isComplete = true
            for step in 0...720 {
                let t = Double(step) / 60
                project.mouse.append(MouseSample(t: t, x: 0.35 + 0.22 * sin(t * 0.5), y: 0.42 + 0.12 * cos(t * 0.7)))
            }
            project.clicks = [ClickEvent(t: 2.6, x: 0.46, y: 0.5), ClickEvent(t: 9, x: 0.3, y: 0.34)]
            project.keys = [KeyEvent(t: 3.1, parts: ["⌘", "⇧", "4"])]
            project.appearance.canvas.fill = .gradient(0xFF8A63, 0xC7A6E8)
            project.zooms = SmartZoom.analyze(clicks: project.clicks, mouse: project.mouse, duration: 12)
            StudioPackage.save(project, to: package)

            StudioController.shared.open(package: package)
            guard let session = StudioController.shared.session else { return }
            await wait(2)
            session.tab = .canvas
            session.seek(to: 3.4)
            await wait(1.5)
            await captureWindow("showcase", directory: directory)
        } catch {
            print("studio: FAILED \(error)")
        }
    }

    /// Switches themes while a real editor window is open, then restores the previous theme.
    @MainActor
    static func themes(directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        ThemeEngine.shared.start()
        let engine = ThemeEngine.shared
        let (oldTheme, oldAccent) = (engine.theme, engine.accent)
        defer {
            engine.theme = oldTheme
            engine.accent = oldAccent
        }
        let package = directory.appendingPathComponent("showcase.\(StudioProject.packageExtension)", isDirectory: true)
        StudioController.shared.open(package: package)
        guard let session = StudioController.shared.session else {
            print("studio: editor did not open")
            return
        }
        await wait(2)
        session.tab = .canvas
        session.seek(to: 3.4)
        await wait(1)
        for (theme, accent) in [(AppThemeID.daylight, ThemeAccent.teal), (.safelight, .safelight), (.aurora, .pink)] {
            engine.theme = theme
            engine.accent = accent
            await wait(1)
            await captureWindow("theme-\(theme.rawValue)", directory: directory)
            print("theme: \(theme.rawValue) dark \(engine.isDark)")
        }
        session.project.appearance.canvas.fill = .linear([0x22D3EE, 0x3B82F6, 0x7C3AED], angle: 60)
        session.changed()
        await wait(1)
        await captureWindow("theme-linear", directory: directory)
    }

    /// Shows the hover card in a real panel, using a sample image.
    @MainActor
    static func cardCheck(directory: URL) async {
        CaptureLibrary.overrideDirectory = directory.appendingPathComponent("card-library", isDirectory: true)
        try? FileManager.default.removeItem(at: CaptureLibrary.overrideDirectory!)
        ThemeEngine.shared.start()
        guard let item = await CaptureLibrary.shared.add(image: PreviewRenderer.syntheticScreen(), scale: 2, kind: "Area", name: "Sample", formatTitle: "PNG", savedURL: nil) else { return }
        let panel = KeylessPanel(size: HoverQuickCard.size)
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: HoverQuickCard(item: item, message: "", close: {}, hovering: { _ in }, showsControls: true))
        panel.setFrameOrigin(CGPoint(x: 80, y: 80))
        panel.orderFrontRegardless()
        await wait(1)
        await captureWindow("card", directory: directory, minimumWidth: 300)
    }

    /// Drives a real pin's resize handle with scripted drags, then shows it see-through.
    @MainActor
    static func pinCheck(directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        ThemeEngine.shared.start()
        let image = NSImage(cgImage: PreviewRenderer.syntheticScreen(), size: CGSize(width: 480, height: 300))
        let panel = KeylessPanel(size: CGSize(width: 480, height: 300))
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.contentView = FirstMouseHostingView(rootView: PinnedImageView(image: image, close: {}, showsControls: true, startingOpacity: 0.45))
        panel.setFrameOrigin(CGPoint(x: 120, y: 200))
        panel.orderFrontRegardless()
        await wait(1)
        await captureWindow("pin", directory: directory, minimumWidth: 300)

        let top = panel.frame.maxY, left = panel.frame.minX
        func drag(to point: CGPoint) {
            let handle = PinResizeHandle()
            panel.contentView?.addSubview(handle)
            var points = [CGPoint(x: 1000, y: 500), point]
            handle.pointer = { points.count > 1 ? points.removeFirst() : points[0] }
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseDragged), atStart: false)
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            handle.mouseDown(with: event(.leftMouseDown))
            handle.removeFromSuperview()
        }
        func report(_ name: String, _ passed: Bool) {
            let frame = panel.frame
            let anchored = abs(frame.maxY - top) < 1 && abs(frame.minX - left) < 1
            let shape = abs(frame.width / frame.height - 1.6) < 0.02
            print("\(passed && anchored && shape ? "ok" : "FAIL") \(name) \(frame.size)")
        }
        drag(to: CGPoint(x: 1240, y: 500))
        report("grows, keeps its shape, stops at the screen edge", panel.frame.width > 480 && panel.frame.minY >= (panel.screen?.visibleFrame.minY ?? 0))
        drag(to: CGPoint(x: 0, y: 900))
        report("stops at the smallest size", panel.frame.width == 180)
        await wait(0.3)
        print("ok handle does not move the window \(!PinResizeHandle().mouseDownCanMoveWindow)")
    }

    /// Exercises the real library against real files on disk.
    @MainActor
    static func libraryCheck(directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        CaptureLibrary.overrideDirectory = directory.appendingPathComponent("library", isDirectory: true)
        let library = CaptureLibrary.shared
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { return }
        func file(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            manager.createFile(atPath: url.path, contents: Data([1]))
            return url
        }
        func check(_ name: String, _ passed: Bool) { print("\(passed ? "ok" : "FAIL") \(name)") }

        let image1 = file("photo.png"), video = file("clip.mp4"), kept = file("kept.png")
        let photoItem = await library.add(image: image, scale: 1, kind: "Area", name: "photo", formatTitle: "PNG", savedURL: image1)
        let videoItem = await library.add(image: image, scale: 1, kind: CaptureItem.recordingKind, name: "clip", formatTitle: "MP4", savedURL: video)
        let keptItem = await library.add(image: image, scale: 1, kind: "Area", name: "kept", formatTitle: "PNG", savedURL: kept)
        let clipboardItem = await library.add(image: image, scale: 1, kind: "Area", name: "clipboard", formatTitle: "PNG", savedURL: nil)
        let driveItem = await library.add(image: image, scale: 1, kind: "Area", name: "drive", formatTitle: "PNG", savedURL: URL(fileURLWithPath: "/Volumes/SnapframeNotMounted/a.png"))
        guard let photoItem, let videoItem, let keptItem, let clipboardItem, let driveItem else { return print("FAIL setup") }

        await library.removeItemsWithDeletedFiles()
        check("nothing removed while files exist", library.index.items.count == 5)

        try? manager.removeItem(at: image1)
        try? manager.trashItem(at: video, resultingItemURL: nil)
        await library.removeItemsWithDeletedFiles()
        let ids = Set(library.index.items.map(\.id))
        check("deleted photo removed", !ids.contains(photoItem.id))
        check("video moved to Trash removed", !ids.contains(videoItem.id))
        check("private copy cleaned up", !manager.fileExists(atPath: library.imageURL(id: photoItem.id).path))
        check("existing file kept", ids.contains(keptItem.id))
        check("clipboard capture kept", ids.contains(clipboardItem.id))
        check("unplugged drive kept", ids.contains(driveItem.id))

        let reloaded = try? JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: directory.appendingPathComponent("library/index.json")))
        check("removal saved to disk", reloaded?.items.count == 3)
    }

    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// Drives a real editor window: preview, a style change, a cut, undo and playback.
    @MainActor
    static func window(directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let original = directory.appendingPathComponent("sample.\(StudioProject.packageExtension)", isDirectory: true)
        let package = directory.appendingPathComponent("window.\(StudioProject.packageExtension)", isDirectory: true)
        try? FileManager.default.removeItem(at: package)
        try? FileManager.default.copyItem(at: original, to: package)
        StudioController.shared.open(package: package)
        guard let session = StudioController.shared.session else {
            print("studio: editor did not open")
            return
        }
        await wait(2)
        session.seek(to: 2.2)
        await wait(1)
        await captureWindow("1-preview", directory: directory)

        session.project.appearance.canvas.fill = .color(0x6A4C74)
        session.project.appearance.cameraCorner = .topRight
        session.changed()
        await wait(1)
        await captureWindow("2-styled", directory: directory)

        session.seek(to: 4)
        session.splitAtPlayhead()
        await wait(1)
        session.selectedClip = session.project.clips[1].id
        session.deleteSelectedClip()
        await wait(1)
        print("studio: after cut \(session.project.clips.count) clips, \(session.project.editedDuration)s, item \(session.player.currentItem?.duration.seconds ?? -1)s")
        await captureWindow("3-cut", directory: directory)

        session.undo()
        await wait(1)
        print("studio: after undo \(session.project.clips.count) clips, item \(session.player.currentItem?.duration.seconds ?? -1)s")

        session.seek(to: 1)
        await wait(0.5)
        session.togglePlay()
        await wait(1.5)
        print("studio: playing, playhead \(session.playhead), error \(String(describing: session.player.currentItem?.error))")
        session.togglePlay()
        print("studio: saved edits match \(StudioPackage.load(package) == session.project)")
    }

    /// Lays out the editor for the given project, then saves it as an image.
    static func editor(directory: URL) async {
        let package = directory.appendingPathComponent("sample.\(StudioProject.packageExtension)", isDirectory: true)
        guard var project = StudioPackage.load(package) else {
            print("studio: run synthetic first")
            return
        }
        project.split(atTimeline: 5)
        let session = await StudioSession(project: project, package: package)
        await session.load()
        for tab in [StudioTab.zoom, .cursor, .canvas] {
            await MainActor.run {
                session.tab = tab
                let host = NSHostingView(rootView: StudioView(session: session).environment(\.colorScheme, .dark))
                host.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("editor-\(tab.rawValue).png"))
            }
        }
        await session.teardown()
    }
}
#endif
