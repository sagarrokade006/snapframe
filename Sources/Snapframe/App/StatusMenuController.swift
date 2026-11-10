import AppKit
import Combine
import SnapframeCore
import SwiftUI

/// Owns the menu-bar icon and the popover it opens.
@MainActor
final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var updateObserver: AnyCancellable?

    var onCapture: ((ShortcutAction) -> Void)?
    var onOpenHome: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override init() {
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Snapframe")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            capture: { [weak self] action in
                self?.popover.performClose(nil)
                self?.onCapture?(action)
            },
            openHome: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenHome?()
            },
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenSettings?()
            }
        ))

        updateObserver = UpdateController.shared.$availableVersion.sink { [weak self] version in
            self?.statusItem.button?.contentTintColor = version == nil ? nil : Palette.accent
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

struct PopoverView: View {
    @ObservedObject private var library = CaptureLibrary.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var iconCover = DesktopIconCover.shared
    @ObservedObject private var updates = UpdateController.shared

    var capture: (ShortcutAction) -> Void
    var openHome: () -> Void
    var openSettings: () -> Void

    @State private var showPinned = false

    private var thumbs: [CaptureItem] {
        Array((showPinned ? library.index.items.filter(\.isPinned) : library.index.items).prefix(3))
    }

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 9) {
                BrandMark(size: 30)
                Text("Snapframe").font(.snapDisplay(16))
                Spacer()
                Button("Open Home", action: openHome).buttonStyle(QuietButtonStyle())
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 12, height: 18)
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Settings")
            }

            if let version = updates.availableVersion {
                Button {
                    updates.checkForUpdates()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Snapframe \(version) is available").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("Update").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.snapInk)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.snapAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                tile(.area, "Area", primary: true)
                tile(.window, "Window")
                tile(.fullscreen, "Fullscreen")
                tile(.previousArea, "Previous")
                tile(.selfTimer, "Timer")
                tile(.allInOne, "All-In-One")
                tile(.scrolling, "Scrolling")
                tile(.text, "Text")
                tile(.toggleDesktopIcons, iconCover.isVisible ? "Show Icons" : "Hide Icons")
            }

            HStack {
                PillSegment(options: [(false, "Recent"), (true, "Pinned")], selection: $showPinned, activeFill: .snapText)
                    .frame(width: 170)
                Spacer()
                Button("Show all", action: openHome)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.snapMuted)
            }

            HStack(spacing: 8) {
                ForEach(thumbs) { item in
                    Button {
                        library.selectedID = item.id
                        openHome()
                    } label: {
                        CaptureThumbnail(item: item)
                            .frame(height: 82)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                }
                if thumbs.isEmpty {
                    Text(showPinned ? "Nothing pinned yet" : "Your captures will appear here")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.snapMuted)
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .snapCard(radius: 9)
                }
                ForEach(0..<(thumbs.isEmpty ? 0 : 3 - thumbs.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, minHeight: 82)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("After capture").font(.system(size: 13, weight: .medium))
                PillSegment(
                    options: AfterCapture.allCases.map { ($0, $0.shortTitle) },
                    selection: $settings.afterCapture
                )
            }

            Rectangle().fill(Color.snapRaised).frame(height: 1)

            HStack {
                statusLine
                Spacer()
                Button("Quit Snapframe") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
            }
        }
        .padding(14)
        .frame(width: 384)
        .background(Color.snapSidebar)
        .snapWindowStyle()
    }

    @ViewBuilder
    private var statusLine: some View {
        if updates.isConfigured {
            Button("Check for Updates") { updates.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.snapTeal)
        } else {
            Text("Version \(UpdateService.currentVersion.description)").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
        }
    }

    private func tile(_ action: ShortcutAction, _ title: String, primary: Bool = false) -> some View {
        Button {
            capture(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.symbol).font(.system(size: 18))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(settings.shortcuts[action]?.displayString ?? " ").font(.system(size: 11)).opacity(0.78)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .foregroundStyle(primary ? Color.snapInk : Color.snapText)
            .background(primary ? Color.snapAccent : Color.snapCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(primary ? Color.snapAccent : Color.snapLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
