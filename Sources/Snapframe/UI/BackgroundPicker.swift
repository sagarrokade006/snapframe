import AppKit
import SnapframeCore
import SwiftUI

private enum FillMode: Hashable {
    case none, solid, gradient

    init(_ fill: CanvasFill) {
        switch fill {
        case .none: self = .none
        case .color: self = .solid
        case .gradient, .linear: self = .gradient
        }
    }
}

private func hexValue(of color: Color) -> UInt32 {
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
    func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
    return byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
}

struct FillSwatch: View {
    let fill: CanvasFill

    private func gradient(_ stops: [UInt32], angle: Double) -> LinearGradient {
        let line = CanvasFill.gradientLine(angle: angle, size: CGSize(width: 1, height: 1))
        return LinearGradient(colors: stops.map { Color(hex: $0) }, startPoint: UnitPoint(x: line.start.x, y: line.start.y), endPoint: UnitPoint(x: line.end.x, y: line.end.y))
    }

    var body: some View {
        switch fill {
        case .none:
            ZStack {
                Color.snapRaised
                Image(systemName: "slash.circle").foregroundStyle(Color.snapMuted)
            }
        case .color(let hex):
            Color(hex: hex)
        case .gradient(let start, let end):
            gradient([start, end], angle: 135)
        case .linear(let stops, let angle):
            gradient(stops, angle: angle)
        }
    }
}

/// None, solid or gradient backgrounds, shared by Annotate and Studio.
struct BackgroundPicker: View {
    let fill: CanvasFill
    /// Called for every change, including while dragging a color.
    let change: (CanvasFill) -> Void
    /// Called once an edit is finished, to add one undo step.
    let commit: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var mode: FillMode
    @State private var solid: Color
    @State private var start: Color
    @State private var end: Color
    @State private var angle: Double
    @State private var pendingCommit: Task<Void, Never>?

    init(fill: CanvasFill, change: @escaping (CanvasFill) -> Void, commit: @escaping () -> Void) {
        self.fill = fill
        self.change = change
        self.commit = commit
        _mode = State(initialValue: FillMode(fill))

        var solidHex: UInt32 = 0xFF6B3D
        if case .color(let hex) = fill { solidHex = hex }
        _solid = State(initialValue: Color(hex: solidHex))

        let colors = fill.gradientColors ?? [0xFF6B3D, 0x5B6CFF]
        _start = State(initialValue: Color(hex: colors[0]))
        _end = State(initialValue: Color(hex: colors[colors.count - 1]))
        if case .linear(_, let saved) = fill {
            _angle = State(initialValue: saved)
        } else {
            _angle = State(initialValue: 135)
        }
    }

    private var customGradient: CanvasFill { .linear([hexValue(of: start), hexValue(of: end)], angle: angle) }

    private func choose(_ newFill: CanvasFill) {
        pendingCommit?.cancel()
        change(newFill)
        commit()
    }

    /// Color wells report every movement and never say when they finish, so edits are grouped by a short pause.
    private func adjust(_ newFill: CanvasFill) {
        change(newFill)
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private var modeBinding: Binding<FillMode> {
        Binding(get: { mode }, set: { newMode in
            mode = newMode
            guard FillMode(fill) != newMode else { return }
            switch newMode {
            case .none: choose(.none)
            case .solid: choose(BackgroundCatalog.defaultSolid)
            case .gradient: choose(BackgroundCatalog.defaultGradient)
            }
        })
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.snapMuted)
    }

    private func button(_ swatch: CanvasFill, name: String, height: CGFloat) -> some View {
        Button {
            choose(swatch)
            mode = FillMode(swatch)
        } label: {
            FillSwatch(fill: swatch)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(fill == swatch ? Color.snapAccentText : Color.snapLine, lineWidth: fill == swatch ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(fill == swatch ? .isSelected : [])
        .help(name)
    }

    private func grid(_ presets: [BackgroundPreset], columns: Int, height: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(presets, id: \.name) { button($0.fill, name: $0.name, height: height) }
        }
    }

    private func save(_ newFill: CanvasFill) {
        settings.savedBackgrounds = BackgroundCatalog.saving(newFill, in: settings.savedBackgrounds)
    }

    private func saveButton(_ newFill: CanvasFill) -> some View {
        Button { save(newFill) } label: { Label("Save", systemImage: "plus") }
            .buttonStyle(QuietButtonStyle())
    }

    private func well(_ title: String, _ value: Binding<Color>) -> some View {
        ColorPicker(title, selection: value, supportsOpacity: false).labelsHidden().accessibilityLabel(title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            PillSegment(options: [(.none, "None"), (.solid, "Solid"), (.gradient, "Gradient")], selection: modeBinding, activeFill: .snapText)

            switch mode {
            case .none:
                Text("No background. The capture is saved on its own.")
                    .font(.system(size: 13)).foregroundStyle(Color.snapMuted).fixedSize(horizontal: false, vertical: true)
            case .solid:
                heading("Snapframe colors")
                grid(BackgroundCatalog.brandSolids, columns: 8, height: 26)
                heading("Colors")
                grid(BackgroundCatalog.solids, columns: 8, height: 26)
                heading("Make your own")
                HStack(spacing: 8) {
                    well("Custom color", Binding(get: { solid }, set: {
                        solid = $0
                        adjust(.color(hexValue(of: $0)))
                    }))
                    Text(verbatim: String(format: "#%06X", hexValue(of: solid))).font(.system(size: 13)).monospacedDigit()
                    Spacer()
                    saveButton(.color(hexValue(of: solid)))
                }
            case .gradient:
                heading("Snapframe gradients")
                grid(BackgroundCatalog.brandGradients, columns: 6, height: 34)
                heading("Gradients")
                grid(BackgroundCatalog.gradients, columns: 6, height: 34)
                heading("Make your own")
                HStack(spacing: 8) {
                    well("Gradient start", Binding(get: { start }, set: {
                        start = $0
                        adjust(customGradient)
                    }))
                    well("Gradient end", Binding(get: { end }, set: {
                        end = $0
                        adjust(customGradient)
                    }))
                    Spacer()
                    saveButton(customGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Angle").font(.system(size: 13))
                        Spacer()
                        Text(verbatim: "\(Int(angle))°").font(.system(size: 13)).foregroundStyle(Color.snapMuted).monospacedDigit()
                    }
                    Slider(value: Binding(get: { angle }, set: {
                        angle = $0
                        change(customGradient)
                    }), in: 0...360) { editing in
                        if !editing { commit() }
                    }
                    .accessibilityLabel("Gradient angle")
                }
            }

            heading("Your colors")
            if settings.savedBackgrounds.isEmpty {
                Text("Saved colors and gradients appear here.").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Array(settings.savedBackgrounds.enumerated()), id: \.offset) { _, saved in
                        button(saved, name: "Saved background", height: 26)
                            .contextMenu {
                                Button("Remove") { settings.savedBackgrounds.removeAll { $0 == saved } }
                            }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .onChange(of: fill) { _, newFill in
            // Undo can change the fill from outside the picker.
            if FillMode(newFill) != mode { mode = FillMode(newFill) }
        }
    }
}
