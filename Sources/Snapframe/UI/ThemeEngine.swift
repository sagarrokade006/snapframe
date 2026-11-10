import AppKit
import SnapframeCore
import SwiftUI

extension NSColor {
    convenience init(snapHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The colors in use right now. Drawing can read this from any thread.
enum ThemeStore {
    private static let lock = NSLock()
    private static var palette = ThemePalette.graphite
    private static var accent = ThemeAccent.safelight.hex

    static var current: (palette: ThemePalette, accent: UInt32) {
        lock.withLock { (palette, accent) }
    }

    static func set(_ newPalette: ThemePalette, accent newAccent: UInt32) {
        lock.withLock {
            palette = newPalette
            accent = newAccent
        }
    }
}

/// A color that always draws from the active theme.
func themedColor(_ pick: @escaping @Sendable (ThemePalette, UInt32) -> UInt32) -> NSColor {
    NSColor(name: nil) { _ in
        let state = ThemeStore.current
        return NSColor(snapHex: pick(state.palette, state.accent))
    }
}

@MainActor
final class ThemeEngine: ObservableObject {
    static let shared = ThemeEngine()

    /// Bumped on every change so open windows redraw.
    @Published private(set) var revision = 0

    @Published var theme: AppThemeID {
        didSet {
            defaults.set(theme.rawValue, forKey: "appTheme")
            apply()
        }
    }

    @Published var accent: ThemeAccent {
        didSet {
            defaults.set(accent.rawValue, forKey: "themeAccent")
            apply()
        }
    }

    private let defaults = UserDefaults.standard
    private var appearanceWatch: NSKeyValueObservation?
    private var systemIsDark = true

    var isDark: Bool { ThemeStore.current.palette.isDark }

    private init() {
        theme = AppThemeID(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .graphite
        accent = ThemeAccent(rawValue: defaults.string(forKey: "themeAccent") ?? "") ?? .safelight
    }

    func start() {
        apply()
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ThemeEngine.shared.systemAppearanceChanged() }
            }
        }
    }

    private static var appIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func systemAppearanceChanged() {
        guard theme == .system, Self.appIsDark != systemIsDark else { return }
        apply()
    }

    private func apply() {
        if theme == .system {
            NSApp.appearance = nil
            systemIsDark = Self.appIsDark
        }
        let palette = theme.palette(systemIsDark: systemIsDark)
        ThemeStore.set(palette, accent: accent.hex)
        if theme != .system {
            NSApp.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        }
        revision += 1
    }
}

private struct SnapWindowStyle: ViewModifier {
    @ObservedObject private var engine = ThemeEngine.shared

    func body(content: Content) -> some View {
        content
            .tint(.snapAccent)
            .foregroundStyle(Color.snapText)
            .environment(\.colorScheme, engine.isDark ? .dark : .light)
            .id(engine.revision)
    }
}

extension View {
    /// Applies the active theme and accent shared by every Snapframe window.
    func snapWindowStyle() -> some View {
        modifier(SnapWindowStyle())
    }
}
