import AppKit
import Combine
import SnapframeCore

struct PreviousArea: Codable {
    var displayID: UInt32
    var rect: CGRect
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var afterCapture: AfterCapture { didSet { defaults.set(afterCapture.rawValue, forKey: "afterCapture") } }
    @Published var exportPath: String { didSet { defaults.set(exportPath, forKey: "exportPath") } }
    @Published var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
    @Published var namePattern: String { didSet { defaults.set(namePattern, forKey: "namePattern") } }
    @Published var scaleTo1x: Bool { didSet { defaults.set(scaleTo1x, forKey: "scaleTo1x") } }
    @Published var convertToSRGB: Bool { didSet { defaults.set(convertToSRGB, forKey: "convertToSRGB") } }
    @Published var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: "windowShadow") } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "showCursor") } }
    @Published var freezeScreen: Bool { didSet { defaults.set(freezeScreen, forKey: "freezeScreen") } }
    @Published var adjustBeforeCapture: Bool { didSet { defaults.set(adjustBeforeCapture, forKey: "adjustBeforeCapture") } }
    @Published var timerSeconds: Int { didSet { defaults.set(timerSeconds, forKey: "timerSeconds") } }
    @Published var libraryRetentionDays: Int { didSet { defaults.set(libraryRetentionDays, forKey: "libraryRetentionDays") } }
    @Published var openHomeAtLaunch: Bool { didSet { defaults.set(openHomeAtLaunch, forKey: "openHomeAtLaunch") } }
    @Published var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }
    @Published var shortcuts: [ShortcutAction: Shortcut] { didSet { saveShortcuts() } }

    /// Lets onboarding continue where it stopped after the restart macOS requires.
    var onboardingStep: Int {
        get { defaults.integer(forKey: "onboardingStep") }
        set { defaults.set(newValue, forKey: "onboardingStep") }
    }

    var lastOverlayMode: OverlaySession.Mode {
        get { OverlaySession.Mode(rawValue: defaults.string(forKey: "lastOverlayMode") ?? "") ?? .area }
        set { defaults.set(newValue.rawValue, forKey: "lastOverlayMode") }
    }

    var defaultCanvasStyle: CanvasStyle {
        get {
            guard let data = defaults.data(forKey: "defaultCanvasStyle") else { return CanvasStyle() }
            return (try? JSONDecoder().decode(CanvasStyle.self, from: data)) ?? CanvasStyle()
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "defaultCanvasStyle") }
    }

    var previousArea: PreviousArea? {
        get {
            guard let data = defaults.data(forKey: "previousArea") else { return nil }
            return try? JSONDecoder().decode(PreviousArea.self, from: data)
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "previousArea")
        }
    }

    var exportDirectory: URL { URL(fileURLWithPath: exportPath, isDirectory: true) }

    private init() {
        let store = UserDefaults.standard
        store.register(defaults: [
            "playSound": true,
            "convertToSRGB": true,
            "windowShadow": true,
            "freezeScreen": true,
            "quality": 0.9,
            "timerSeconds": 3,
            "libraryRetentionDays": 30,
            "openHomeAtLaunch": true,
        ])

        playSound = store.bool(forKey: "playSound")
        afterCapture = AfterCapture(rawValue: store.string(forKey: "afterCapture") ?? "") ?? .saveAndCopy
        exportPath = store.string(forKey: "exportPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        format = ImageFormat(rawValue: store.string(forKey: "format") ?? "") ?? .png
        quality = store.double(forKey: "quality")
        namePattern = store.string(forKey: "namePattern") ?? NameTemplate.defaultPattern
        scaleTo1x = store.bool(forKey: "scaleTo1x")
        convertToSRGB = store.bool(forKey: "convertToSRGB")
        windowShadow = store.bool(forKey: "windowShadow")
        showCursor = store.bool(forKey: "showCursor")
        freezeScreen = store.bool(forKey: "freezeScreen")
        adjustBeforeCapture = store.bool(forKey: "adjustBeforeCapture")
        timerSeconds = store.integer(forKey: "timerSeconds")
        libraryRetentionDays = store.integer(forKey: "libraryRetentionDays")
        openHomeAtLaunch = store.bool(forKey: "openHomeAtLaunch")
        onboardingCompleted = store.bool(forKey: "onboardingCompleted")
        shortcuts = Self.loadShortcuts(from: store)
    }

    private static func loadShortcuts(from store: UserDefaults) -> [ShortcutAction: Shortcut] {
        if let data = store.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                ShortcutAction(rawValue: key).map { ($0, value) }
            })
        }
        return Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    private func saveShortcuts() {
        let saved = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(saved), forKey: "shortcuts")
    }

    /// Explains why a shortcut may not fire. Returns nil when it looks free.
    func conflictMessage(for action: ShortcutAction) -> String? {
        guard let shortcut = shortcuts[action] else { return nil }
        if let other = shortcuts.first(where: { $0.key != action && $0.value == shortcut }) {
            return "Also assigned to \(other.key.title)"
        }
        let symbolic = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        if SystemShortcuts.reserved(from: symbolic).contains(shortcut) {
            return "Reserved by macOS"
        }
        return nil
    }
}
