import AppKit
import SnapframeCore

/// Logs the cursor, clicks, shortcuts and windows during a Studio recording, so they can be redrawn later.
@MainActor
final class StudioTracker {
    private(set) var mouse: [MouseSample] = []
    private(set) var clicks: [ClickEvent] = []
    private(set) var keys: [KeyEvent] = []
    private(set) var windows: [WindowSample] = []

    private let region: CGRect
    private let elapsed: () -> Double
    private let isPaused: () -> Bool
    private let autosave: () -> Void
    private let logsKeys: Bool

    private var timer: Timer?
    private var monitors: [Any] = []
    private var ticks = 0
    private var lastPoint: (x: Double, y: Double)?

    private static let saveEveryTicks = 300
    private static let windowEveryTicks = 30

    init(region: CGRect, elapsed: @escaping () -> Double, isPaused: @escaping () -> Bool, logsKeys: Bool = true, autosave: @escaping () -> Void) {
        self.logsKeys = logsKeys
        self.region = region
        self.elapsed = elapsed
        self.isPaused = isPaused
        self.autosave = autosave
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }) { monitors.append(monitor) }

        guard logsKeys else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordKey(event) }
        }) { monitors.append(monitor) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func normalized(_ point: CGPoint) -> (x: Double, y: Double) {
        ((point.x - region.minX) / region.width, 1 - (point.y - region.minY) / region.height)
    }

    private func tick() {
        ticks += 1
        if ticks % Self.saveEveryTicks == 0 { autosave() }
        guard !isPaused() else { return }

        let t = elapsed()
        let point = normalized(NSEvent.mouseLocation)
        // Still positions are only logged now and then, which keeps long recordings small.
        if lastPoint == nil || lastPoint! != point || ticks % 30 == 0 {
            mouse.append(MouseSample(t: t, x: point.x, y: point.y))
            lastPoint = point
        }
        if ticks % Self.windowEveryTicks == 0 { sampleWindow(t: t) }
    }

    private func recordClick() {
        let location = NSEvent.mouseLocation
        guard !isPaused(), region.contains(location) else { return }
        let point = normalized(location)
        clicks.append(ClickEvent(t: elapsed(), x: point.x, y: point.y))
    }

    /// Only shortcuts are logged, never ordinary typing.
    private func recordKey(_ event: NSEvent) {
        guard !isPaused() else { return }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        guard !modifiers.isEmpty else { return }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        keys.append(KeyEvent(t: elapsed(), parts: Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers).keyParts))
    }

    private func sampleWindow(t: Double) {
        guard let screen = NSScreen.screens.first, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let location = NSEvent.mouseLocation
        let quartz = CGPoint(x: location.x, y: screen.frame.maxY - location.y)
        let quartzRegion = CGRect(x: region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)

        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  let info = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: info), bounds.contains(quartz)
            else { continue }
            let rect = CGRect(
                x: (bounds.minX - quartzRegion.minX) / quartzRegion.width,
                y: (bounds.minY - quartzRegion.minY) / quartzRegion.height,
                width: bounds.width / quartzRegion.width,
                height: bounds.height / quartzRegion.height
            )
            if windows.last?.rect != rect { windows.append(WindowSample(t: t, rect: rect)) }
            return
        }
    }
}

enum StudioPackage {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapframe/Studio", isDirectory: true)
    }

    static func create() throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString).\(StudioProject.packageExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load(_ package: URL) -> StudioProject? {
        (try? Data(contentsOf: package.appendingPathComponent(StudioProject.projectFile))).flatMap { try? StudioProject.decode($0) }
    }

    static func save(_ project: StudioProject, to package: URL) {
        guard let data = try? project.encoded() else { return }
        try? data.write(to: package.appendingPathComponent(StudioProject.projectFile), options: .atomic)
    }

    /// Packages from a Studio recording that never finished.
    static func unfinished() -> [URL] {
        let packages = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return packages.filter { load($0)?.isComplete != true }
    }
}
