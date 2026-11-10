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

    private static let size = CGSize(width: 356, height: 312)

    func show(_ item: CaptureItem, message: String) {
        close()
        let card = QuickAccessCard(
            item: item,
            message: message,
            close: { [weak self] in self?.close() },
            hovering: { [weak self] inside in
                if inside { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
            }
        )

        let panel = KeylessPanel(size: Self.size)
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
                quick("Copy", "doc.on.doc") { library.copy(item) }
                quick("Edit", "pencil.tip.crop.circle") { AnnotateController.shared.open(item) }
                quick("Float", "pip") { PinController.shared.pin(item) }
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
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: 0x36383E)))
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

private struct PinnedImageView: View {
    let image: NSImage
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(Color.snapText)
                            .background(Color.snapInk.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close pin")
                    .padding(7)
                }
            }
            .onHover { hovering = $0 }
    }
}
