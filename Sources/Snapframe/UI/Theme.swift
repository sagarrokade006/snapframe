import AppKit
import SnapframeCore
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let snapAccent = Color(hex: 0xFF6B3D)
    static let snapPanel = Color(nsColor: Palette.panel)
    static let snapGround = Color(hex: 0x101113)
    static let snapSidebar = Color(hex: 0x17181B)
    static let snapCard = Color(hex: 0x1F2125)
    static let snapRaised = Color(hex: 0x2C2E33)
    static let snapLine = Color(hex: 0x32343A)
    static let snapText = Color(hex: 0xF4F3F0)
    static let snapMuted = Color(hex: 0xA8ABB3)
    static let snapTeal = Color(hex: 0x6FD3C2)
    static let snapInk = Color(hex: 0x17181A)
}

extension Font {
    static func snapDisplay(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

extension ShortcutAction {
    var symbol: String {
        switch self {
        case .allInOne: return "square.grid.2x2"
        case .area: return "viewfinder"
        case .previousArea: return "gobackward"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .selfTimer: return "timer"
        }
    }
}

extension View {
    func snapCard(radius: CGFloat = 14) -> some View {
        background(Color.snapCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Applies the dark look and accent shared by every Snapframe window.
    func snapWindowStyle() -> some View {
        preferredColorScheme(.dark).tint(.snapAccent).foregroundStyle(Color.snapText)
    }
}

struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 34
            context.fill(
                Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 8 * unit),
                with: .color(Color(hex: 0x26282D))
            )
            var corners = Path()
            let segments: [[CGPoint]] = [
                [.init(x: 8, y: 12), .init(x: 8, y: 8), .init(x: 12, y: 8)],
                [.init(x: 22, y: 8), .init(x: 26, y: 8), .init(x: 26, y: 12)],
                [.init(x: 26, y: 22), .init(x: 26, y: 26), .init(x: 22, y: 26)],
                [.init(x: 12, y: 26), .init(x: 8, y: 26), .init(x: 8, y: 22)],
            ]
            for segment in segments {
                corners.addLines(segment.map { CGPoint(x: $0.x * unit, y: $0.y * unit) })
            }
            context.stroke(corners, with: .color(.snapText), style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 11 * unit, y: 11 * unit, width: 12 * unit, height: 12 * unit)), with: .color(.snapAccent))
            context.fill(Path(ellipseIn: CGRect(x: 14.8 * unit, y: 14.8 * unit, width: 4.4 * unit, height: 4.4 * unit)), with: .color(Color(hex: 0x26282D)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct KeyCaps: View {
    let parts: [String]
    var fontSize: CGFloat = 14
    var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: fontSize, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(minWidth: height * 0.75, minHeight: height)
                    .background(Color(hex: 0x33353B), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.snapSidebar).frame(height: 2).padding(.horizontal, 3)
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.snapInk)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
            .background(Color.snapAccent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.snapText)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(Color.snapRaised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Icon above a small label, used for actions on a capture.
struct IconAction: View {
    let title: String
    let symbol: String
    var primary = false
    var height: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(primary ? Color.snapInk : Color.snapText)
            .background(primary ? Color.snapAccent : Color.snapRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillSegment<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var activeFill = Color.snapAccent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(selection == option.value ? Color.snapInk : Color.snapText)
                        .background(selection == option.value ? activeFill : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(hex: 0x26282D), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct CaptureThumbnail: View {
    let item: CaptureItem
    @ObservedObject private var library = CaptureLibrary.shared

    var body: some View {
        ZStack {
            Color(hex: 0x26282D)
            if let image = library.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(10)
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Color.snapMuted)
            }
        }
    }
}

/// Wraps children onto new lines, used for chips and tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (positions, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = rows(subviews, width: bounds.width).positions
        for (subview, position) in zip(subviews, positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
}

enum CaptureFormatting {
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func tagColor(_ tag: String) -> Color {
        let colors: [Color] = [.snapAccent, .snapTeal, Color(hex: 0x8FB7D9), Color(hex: 0xF2C14E), Color(hex: 0xC7A6E8)]
        return colors[tag.unicodeScalars.reduce(0) { $0 + Int($1.value) } % colors.count]
    }
}
