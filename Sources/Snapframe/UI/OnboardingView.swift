import AppKit
import Combine
import SnapframeCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var step: Int
    @State private var granted = PermissionManager.isScreenRecordingGranted
    @State private var requested: Bool
    @State private var familiarKeys = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var finish: () -> Void
    var later: () -> Void

    private static let lastStep = 3

    init(initialStep: Int? = nil, finish: @escaping () -> Void, later: @escaping () -> Void) {
        let saved = initialStep ?? AppSettings.shared.onboardingStep
        let isGranted = PermissionManager.isScreenRecordingGranted
        // Past the permission step without the permission, so go back to it.
        _step = State(initialValue: saved > 1 && !isGranted && initialStep == nil ? 1 : saved)
        _requested = State(initialValue: saved >= 1 && !isGranted)
        self.finish = finish
        self.later = later
    }

    var body: some View {
        HStack(spacing: 0) {
            illustration

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0...Self.lastStep, id: \.self) { index in
                        Capsule().fill(index <= step ? Color.snapAccent : Color(hex: 0x33353B)).frame(height: 5)
                    }
                }
                .padding(.bottom, 26)

                Group {
                    switch step {
                    case 0: welcome
                    case 1: permission
                    case 2: shortcuts
                    default: ready
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                HStack {
                    if step == 0 {
                        Button("Later", action: later).buttonStyle(.plain).foregroundStyle(Color.snapMuted)
                    } else {
                        Button("Back") { step -= 1 }.buttonStyle(.plain)
                    }
                    Spacer()
                    Button(primaryTitle, action: advance)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(primaryDisabled)
                        .opacity(primaryDisabled ? 0.45 : 1)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 38)
            .padding(.top, 38)
            .padding(.bottom, 26)
        }
        .frame(width: 920, height: 580)
        .background(Color.snapSidebar)
        .snapWindowStyle()
        .onReceive(poll) { _ in granted = PermissionManager.isScreenRecordingGranted }
    }

    private var illustration: some View {
        ZStack {
            Color.snapAccent
            Canvas { context, size in
                let inset: CGFloat = 70
                let arm: CGFloat = 60
                let side = size.width - inset * 2
                let box = CGRect(x: inset, y: (size.height - side) / 2, width: side, height: side)
                var path = Path()
                path.addLines([.init(x: box.minX, y: box.minY + arm), .init(x: box.minX, y: box.minY), .init(x: box.minX + arm, y: box.minY)])
                path.addLines([.init(x: box.maxX - arm, y: box.minY), .init(x: box.maxX, y: box.minY), .init(x: box.maxX, y: box.minY + arm)])
                path.addLines([.init(x: box.maxX, y: box.maxY - arm), .init(x: box.maxX, y: box.maxY), .init(x: box.maxX - arm, y: box.maxY)])
                path.addLines([.init(x: box.minX + arm, y: box.maxY), .init(x: box.minX, y: box.maxY), .init(x: box.minX, y: box.maxY - arm)])
                context.stroke(path, with: .color(.snapInk), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            }
            Image(systemName: "camera.aperture")
                .font(.system(size: 124, weight: .regular))
                .foregroundStyle(Color.snapInk)
        }
        .frame(width: 370)
        .accessibilityHidden(true)
    }

    private func heading(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.snapDisplay(34)).fixedSize(horizontal: false, vertical: true)
            Text(body).font(.system(size: 16)).foregroundStyle(Color(hex: 0xC4C6CC)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Capture anything on your Mac", "Free, fast and private. Snapframe lives in your menu bar and is one shortcut away.")
            benefit("viewfinder", "Area, window, fullscreen and timed captures")
            benefit("square.grid.2x2", "Every capture kept in one library")
            benefit("lock", "No accounts, no cloud, no subscriptions")
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Color(hex: 0xFF8A63)).frame(width: 24)
            Text(text).font(.system(size: 14, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .snapCard(radius: 11)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Allow Screen Recording", "macOS requires this before any app can capture your screen. Your captures stay on this Mac.")

            HStack(spacing: 14) {
                Image(systemName: granted ? "checkmark" : "exclamationmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.snapInk)
                    .frame(width: 44, height: 44)
                    .background(granted ? Color.snapTeal : Color(hex: 0xFF8A63), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Screen Recording is on" : "Screen Recording is off").font(.system(size: 14, weight: .semibold))
                    Text(granted ? "Snapframe can capture your screen." : "Turn on Snapframe in System Settings.").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
                }
                Spacer()
                if !granted {
                    Button(requested ? "Open Settings" : "Allow Access") {
                        if requested {
                            PermissionManager.openSystemSettings()
                        } else {
                            requested = true
                            PermissionManager.request()
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(18)
            .snapCard()

            if !granted && requested {
                Text("After turning it on, restart Snapframe so macOS applies the change.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.snapMuted)
                    .padding(.top, 12)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Pick your shortcuts", "You can change any of them later in Settings.")
            layoutOption(familiar: false, title: "Keep macOS shortcuts", detail: "Snapframe uses Control and Option.", key: ["⌃", "⌥", "4"])
            layoutOption(familiar: true, title: "Use the familiar keys", detail: "Turn off the macOS screenshot shortcuts first.", key: ["⇧", "⌘", "4"])
            if familiarKeys {
                Button("Open Keyboard Settings") { PermissionManager.openKeyboardSettings() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func layoutOption(familiar: Bool, title: String, detail: String, key: [String]) -> some View {
        Button {
            familiarKeys = familiar
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
                }
                Spacer()
                KeyCaps(parts: key)
            }
            .padding(15)
            .snapCard(radius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(familiarKeys == familiar ? Color.snapAccent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("You're ready", "Try your first capture. Snapframe will be waiting in the menu bar.")
            VStack(spacing: 12) {
                KeyCaps(parts: settings.shortcuts[.area]?.keyParts ?? [], fontSize: 26, height: 54)
                Text("Press this, then drag across your screen").font(.system(size: 14)).foregroundStyle(Color(hex: 0xC4C6CC))
            }
            .frame(maxWidth: .infinity)
            .padding(26)
            .snapCard()
        }
    }

    private var needsRestart: Bool { step == 1 && requested && !granted }

    private var primaryTitle: String {
        if step == Self.lastStep { return "Start Using Snapframe" }
        return needsRestart ? "Restart Snapframe" : "Continue"
    }

    private var primaryDisabled: Bool { step == 1 && !granted && !requested }

    private func advance() {
        if needsRestart {
            settings.onboardingStep = 2
            AppRelauncher.relaunch()
            return
        }
        if step == 2 && familiarKeys { applyFamiliarKeys() }
        if step == Self.lastStep {
            settings.onboardingCompleted = true
            settings.onboardingStep = 0
            finish()
        } else {
            step += 1
            settings.onboardingStep = step
        }
    }

    private func applyFamiliarKeys() {
        let modifiers: ShortcutModifiers = [.shift, .command]
        settings.shortcuts[.area] = Shortcut(keyCode: 21, modifiers: modifiers)
        settings.shortcuts[.window] = Shortcut(keyCode: 23, modifiers: modifiers)
        settings.shortcuts[.fullscreen] = Shortcut(keyCode: 20, modifiers: modifiers)
    }
}
