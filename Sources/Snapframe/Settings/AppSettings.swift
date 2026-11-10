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
    @Published var keepLineBreaks: Bool { didSet { defaults.set(keepLineBreaks, forKey: "keepLineBreaks") } }
    @Published var detectTextLanguage: Bool { didSet { defaults.set(detectTextLanguage, forKey: "detectTextLanguage") } }
    @Published var hideIconsWhileCapturing: Bool { didSet { defaults.set(hideIconsWhileCapturing, forKey: "hideIconsWhileCapturing") } }
    @Published var automationPolicy: AutomationPolicy { didSet { defaults.set(automationPolicy.rawValue, forKey: "automationPolicy") } }
    @Published var savedBackgrounds: [CanvasFill] { didSet { defaults.set(try? JSONEncoder().encode(savedBackgrounds), forKey: "savedBackgrounds") } }
    @Published var recordMode: RecordMode { didSet { defaults.set(recordMode.rawValue, forKey: "recordMode") } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: "recordMicrophone") } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    @Published var recordCamera: Bool { didSet { defaults.set(recordCamera, forKey: "recordCamera") } }
    @Published var recordClicks: Bool { didSet { defaults.set(recordClicks, forKey: "recordClicks") } }
    @Published var recordKeystrokes: Bool { didSet { defaults.set(recordKeystrokes, forKey: "recordKeystrokes") } }
    @Published var recordFramesPerSecond: Int { didSet { defaults.set(recordFramesPerSecond, forKey: "recordFramesPerSecond") } }
    @Published var recordMaximumHeight: Int { didSet { defaults.set(recordMaximumHeight, forKey: "recordMaximumHeight") } }
    @Published var showRecordingTime: Bool { didSet { defaults.set(showRecordingTime, forKey: "showRecordingTime") } }
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
            "keepLineBreaks": true,
            "detectTextLanguage": true,
            "recordSystemAudio": true,
            "recordClicks": true,
            "recordFramesPerSecond": 30,
            "showRecordingTime": true,
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
        keepLineBreaks = store.bool(forKey: "keepLineBreaks")
        detectTextLanguage = store.bool(forKey: "detectTextLanguage")
        hideIconsWhileCapturing = store.bool(forKey: "hideIconsWhileCapturing")
        savedBackgrounds = store.data(forKey: "savedBackgrounds").flatMap { try? JSONDecoder().decode([CanvasFill].self, from: $0) } ?? []
        recordMode = RecordMode(rawValue: store.string(forKey: "recordMode") ?? "") ?? (store.bool(forKey: "recordOutputGIF") ? .gif : .video)
        recordMicrophone = store.bool(forKey: "recordMicrophone")
        recordSystemAudio = store.bool(forKey: "recordSystemAudio")
        recordCamera = store.bool(forKey: "recordCamera")
        recordClicks = store.bool(forKey: "recordClicks")
        recordKeystrokes = store.bool(forKey: "recordKeystrokes")
        recordFramesPerSecond = store.integer(forKey: "recordFramesPerSecond")
        recordMaximumHeight = store.integer(forKey: "recordMaximumHeight")
        showRecordingTime = store.bool(forKey: "showRecordingTime")
        automationPolicy = AutomationPolicy(rawValue: store.string(forKey: "automationPolicy") ?? "") ?? .ask
        shortcuts = Self.loadShortcuts(from: store)
    }

    /// Gives shortcuts to actions added since the last launch, without restoring ones the user cleared.
    private static func loadShortcuts(from store: UserDefaults) -> [ShortcutAction: Shortcut] {
        let everyAction = ShortcutAction.allCases.map(\.rawValue)
        defer { store.set(everyAction, forKey: "shortcutActionsSeen") }

        guard let data = store.data(forKey: "shortcuts"),
              let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data)
        else {
            return Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        }

        var result = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
            ShortcutAction(rawValue: key).map { ($0, value) }
        })
        let originalActions = ["allInOne", "area", "previousArea", "window", "fullscreen", "selfTimer"]
        let seen = store.stringArray(forKey: "shortcutActionsSeen") ?? originalActions
        for action in ShortcutAction.allCases where !seen.contains(action.rawValue) {
            result[action] = action.defaultShortcut
        }
        let stored = Dictionary(uniqueKeysWithValues: result.map { ($0.key.rawValue, $0.value) })
        store.set(try? JSONEncoder().encode(stored), forKey: "shortcuts")
        return result
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
