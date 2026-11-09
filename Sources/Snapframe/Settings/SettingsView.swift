import AppKit
import ServiceManagement
import SnapframeCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case screenshots = "Screenshots"
    case updates = "Updates"
    case about = "About"

    var id: String { rawValue }
}

struct SettingsView: View {
    @State var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        Text(item.rawValue)
                            .fontWeight(.medium)
                            .foregroundStyle(pane == item ? Color.black : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(pane == item ? Color.snapAccent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 190)
            .background(Color.black.opacity(0.25))

            Group {
                switch pane {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .screenshots: ScreenshotsPane()
                case .updates: UpdatesPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 580)
        .background(Color.snapPanel)
        .preferredColorScheme(.dark)
        .tint(Color.snapAccent)
    }
}

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: setLaunchAtLogin
                ))
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Play sound after capture", isOn: $settings.playSound)
            }
            Section("After capture") {
                Picker("Action", selection: $settings.afterCapture) {
                    ForEach(AfterCapture.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Export folder") {
                    HStack {
                        Text(settings.exportDirectory.lastPathComponent)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Hold Control while capturing to copy without saving.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Self-timer") {
                Picker("Default delay", selection: $settings.timerSeconds) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.exportDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.exportPath = url.path
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(action: action)
                }
            } footer: {
                Text("Click a shortcut, then press a new one. Press Delete to clear it, or Esc to cancel.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    private var warning: String? {
        if rejected { return "Include ⌘, ⌃ or ⌥" }
        if hotKeys.failed.contains(action) { return "In use by another app" }
        return settings.conflictMessage(for: action)
    }

    var body: some View {
        LabeledContent(action.title) {
            HStack(spacing: 10) {
                if let warning {
                    Text(warning).font(.callout).foregroundStyle(Color.snapAccent)
                }
                Button(recording ? "Press keys…" : (settings.shortcuts[action]?.displayString ?? "Not set")) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 100)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        rejected = false
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeyCenter.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            stop()
        case 51, 117:
            settings.shortcuts[action] = nil
            stop()
        default:
            let flags = event.modifierFlags
            var modifiers: ShortcutModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            guard shortcut.isValidGlobalShortcut else {
                rejected = true
                return
            }
            rejected = false
            settings.shortcuts[action] = shortcut
            stop()
        }
    }
}

private struct ScreenshotsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var preview: String {
        NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: "Area") + "." + settings.format.fileExtension
    }

    var body: some View {
        Form {
            Section("File") {
                Picker("Format", selection: $settings.format) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.format.usesQuality {
                    LabeledContent("Quality") {
                        Slider(value: $settings.quality, in: 0.3...1).frame(width: 200)
                    }
                }
                TextField("File name", text: $settings.namePattern)
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Tokens: " + NameTemplate.tokens.map { "{\($0)}" }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Image") {
                Toggle("Scale Retina captures to 1x", isOn: $settings.scaleTo1x)
                Toggle("Convert to sRGB", isOn: $settings.convertToSRGB)
                Toggle("Capture window shadow", isOn: $settings.windowShadow)
                Toggle("Show cursor", isOn: $settings.showCursor)
            }
            Section("Selection") {
                Toggle("Freeze screen during selection", isOn: $settings.freezeScreen)
                Toggle("Adjust selection before capturing", isOn: $settings.adjustBeforeCapture)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdatesPane: View {
    @ObservedObject private var updates = UpdateController.shared

    private var lastChecked: String {
        updates.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    var body: some View {
        Form {
            if updates.isConfigured {
                Section {
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                    LabeledContent("Last checked", value: lastChecked)
                    Button("Check Now") { updates.checkForUpdates() }
                } footer: {
                    Text("Snapframe checks GitHub for new releases. Your captures never leave this Mac.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Updates are not set up in this build.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        Form {
            LabeledContent("Name", value: "Snapframe")
            LabeledContent("Version", value: version)
            LabeledContent("Minimum macOS", value: "14.0")
        }
        .formStyle(.grouped)
    }
}
