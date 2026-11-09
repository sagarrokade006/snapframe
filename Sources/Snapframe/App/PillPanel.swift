import AppKit

/// A small floating message used for capture results and the self-timer countdown.
@MainActor
final class PillPanel: NSPanel {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let pillView = PillContentView()

    init(message: String, fontSize: CGFloat) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = Palette.text
        label.translatesAutoresizingMaskIntoConstraints = false
        pillView.addSubview(label)
        pillView.onClick = { [weak self] in self?.onClick?() }
        contentView = pillView

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pillView.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: pillView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: pillView.bottomAnchor, constant: -12),
        ])
        update(message: message)
    }

    func update(message: String) {
        label.stringValue = message
        pillView.layoutSubtreeIfNeeded()
        setContentSize(pillView.fittingSize)
    }

    private var activeScreen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func showBottomLeft() {
        let area = activeScreen.visibleFrame
        setFrameOrigin(CGPoint(x: area.minX + 24, y: area.minY + 24))
        orderFrontRegardless()
    }

    func showCentered() {
        let area = activeScreen.visibleFrame
        setFrameOrigin(CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
        orderFrontRegardless()
    }
}

private final class PillContentView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        Palette.panel.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}
