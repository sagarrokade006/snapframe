import CoreGraphics
import Foundation

public enum AppThemeID: String, CaseIterable, Codable, Sendable {
    case system, graphite, daylight, safelight, deepSea, aurora

    public var title: String {
        switch self {
        case .system: return "System"
        case .graphite: return "Graphite"
        case .daylight: return "Daylight"
        case .safelight: return "Safelight"
        case .deepSea: return "Deep Sea"
        case .aurora: return "Aurora"
        }
    }

    public var detail: String {
        switch self {
        case .system: return "Follows your Mac, light or dark."
        case .graphite: return "Neutral and quiet, so your captures stand out."
        case .daylight: return "Bright and airy, for light rooms."
        case .safelight: return "Warm darkroom red."
        case .deepSea: return "Cool teal and navy."
        case .aurora: return "Deep violet."
        }
    }

    /// The colors to draw with. `system` becomes Graphite or Daylight.
    public func palette(systemIsDark: Bool) -> ThemePalette {
        switch self {
        case .system: return systemIsDark ? .graphite : .daylight
        case .graphite: return .graphite
        case .daylight: return .daylight
        case .safelight: return .safelight
        case .deepSea: return .deepSea
        case .aurora: return .aurora
        }
    }
}

public enum ThemeAccent: String, CaseIterable, Codable, Sendable {
    case safelight, teal, blue, pink, sun, lime

    public var title: String {
        switch self {
        case .safelight: return "Safelight"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .sun: return "Sun"
        case .lime: return "Lime"
        }
    }

    public var hex: UInt32 {
        switch self {
        case .safelight: return 0xFF6B3D
        case .teal: return 0x6FD3C2
        case .blue: return 0x7C9BFF
        case .pink: return 0xFF8AC0
        case .sun: return 0xF2C14E
        case .lime: return 0xB5E36B
        }
    }
}

public struct ThemePalette: Equatable, Sendable {
    public var isDark: Bool
    public var ground: UInt32
    public var sidebar: UInt32
    public var card: UInt32
    public var control: UInt32
    public var raised: UInt32
    public var line: UInt32
    public var text: UInt32
    public var soft: UInt32
    public var muted: UInt32
    /// Text on a fill that uses the `text` color.
    public var onText: UInt32

    /// Today's dark look. It is the default, so updating changes nothing until a theme is chosen.
    public static let graphite = ThemePalette(
        isDark: true, ground: 0x101113, sidebar: 0x17181B, card: 0x1F2125, control: 0x26282D, raised: 0x2C2E33,
        line: 0x32343A, text: 0xF4F3F0, soft: 0xC4C6CC, muted: 0xA8ABB3, onText: 0x17181A
    )
    public static let daylight = ThemePalette(
        isDark: false, ground: 0xEEF0F4, sidebar: 0xF7F8FA, card: 0xFFFFFF, control: 0xE9EBEF, raised: 0xE4E6EB,
        line: 0xD3D6DD, text: 0x16181D, soft: 0x3F434C, muted: 0x555A65, onText: 0xFFFFFF
    )
    public static let safelight = ThemePalette(
        isDark: true, ground: 0x180A06, sidebar: 0x21100A, card: 0x2C1710, control: 0x351C13, raised: 0x3D2218,
        line: 0x4D2D21, text: 0xFFF3EC, soft: 0xEBCFC1, muted: 0xD9B8A8, onText: 0x2A0F07
    )
    public static let deepSea = ThemePalette(
        isDark: true, ground: 0x07171F, sidebar: 0x0C212B, card: 0x122C38, control: 0x173441, raised: 0x1B3C4A,
        line: 0x254B5A, text: 0xEAF7F6, soft: 0xBBDAD8, muted: 0xA5C8CB, onText: 0x06262F
    )
    public static let aurora = ThemePalette(
        isDark: true, ground: 0x120C24, sidebar: 0x1A1232, card: 0x231943, control: 0x2A1F4D, raised: 0x322557,
        line: 0x3F3168, text: 0xF6F2FF, soft: 0xD8CFEE, muted: 0xC3B8DE, onText: 0x1F1240
    )

    /// The accent as text or a thin line, adjusted so it stays readable on this theme's surfaces.
    public func accentText(_ accent: UInt32) -> UInt32 {
        func mixed(toward target: Double, by amount: Double) -> UInt32 {
            func channel(_ shift: UInt32) -> UInt32 {
                let value = Double((accent >> shift) & 0xFF)
                return UInt32((value + (target - value) * amount).rounded()) << shift
            }
            return channel(16) | channel(8) | channel(0)
        }
        guard isDark else { return mixed(toward: 0, by: 0.55) }
        // Warm and colored surfaces can dull an accent, so it lightens just enough to stay readable.
        var amount = 0.0
        while amount < 1, ThemeContrast.ratio(mixed(toward: 255, by: amount), raised) < 4.5 { amount += 0.04 }
        return mixed(toward: 255, by: amount)
    }
}

public enum ThemeContrast {
    public static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }

    public static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public extension CanvasFill {
    var isGradient: Bool {
        switch self {
        case .gradient, .linear: return true
        case .none, .color: return false
        }
    }

    var gradientColors: [UInt32]? {
        switch self {
        case .gradient(let start, let end): return [start, end]
        case .linear(let stops, _): return stops
        case .none, .color: return nil
        }
    }

    /// Where a gradient starts and ends, with y pointing down. 0° runs upward and 90° to the right.
    static func gradientLine(angle: Double, size: CGSize) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        let (x, y) = (sin(radians), -cos(radians))
        let reach = (abs(size.width * x) + abs(size.height * y)) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return (
            CGPoint(x: center.x - x * reach, y: center.y - y * reach),
            CGPoint(x: center.x + x * reach, y: center.y + y * reach)
        )
    }
}

public struct BackgroundPreset: Equatable, Sendable {
    public let name: String
    public let fill: CanvasFill

    public init(_ name: String, _ fill: CanvasFill) {
        self.name = name
        self.fill = fill
    }
}

public enum BackgroundCatalog {
    public static let savedLimit = 16
    public static let defaultSolid = CanvasFill.color(0xFF6B3D)
    public static let defaultGradient = CanvasFill.linear([0xFF8A63, 0xC7A6E8], angle: 135)

    private static func solid(_ name: String, _ hex: UInt32) -> BackgroundPreset { BackgroundPreset(name, .color(hex)) }
    private static func blend(_ name: String, _ stops: UInt32...) -> BackgroundPreset { BackgroundPreset(name, .linear(stops, angle: 135)) }

    public static let brandSolids = [
        solid("Safelight", 0xFF6B3D), solid("Teal", 0x6FD3C2), solid("Graphite", 0x2A2C30), solid("Ink", 0x15161A),
        solid("Slate blue", 0x5C8B94), solid("Clay", 0xC9694A), solid("Sand", 0xD8CDB8), solid("Paper", 0xF4F3F0),
    ]

    public static let solids: [BackgroundPreset] = {
        let neutrals = [
            solid("White", 0xFFFFFF), solid("Silver", 0xE5E7EB), solid("Light gray", 0x9CA3AF), solid("Gray", 0x6B7280),
            solid("Dark gray", 0x374151), solid("Charcoal", 0x1F2937), solid("Near black", 0x111827), solid("Black", 0x000000),
        ]
        let families: [(String, [UInt32])] = [
            ("red", [0xFEE2E2, 0xFCA5A5, 0xEF4444, 0xB91C1C]), ("orange", [0xFFEDD5, 0xFDBA74, 0xF97316, 0xC2410C]),
            ("amber", [0xFEF3C7, 0xFCD34D, 0xF59E0B, 0xB45309]), ("green", [0xDCFCE7, 0x86EFAC, 0x22C55E, 0x15803D]),
            ("teal", [0xCCFBF1, 0x5EEAD4, 0x14B8A6, 0x0F766E]), ("blue", [0xDBEAFE, 0x93C5FD, 0x3B82F6, 0x1D4ED8]),
            ("violet", [0xEDE9FE, 0xC4B5FD, 0x8B5CF6, 0x6D28D9]), ("pink", [0xFCE7F3, 0xF9A8D4, 0xEC4899, 0xBE185D]),
        ]
        let tones = ["Pale", "Light", "Bright", "Deep"]
        return neutrals + families.flatMap { family in
            zip(tones, family.1).map { solid("\($0) \(family.0)", $1) }
        }
    }()

    public static let brandGradients = [
        blend("Safelight to teal", 0xFF6B3D, 0x6FD3C2), blend("Graphite to slate", 0x2A2C30, 0x5C8B94),
        blend("Safelight to clay", 0xFF6B3D, 0xC9694A), blend("Teal to slate", 0x6FD3C2, 0x5C8B94),
        blend("Safelight to sun", 0xFF6B3D, 0xF2C14E), blend("Ink to safelight", 0x15161A, 0xFF6B3D),
    ]

    public static let gradients = [
        blend("Peach to lilac", 0xFF8A63, 0xC7A6E8), blend("Teal to blue", 0x6FD3C2, 0x3D8BFF), blend("Sun to safelight", 0xF2C14E, 0xFF6B3D),
        blend("Violet to pink", 0xA855F7, 0xEC4899), blend("Green to teal", 0x22C55E, 0x14B8A6), blend("Blue to violet", 0x3B82F6, 0x8B5CF6),
        blend("Orange to pink", 0xF97316, 0xEC4899), blend("Sky to aqua", 0x0EA5E9, 0x22D3EE), blend("Rose", 0xF43F5E, 0xFB7185),
        blend("Lime to sun", 0x84CC16, 0xF2C14E), blend("Navy to violet", 0x1E3A8A, 0x7C3AED), blend("Night", 0x0F172A, 0x334155),
        blend("Butter to blush", 0xFDE68A, 0xFCA5A5), blend("Ice to lavender", 0xBAE6FD, 0xDDD6FE), blend("Mint to ice", 0xBBF7D0, 0xBAE6FD),
        blend("Blush to apricot", 0xFBCFE8, 0xFED7AA), blend("Sunset", 0xFF6B3D, 0xEC4899, 0x7C3AED), blend("Lagoon", 0x22D3EE, 0x3B82F6, 0x7C3AED),
        blend("Ember", 0xF2C14E, 0xF97316, 0xE11D48), blend("Reef", 0x34D399, 0x06B6D4, 0x3B82F6), blend("Nebula", 0x111827, 0x7C3AED, 0xEC4899),
        blend("Shallows", 0x0F766E, 0x14B8A6, 0xFDE68A), blend("Dusk", 0x1F2937, 0xBE185D, 0xF97316), blend("Candy", 0xFDE68A, 0xF9A8D4, 0xC4B5FD),
    ]

    /// Puts a background first in the saved list, without duplicates and within the limit.
    public static func saving(_ fill: CanvasFill, in saved: [CanvasFill]) -> [CanvasFill] {
        guard fill != .none else { return saved }
        return Array(([fill] + saved.filter { $0 != fill }).prefix(savedLimit))
    }
}
