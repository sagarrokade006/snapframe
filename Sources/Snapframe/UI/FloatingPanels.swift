import AppKit
import SnapframeCore
import SwiftUI

/// Lets the first click act on a button without activating Snapframe first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class KeylessPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// The preview card shown after each capture.
@MainActor
final class QuickAccessController {
    static let shared = QuickAccessController()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    private static func size(for style: QuickCardStyle) -> CGSize {
        style == .hover ? HoverQuickCard.size : CGSize(width: 356, height: 312)
    }

    /// Where a share menu opened from the card should attach.
    var shareWindow: NSWindow? { panel }

    func show(_ item: CaptureItem, message: String) {
        close()
        let style = AppSettings.shared.quickCardStyle
        let close: () -> Void = { [weak self] in self?.close() }
        let hovering: (Bool) -> Void = { [weak self] inside in
            if inside { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
        }
        let card = Group {
            if style == .hover {
                HoverQuickCard(item: item, message: message, close: close, hovering: hovering)
            } else {
                QuickAccessCard(item: item, message: message, close: close, hovering: hovering)
            }
        }

        let panel = KeylessPanel(size: Self.size(for: style))
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: card)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func close() {
        dismissal?.cancel()
        panel?.close()
        panel = nil
    }
}

struct QuickAccessCard: View {
    let item: CaptureItem
    let message: String
    let close: () -> Void
    let hovering: (Bool) -> Void

    private var library: CaptureLibrary { .shared }

    var body: some View {
        VStack(spacing: 0) {
            CaptureThumbnail(item: item).frame(height: 196).clipped()

            HStack {
                Text(message).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(verbatim: "\(item.pixelWidth) × \(item.pixelHeight)").font(.system(size: 12)).foregroundStyle(Color.snapMuted)
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 4)

            HStack(spacing: 4) {
                if item.isStudio {
                    quick("Open Editor", "film") { StudioController.shared.open(item) }
                } else {
                    quick("Copy", "doc.on.doc") { library.copy(item) }
                }
                if item.isStudio {
                    EmptyView()
                } else if item.isVideo {
                    quick("Play", "play.fill") { library.open(item) }
                    if item.canTrim {
                        quick("Trim", "timeline.selection") { TrimController.shared.open(item) }
                    }
                } else {
                    quick("Edit", "pencil.tip.crop.circle") { AnnotateController.shared.open(item) }
                    quick("Float", "pip") { PinController.shared.pin(item) }
                }
                quick("Reveal", "folder") { library.reveal(item) }
                quick("Close", "xmark") {}
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 9)
        }
        .frame(width: 356, height: 312)
        .background(Color.snapSidebar)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.snapLine))
        .snapWindowStyle()
        .onHover(perform: hovering)
    }

    private func quick(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
            close()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A clean preview whose controls appear when the pointer is over it.
struct HoverQuickCard: View {
    static let size = CGSize(width: 340, height: 222)

    let item: CaptureItem
    let message: String
    let close: () -> Void
    let hovering: (Bool) -> Void
    /// Lets previews show the controls without a pointer.
    var showsControls = false

    @State private var inside = false

    private var library: CaptureLibrary { .shared }
    private var isImage: Bool { !item.isVideo && !item.isStudio }
    private var visible: Bool { inside || showsControls }

    private func run(_ action: () -> Void) {
        action()
        close()
    }

    private func corner(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.snapOnText)
                .background(Color.snapText, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 36)
                .foregroundStyle(Color.snapOnText)
                .background(Color.snapText, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var center: some View {
        VStack(spacing: 8) {
            if item.isStudio {
                pill("Open Editor") { run { StudioController.shared.open(item) } }
            } else {
                if item.isVideo { pill("Play") { run { library.open(item) } } }
                pill("Copy") { run { library.copy(item) } }
                pill("Save") {
                    close()
                    library.saveCopy(item)
                }
            }
        }
    }

    private var controls: some View {
        ZStack {
            Color.snapGround.opacity(0.55)
            center
            VStack {
                HStack {
                    corner("Close", "xmark", action: close)
                    Spacer()
                    if isImage {
                        corner("Float above windows", "pip") { run { PinController.shared.pin(item) } }
                    } else {
                        corner("Reveal in Finder", "folder") { run { library.reveal(item) } }
                    }
                }
                Spacer()
                HStack {
                    if isImage {
                        corner("Edit", "pencil.tip.crop.circle") { run { AnnotateController.shared.open(item) } }
                    } else if item.canTrim {
                        corner("Trim", "timeline.selection") { run { TrimController.shared.open(item) } }
                    }
                    Spacer()
                    if !item.isStudio {
                        corner("Share", "square.and.arrow.up") {
                            if let window = QuickAccessController.shared.shareWindow {
                                ShareSheet.show(library.existingFile(for: item), in: window)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureThumbnail(item: item)
                .frame(width: Self.size.width, height: Self.size.height)
                .blur(radius: visible ? 7 : 0)
            if visible {
                controls
            } else {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 26)
                    .background(Color.snapSidebar.opacity(0.92), in: Capsule())
                    .padding(9)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.snapLine))
        .animation(.easeOut(duration: 0.14), value: inside)
        .contextMenu {
            Button("Reveal in Finder") { library.reveal(item) }
        }
        .snapWindowStyle()
        .onHover { now in
            inside = now
            hovering(now)
        }
    }
}

/// Keeps captures floating above other windows.
@MainActor
final class PinController {
    static let shared = PinController()

    private var panels: [NSPanel] = []

    func pin(_ item: CaptureItem) {
        guard let image = NSImage(contentsOf: CaptureLibrary.shared.imageURL(id: item.id)) else { return }
        let scale = max(item.scale, 1)
        pin(image: image, pointSize: CGSize(width: Double(item.pixelWidth) / scale, height: Double(item.pixelHeight) / scale))
    }

    func pin(image: NSImage, pointSize: CGSize) {
        var size = pointSize
        let limit = min(720 / size.width, 520 / size.height, 1)
        size = CGSize(width: size.width * limit, height: size.height * limit)

        let panel = KeylessPanel(size: size)
        panel.level = .floating
        panel.isMovableByWindowBackground = true

        let view = PinnedImageView(image: image) { [weak self, weak panel] in
            guard let panel else { return }
            panel.close()
            self?.panels.removeAll { $0 === panel }
        }
        panel.contentView = FirstMouseHostingView(rootView: view)

        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrameOrigin(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        panel.orderFrontRegardless()
        panels.append(panel)
    }
}

/// The corner handle on a pin. It tracks the mouse itself, so dragging resizes rather than moves the window.
final class PinResizeHandle: NSView {
    /// Tests can replace the real pointer.
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = pointer()
        let startFrame = window.frame
        let screen = window.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? startFrame

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            let now = pointer()
            // The top-left corner stays put, so the room available is what lies to its right and below it.
            let limit = CGSize(width: max(area.maxX - startFrame.minX, 1), height: max(startFrame.maxY - area.minY, 1))
            let size = PinSizing.resized(from: startFrame.size, dragX: now.x - start.x, dragY: start.y - now.y, limit: limit)
            window.setFrame(CGRect(x: startFrame.minX, y: startFrame.maxY - size.height, width: size.width, height: size.height), display: true)
            window.invalidateShadow()
        }
    }
}

private struct PinResizeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PinResizeHandle { PinResizeHandle() }
    func updateNSView(_ view: PinResizeHandle, context: Context) {}
}

struct PinnedImageView: View {
    let image: NSImage
    let close: () -> Void
    /// Lets previews show the controls without a pointer.
    var showsControls = false
    var startingOpacity = 1.0

    @State private var inside = false
    @State private var opacity: Double?

    private var visible: Bool { inside || showsControls }
    private var current: Double { opacity ?? startingOpacity }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .opacity(current)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if visible {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(Color.white)
                            .background(Color.snapInk.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close pin")
                    .padding(7)
                }
            }
            .overlay(alignment: .bottom) {
                if visible {
                    Slider(value: Binding(get: { current }, set: { opacity = $0 }), in: PinSizing.opacityRange)
                        .controlSize(.mini)
                        .tint(Color.white)
                        .frame(width: 84)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.snapInk.opacity(0.85), in: Capsule())
                        .padding(7)
                        .accessibilityLabel("Pin opacity")
                        .help("Make the pin more see-through")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if visible {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Color.white)
                        .background(Color.snapInk.opacity(0.85), in: Circle())
                        .overlay(PinResizeArea())
                        .padding(7)
                        .accessibilityHidden(true)
                        .help("Drag to resize")
                }
            }
            .onHover { inside = $0 }
    }
}
