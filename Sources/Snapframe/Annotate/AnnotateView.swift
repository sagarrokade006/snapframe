import AppKit
import SnapframeCore
import SwiftUI

struct AnnotateView: View {
    @ObservedObject var session: AnnotateSession
    @State private var askingPassword = false

    private static let backgrounds: [CanvasFill] = [
        .none,
        .color(0x5C8B94), .color(0x2A2C30), .color(0xC9694A), .color(0x6B7F4E), .color(0x6A4C74), .color(0xD8CDB8), .color(0xF4F3F0),
        .gradient(0xFF8A63, 0xC7A6E8), .gradient(0x6FD3C2, 0x3D8BFF), .gradient(0xF2C14E, 0xFF6B3D), .gradient(0x2A2C30, 0x5C8B94),
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            toolBar
            optionsBar
            HStack(spacing: 0) {
                AnnotationCanvas(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.snapGround)
                backgroundPanel
            }
            bottomBar
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(Color.snapGround)
        .snapWindowStyle()
        .sheet(isPresented: $askingPassword) {
            PasswordSheet { password in
                askingPassword = false
                if let password { session.exportProtectedPDF(password: password) }
            }
        }
        .alert("Snapframe", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.message ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Text("Annotate").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(QuietButtonStyle()).disabled(!session.canUndo).opacity(session.canUndo ? 1 : 0.45)
                .keyboardShortcut("z", modifiers: .command)
            Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .buttonStyle(QuietButtonStyle()).disabled(!session.canRedo).opacity(session.canRedo ? 1 : 0.45)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Duplicate") { session.duplicateSelection() }
                .buttonStyle(QuietButtonStyle()).disabled(session.selected == nil).opacity(session.selected == nil ? 0.45 : 1)
                .keyboardShortcut("d", modifiers: .command)
        }
        .padding(.leading, 90)
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(Color.snapSidebar)
    }

    private var toolBar: some View {
        HStack(spacing: 2) {
            ForEach(AnnotateTool.allCases) { tool in
                Button {
                    session.tool = tool
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbol).font(.system(size: 17)).frame(height: 21)
                        Text(tool.title).font(.system(size: 11))
                    }
                    .frame(width: 66, height: 52)
                    .foregroundStyle(session.tool == tool ? Color.snapInk : Color.snapText)
                    .background(session.tool == tool ? Color.snapAccent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 62)
        .background(Color.snapSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.snapRaised).frame(height: 1) }
    }

    private var optionsBar: some View {
        HStack(spacing: 14) {
            Text(session.tool.title).font(.system(size: 13, weight: .semibold))
            Text(session.tool.hint).font(.system(size: 13)).foregroundStyle(Color(hex: 0xC4C6CC)).lineLimit(1)
            Spacer()
            contextualControls
            if session.tool.usesLineWidth { widthControl }
            if session.tool.usesColor { colorControl }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color.snapCard)
    }

    @ViewBuilder
    private var contextualControls: some View {
        switch session.tool {
        case .crop:
            Button("Apply Crop") { session.applyCrop() }.buttonStyle(QuietButtonStyle()).disabled(session.pendingCrop == nil)
            Button("Reset") { session.resetCrop() }.buttonStyle(QuietButtonStyle()).disabled(session.document.crop == nil)
        case .redact:
            PillSegment(options: RedactionMode.allCases.map { ($0, $0.title) }, selection: $session.redactionMode).frame(width: 270)
        case .spotlight:
            PillSegment(options: [(false, "Rectangle"), (true, "Oval")], selection: $session.spotlightOval).frame(width: 190)
        case .image:
            Button("From File…") { session.addImageFromFile() }.buttonStyle(QuietButtonStyle())
            Button("From Clipboard") { session.addImageFromClipboard() }.buttonStyle(QuietButtonStyle())
        default:
            EmptyView()
        }
    }

    private var widthControl: some View {
        PillSegment(options: [(CGFloat(2), "S"), (CGFloat(4), "M"), (CGFloat(8), "L")], selection: $session.lineWidth, activeFill: .snapText)
            .frame(width: 126)
            .accessibilityLabel("Stroke size")
    }

    private var colorControl: some View {
        HStack(spacing: 6) {
            ForEach(AnnotateSession.palette, id: \.hex) { entry in
                Button {
                    session.color = entry.hex
                } label: {
                    Circle()
                        .fill(Color(hex: entry.hex))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(session.color == entry.hex ? Color.snapText : Color(hex: 0x55575E), lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.name)
            }
        }
    }

    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Background").font(.system(size: 14, weight: .semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(Self.backgrounds.enumerated()), id: \.offset) { _, fill in
                    Button {
                        session.setFill(fill)
                    } label: {
                        swatch(fill)
                            .frame(height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(session.document.style.fill == fill ? Color.snapAccent : Color.snapLine, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(fill == .none ? "No background" : "Background")
                }
            }

            sliderRow("Padding", value: $session.document.style.padding, range: 8...140, display: "\(Int(session.document.style.padding))")
            sliderRow("Corner radius", value: $session.document.style.cornerRadius, range: 0...40, display: "\(Int(session.document.style.cornerRadius))")
            sliderRow("Shadow", value: $session.document.style.shadow, range: 0...1, display: "\(Int(session.document.style.shadow * 100))%")

            Button("Use for New Edits") { session.useStyleAsDefault() }
                .buttonStyle(QuietButtonStyle())
                .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(18)
        .frame(width: 262)
        .frame(maxHeight: .infinity)
        .background(Color.snapSidebar)
    }

    @ViewBuilder
    private func swatch(_ fill: CanvasFill) -> some View {
        switch fill {
        case .none:
            ZStack {
                Color.snapRaised
                Image(systemName: "slash.circle").foregroundStyle(Color.snapMuted)
            }
        case .color(let hex):
            Color(hex: hex)
        case .gradient(let start, let end):
            LinearGradient(colors: [Color(hex: start), Color(hex: end)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(display).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            }
            Slider(value: value, in: range) { editing in
                if !editing { session.commit() }
            }
            .disabled(session.document.style.fill == .none)
            .accessibilityLabel(title)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(verbatim: sizeLabel).font(.system(size: 13)).foregroundStyle(Color.snapMuted).monospacedDigit()
            Spacer()
            Button("Float") { session.float() }.buttonStyle(QuietButtonStyle())
            Button("Share…") { session.share() }.buttonStyle(QuietButtonStyle())
            Button("Protected PDF…") { askingPassword = true }.buttonStyle(QuietButtonStyle())
            Button("Save Project…") { session.saveProject() }.buttonStyle(QuietButtonStyle())
            Button("Save As…") { session.saveAs() }.buttonStyle(QuietButtonStyle())
            Button("Copy") { session.copyToClipboard() }.buttonStyle(QuietButtonStyle())
            Button("Done") { session.finish() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color.snapSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.snapRaised).frame(height: 1) }
    }

    private var sizeLabel: String {
        let output = session.document.outputSize
        let scale = session.renderer.scale
        return "\(Int((output.width * scale).rounded())) × \(Int((output.height * scale).rounded()))"
    }
}

private struct PasswordSheet: View {
    let finish: (String?) -> Void

    @State private var password = ""
    @State private var repeated = ""

    private var isValid: Bool { !password.isEmpty && password == repeated }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Protect with a password").font(.snapDisplay(20))
            Text("The PDF can only be opened with this password. Snapframe can't recover it if you forget.")
                .font(.system(size: 13))
                .foregroundStyle(Color.snapMuted)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Repeat password", text: $repeated).textFieldStyle(.roundedBorder)
            if !repeated.isEmpty && password != repeated {
                Text("The passwords don't match.").font(.system(size: 13)).foregroundStyle(Color.snapAccent)
            }
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.buttonStyle(QuietButtonStyle())
                Button("Continue") { finish(password) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Color.snapSidebar)
        .snapWindowStyle()
    }
}
