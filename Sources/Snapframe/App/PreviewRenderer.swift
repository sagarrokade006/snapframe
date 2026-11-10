#if DEBUG
import AppKit
import ImageIO
import SnapframeCore
import SwiftUI

/// Debug-only check: draws the overlay and exercises file output with a synthetic screen,
/// so both can be inspected without Screen Recording permission.
@MainActor
enum PreviewRenderer {
    private static let size = CGSize(width: 1280, height: 800)
    private static let scale: CGFloat = 2

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sampleLibrary = directory.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.removeItem(at: sampleLibrary)
        CaptureLibrary.overrideDirectory = sampleLibrary

        let snapshot = DisplaySnapshot(
            displayID: 1,
            frame: CGRect(origin: .zero, size: size),
            scale: scale,
            image: syntheticScreen()
        )
        let window = VisibleWindow(
            windowID: 42,
            frame: CGRect(x: 180, y: 70, width: 920, height: 600),
            appName: "Field Notes",
            title: "Launch notes"
        )
        let environment = CaptureEnvironment(displays: [snapshot], windows: [window])

        func session(_ mode: OverlaySession.Mode, adjust: Bool = false) -> OverlaySession {
            OverlaySession(environment: environment, mode: mode, timer: 0, freeze: true, adjustBeforeCapture: adjust)
        }

        let idle = session(.area)
        idle.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(idle, snapshot, "1-area-idle", directory)

        let drawing = session(.area)
        drawing.mouseMoved(to: CGPoint(x: 400, y: 170), on: snapshot)
        drawing.mouseDown(at: CGPoint(x: 400, y: 170), on: snapshot)
        drawing.mouseDragged(to: CGPoint(x: 1000, y: 500), on: snapshot)
        write(drawing, snapshot, "2-area-drawing", directory)

        let adjusting = session(.area, adjust: true)
        adjusting.mouseMoved(to: CGPoint(x: 400, y: 170), on: snapshot)
        adjusting.mouseDown(at: CGPoint(x: 400, y: 170), on: snapshot)
        adjusting.mouseDragged(to: CGPoint(x: 1000, y: 500), on: snapshot)
        adjusting.mouseUp(on: snapshot)
        write(adjusting, snapshot, "3-area-adjusting", directory)

        let windowMode = session(.window)
        windowMode.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(windowMode, snapshot, "4-window", directory)

        let fullscreen = session(.fullscreen)
        fullscreen.mouseMoved(to: CGPoint(x: 640, y: 300), on: snapshot)
        write(fullscreen, snapshot, "5-fullscreen", directory)

        let library = CaptureLibrary.shared
        let samples: [(String, String, CGRect, [String])] = [
            ("Launch notes", "Area", CGRect(x: 360, y: 300, width: 1500, height: 760), ["Launch", "Design"]),
            ("Open questions", "Area", CGRect(x: 400, y: 800, width: 1100, height: 520), ["Launch"]),
            ("Field Notes window", "Window", CGRect(x: 360, y: 140, width: 1840, height: 1200), ["Design"]),
            ("Whole desktop", "Fullscreen", CGRect(x: 0, y: 0, width: 2560, height: 1600), []),
            ("Heading detail", "Area", CGRect(x: 440, y: 240, width: 900, height: 360), ["Bugs"]),
            ("Notes column", "Window", CGRect(x: 360, y: 140, width: 1200, height: 1100), []),
        ]
        var created: [CaptureItem] = []
        for (name, kind, crop, tags) in samples.reversed() {
            guard let image = snapshot.image.cropping(to: crop),
                  let item = await library.add(image: image, scale: scale, kind: kind, name: name, formatTitle: "PNG", savedURL: URL(fileURLWithPath: "/Desktop/\(name).png"))
            else { continue }
            tags.forEach { library.addTag($0, to: item) }
            created.append(item)
        }
        if let first = created.first { library.togglePinned(first) }
        if let launch = library.index.items.first { library.selectedID = launch.id }

        writeHosted(HomeView(onCapture: { _ in }, onSettings: {}), "10-home", size, directory)
        let popover = PopoverView(capture: { _ in }, openHome: {}, openSettings: {})
        writeHosted(popover, "11-popover", NSHostingView(rootView: popover).fittingSize, directory)
        if let item = library.index.items.first {
            writeHosted(QuickAccessCard(item: item, message: "Saved to Desktop and copied", close: {}, hovering: { _ in }), "12-quick-access", CGSize(width: 356, height: 312), directory)
        }
        let settingsSize = CGSize(width: 1060, height: 700)
        for (index, pane) in SettingsPane.allCases.enumerated() {
            writeHosted(SettingsView(pane: pane), "2\(index)-settings-\(pane.rawValue.lowercased())", settingsSize, directory)
        }
        for step in 0...3 {
            writeHosted(OnboardingView(initialStep: step, finish: {}, later: {}), "3\(step)-onboarding", CGSize(width: 920, height: 580), directory)
        }
        let notes = "## Changelog\n\n- Added a Home window with your recent captures\n- New: tags and timed auto-delete\n- Improved capture overlay\n- Fixed: shortcuts after a restart"
        let release = AvailableRelease(version: AppVersion("1.3.0")!, notes: notes, downloadURL: URL(string: "https://github.com")!, size: 3_200_000)
        UpdateController.shared.previewAvailable(release, phase: .available)
        writeHosted(UpdateView(close: {}), "40-update-available", CGSize(width: 720, height: 620), directory)
        UpdateController.shared.previewAvailable(release, phase: .installing)
        writeHosted(UpdateView(close: {}), "41-update-installing", CGSize(width: 720, height: 620), directory)

        let editor = PreviewAnnotate.sampleSession(base: snapshot.image, scale: scale)
        writeHosted(AnnotateView(session: editor), "50-annotate", size, directory)
        editor.tool = .redact
        writeHosted(AnnotateView(session: editor), "51-annotate-redact", size, directory)
        if let flat = editor.renderer.flatten(editor.document), let png = try? OutputService.encode(flat, format: .png, quality: 1, scale: scale) {
            try? png.write(to: directory.appendingPathComponent("52-annotate-flat.png"))
        }
        PreviewAnnotate.checkBurning(base: snapshot.image, scale: scale)
        await PreviewAnnotate.checkStoredEdit(base: snapshot.image, scale: scale)
        PreviewAnnotate.checkCanvas(base: snapshot.image, scale: scale)

        await checkOutput(snapshot: snapshot, directory: directory)
    }

    /// Exercises real capture and shortcut registration. Prints only sizes and counts, and writes nothing.
    static func liveCheck() async {
        let service = CaptureService()
        let options = CaptureOptions(showsCursor: false, convertToSRGB: true, windowShadow: true)
        print("preflight granted: \(PermissionManager.isScreenRecordingGranted)")
        do {
            let environment = try await service.environment(options: options)
            for display in environment.displays {
                print("display \(Int(display.frame.width))x\(Int(display.frame.height)) scale \(display.scale) image \(display.image.width)x\(display.image.height)")
            }
            print("windows found: \(environment.windows.count)")
            if let display = environment.displays.first {
                let region = try await service.captureRegion(displayID: display.displayID, rect: CGRect(x: 10, y: 20, width: 100, height: 50), options: options)
                print("region 100x50 pt: \(region.image.width)x\(region.image.height) scale \(region.scale)")
            }
            if let window = environment.windows.first {
                let plain = try await service.captureWindow(id: window.windowID, includeWallpaper: false, options: options)
                print("window \(Int(window.frame.width))x\(Int(window.frame.height)) pt: \(plain.image.width)x\(plain.image.height)")
                let framed = try await service.captureWindow(id: window.windowID, includeWallpaper: true, options: options)
                print("window on wallpaper: \(framed.image.width)x\(framed.image.height)")
            }
        } catch {
            print("capture error: \(error)")
        }
        HotKeyCenter.shared.register(Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) }))
        print("shortcuts refused: \(HotKeyCenter.shared.failed.count) of \(ShortcutAction.allCases.count)")
    }

    private static func write(_ session: OverlaySession, _ snapshot: DisplaySnapshot, _ name: String, _ directory: URL) {
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: size), session: session, snapshot: snapshot)
        save(view, name, directory)
    }

    private static func writeHosted<V: View>(_ root: V, _ name: String, _ viewSize: CGSize, _ directory: URL) {
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: viewSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        save(host, name, directory)
    }

    private static func save(_ view: NSView, _ name: String, _ directory: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])
        try? data?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func checkOutput(snapshot: DisplaySnapshot, directory: URL) async {
        let output = directory.appendingPathComponent("output")
        try? FileManager.default.removeItem(at: output)

        let crop = SelectionGeometry.pixelCrop(
            CGRect(x: 400, y: 170, width: 600, height: 330),
            scale: scale,
            imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
        guard let image = snapshot.image.cropping(to: crop) else {
            print("output: crop failed")
            return
        }

        for (format, oneX) in [(ImageFormat.png, false), (.jpeg, false), (.heic, false), (.png, true), (.png, false)] {
            let request = OutputRequest(
                image: image, scale: scale, modeName: "Area", saves: true, copies: false,
                format: format, quality: 0.9, scaleTo1x: oneX,
                namePattern: "{mode} fixed", directory: output
            )
            do {
                let result = try await OutputService.process(request)
                guard let url = result.savedURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else {
                    print("output \(format.title): failed \(result.saveError ?? "")")
                    continue
                }
                print("output \(url.lastPathComponent): \(info[kCGImagePropertyPixelWidth] ?? "?")x\(info[kCGImagePropertyPixelHeight] ?? "?") dpi \(info[kCGImagePropertyDPIWidth] ?? "?")")
            } catch {
                print("output \(format.title): \(error)")
            }
        }
    }

    private static func syntheticScreen() -> CGImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 0.18, green: 0.25, blue: 0.27, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 180, y: 130, width: 920, height: 600))
        context.setFillColor(CGColor(srgbRed: 0.91, green: 0.91, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 180, y: 690, width: 920, height: 40))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let ink = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
        func draw(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight) {
            (text as NSString).draw(
                at: CGPoint(x: 240, y: y),
                withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink]
            )
        }
        draw("Launch notes", y: 700, size: 14, weight: .semibold)
        draw("Launch notes", y: 620, size: 36, weight: .bold)
        draw("Check the onboarding copy before the next build.", y: 565, size: 20, weight: .regular)
        draw("Confirm the shortcut defaults on a clean account.", y: 525, size: 20, weight: .regular)
        draw("Record the walkthrough once permissions are final.", y: 485, size: 20, weight: .regular)
        draw("Open questions", y: 415, size: 26, weight: .semibold)
        draw("Should the capture sound be on by default?", y: 370, size: 20, weight: .regular)
        draw("Which file name reads best in Finder?", y: 330, size: 20, weight: .regular)
        draw("Does the loupe need a color readout?", y: 290, size: 20, weight: .regular)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}
#endif
