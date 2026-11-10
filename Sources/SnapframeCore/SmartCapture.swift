import CoreGraphics
import Foundation

public struct RowSignature: Equatable, Sendable {
    public let hash: UInt64
    /// A single-color row, which matches anywhere and so proves nothing on its own.
    public let isFlat: Bool
    /// Average brightness across the row, used when pixels differ slightly between frames.
    public let profile: [UInt8]

    public init(hash: UInt64, isFlat: Bool, profile: [UInt8] = []) {
        self.hash = hash
        self.isFlat = isFlat
        self.profile = profile
    }

    public static func == (a: RowSignature, b: RowSignature) -> Bool {
        a.hash == b.hash && a.isFlat == b.isFlat
    }

    /// Mean brightness difference per sample. Int.max when there is nothing to compare.
    func distance(to other: RowSignature) -> Int {
        guard !profile.isEmpty, profile.count == other.profile.count else { return .max }
        var total = 0
        for index in profile.indices { total += abs(Int(profile[index]) - Int(other.profile[index])) }
        return total / profile.count
    }
}

public enum ScrollMatch: Equatable, Sendable {
    case unchanged
    /// Content moved up by `offset` rows. `footer` rows at the bottom stayed fixed.
    case moved(offset: Int, footer: Int)
    case reversed
    case lost
}

/// Finds how far a page scrolled between two frames by comparing rows of pixels.
public enum ScrollMatcher {
    private static let minimumOverlap = 40
    private static let minimumInformativeRows = 6
    private static let requiredAgreement = 0.92
    private static let similarDistance = 3

    public static func compare(previous: [RowSignature], current: [RowSignature]) -> ScrollMatch {
        let count = previous.count
        guard count > 0, current.count == count else { return .lost }

        let exact = match(previous, current) { $0 == $1 } offset: { older, newer, top, bottom in
            bestOffset(from: older, to: newer, top: top, bottom: bottom)
        }
        switch exact {
        case .unchanged, .moved:
            return exact
        case .reversed, .lost:
            guard previous[0].profile.isEmpty == false else { return exact }
        }

        // Exact pixels didn't line up, so allow for small rendering differences between frames.
        return match(previous, current) { $0.distance(to: $1) <= similarDistance } offset: { older, newer, top, bottom in
            closestOffset(from: older, to: newer, top: top, bottom: bottom)
        }
    }

    private static func match(
        _ previous: [RowSignature],
        _ current: [RowSignature],
        same: (RowSignature, RowSignature) -> Bool,
        offset: ([RowSignature], [RowSignature], Int, Int) -> Int?
    ) -> ScrollMatch {
        let count = previous.count
        let matching = zip(previous, current).filter { same($0, $1) }.count
        if Double(matching) >= Double(count) * 0.995 { return .unchanged }

        let header = fixedPrefix(previous, current, same: same)
        let footer = fixedPrefix(previous.reversed(), current.reversed(), same: same)
        let top = header, bottom = count - footer
        guard bottom - top > minimumOverlap else { return .lost }

        if let found = offset(previous, current, top, bottom) {
            return .moved(offset: found, footer: footer)
        }
        return offset(current, previous, top, bottom) == nil ? .lost : .reversed
    }

    /// Matching rows at the edge. A run of only blank rows is a page margin, not a fixed bar.
    private static func fixedPrefix<C: Collection>(_ first: C, _ second: C, same: (RowSignature, RowSignature) -> Bool) -> Int where C.Element == RowSignature {
        var matched = 0, hasDetail = false
        for (a, b) in zip(first, second) {
            guard same(a, b) else { break }
            matched += 1
            if !a.isFlat { hasDetail = true }
        }
        return hasDetail ? matched : 0
    }

    private static func bestOffset(from older: [RowSignature], to newer: [RowSignature], top: Int, bottom: Int) -> Int? {
        var best: (offset: Int, score: Double)?
        let largest = bottom - top - minimumOverlap
        guard largest >= 1 else { return nil }

        for offset in 1...largest {
            var equal = 0, informative = 0, informativeEqual = 0
            let total = bottom - offset - top
            for row in top..<(bottom - offset) {
                let old = older[row + offset]
                let matches = old == newer[row]
                if matches { equal += 1 }
                if !old.isFlat {
                    informative += 1
                    if matches { informativeEqual += 1 }
                }
            }
            guard informative >= minimumInformativeRows,
                  Double(equal) / Double(total) >= requiredAgreement
            else { continue }

            let score = Double(informativeEqual) / Double(informative)
            guard score >= requiredAgreement else { continue }
            if score == 1 { return offset }
            if best == nil || score > best!.score { best = (offset, score) }
        }
        return best?.offset
    }

    /// Finds the offset with the smallest brightness difference, rejecting poor fits early.
    private static func closestOffset(from older: [RowSignature], to newer: [RowSignature], top: Int, bottom: Int) -> Int? {
        let largest = bottom - top - minimumOverlap
        guard largest >= 1 else { return nil }

        var best: (offset: Int, average: Double)?
        for offset in 1...largest {
            let total = bottom - offset - top
            let allowedMisses = Int(Double(total) * (1 - requiredAgreement))
            var misses = 0, informative = 0, sum = 0
            for row in top..<(bottom - offset) {
                let old = older[row + offset]
                let distance = old.distance(to: newer[row])
                if !old.isFlat {
                    informative += 1
                    sum += distance == .max ? 255 : distance
                }
                if distance > similarDistance {
                    misses += 1
                    if misses > allowedMisses { break }
                }
            }
            guard misses <= allowedMisses, informative >= minimumInformativeRows else { continue }
            let average = Double(sum) / Double(informative)
            if best == nil || average < best!.average { best = (offset, average) }
        }
        return best?.offset
    }

    /// The newly revealed rows of the current frame, just above any fixed footer.
    public static func newRows(rowCount: Int, offset: Int, footer: Int) -> Range<Int> {
        (rowCount - footer - offset)..<(rowCount - footer)
    }
}

public struct TextFragment: Equatable, Sendable {
    public let text: String
    public let x: CGFloat
    public let y: CGFloat
    public let height: CGFloat

    /// Position is measured from the top-left of the image.
    public init(text: String, x: CGFloat, y: CGFloat, height: CGFloat) {
        self.text = text
        self.x = x
        self.y = y
        self.height = height
    }
}

public enum TextComposer {
    /// Puts recognized pieces in reading order: rows from the top, each row left to right.
    public static func compose(_ fragments: [TextFragment], keepLineBreaks: Bool) -> String {
        var rows: [[TextFragment]] = []
        for fragment in fragments.sorted(by: { $0.y < $1.y }) {
            if let last = rows.last, let anchor = last.first,
               abs((fragment.y + fragment.height / 2) - (anchor.y + anchor.height / 2)) < anchor.height * 0.6 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        let lines = rows.map { row in
            row.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }
        return lines.joined(separator: keepLineBreaks ? "\n" : " ")
    }
}

public enum CapturedLink {
    /// Only web links may be opened from a scanned code. `file:` and custom schemes never are.
    public static func openableURL(_ payload: String) -> URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

public enum AutomationPolicy: String, CaseIterable, Sendable {
    case ask, always, never

    public var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .always: return "Always allow"
        case .never: return "Never allow"
        }
    }
}

public enum IconCommand: Equatable, Sendable {
    case hide, show, toggle
}

public enum AutomationCommand: Equatable, Sendable {
    case capture(ShortcutAction)
    case captureRegion(CGRect, display: Int)
    case icons(IconCommand)
    case openHome
    case openSettings

    public static let scheme = "snapframe"

    public static func parse(_ url: URL) -> AutomationCommand? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased()
        else { return nil }

        func number(_ name: String) -> Double? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap(Double.init)
        }

        switch host {
        case "capture-area":
            if let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") {
                guard width > 0, height > 0, x >= 0, y >= 0 else { return nil }
                return .captureRegion(CGRect(x: x, y: y, width: width, height: height), display: max(Int(number("display") ?? 0), 0))
            }
            return .capture(.area)
        case "capture-window": return .capture(.window)
        case "capture-fullscreen": return .capture(.fullscreen)
        case "capture-previous-area": return .capture(.previousArea)
        case "self-timer": return .capture(.selfTimer)
        case "all-in-one": return .capture(.allInOne)
        case "scrolling-capture": return .capture(.scrolling)
        case "capture-text": return .capture(.text)
        case "toggle-desktop-icons": return .icons(.toggle)
        case "hide-desktop-icons": return .icons(.hide)
        case "show-desktop-icons": return .icons(.show)
        case "open-home": return .openHome
        case "open-settings": return .openSettings
        default: return nil
        }
    }
}
