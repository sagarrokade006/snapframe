import AppKit
import ServiceManagement
import SnapframeCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case recording = "Recording"
    case files = "Files"
    case shortcuts = "Shortcuts"
    case updates = "Updates"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .capture: return "viewfinder"
        case .recording: return "record.circle.fill"
        case .files: return "doc.fill"
        case .shortcuts: return "keyboard.fill"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle.fill"
        }
    }

    var tile: Color {
        switch self {
        case .general: return Color(hex: 0xFF8A63)
        case .capture: return .snapTeal
        case .recording: return Color(hex: 0xFF6B6B)
        case .files: return Color(hex: 0xF2C14E)
        case .shortcuts: return Color(hex: 0x8FB7D9)
        case .updates: return Color(hex: 0xC7A6E8)
        case .about: return Color(hex: 0xD9D7D0)
        }
    }

    var intro: String {
        switch self {
        case .general: return "How Snapframe starts and responds."
        case .capture: return "What happens while you select."
        case .recording: return "Defaults for video and GIF capture."
        case .files: return "How captures are named and saved."
        case .shortcuts: return "Click any shortcut, then press the new keys."
        case .updates: return "New versions arrive from GitHub."
        case .about: return "Free, and your captures stay on this Mac."
        }
    }
}

struct SettingsView: View {
    @State var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.snapInk)
                                .frame(width: 30, height: 30)
                                .background(item.tile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(item.rawValue).font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 46)
                        .background(pane == item ? Color.snapRaised : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 44)
            .frame(width: 236)
            .background(Color.snapSidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.rawValue).font(.snapDisplay(26))
                        Text(pane.intro).font(.system(size: 14)).foregroundStyle(Color.snapMuted)
                    }
                    switch pane {
                    case .general: GeneralPane()
                    case .capture: CapturePane()
                    case .recording: RecordingPane()
                    case .files: FilesPane()
                    case .shortcuts: ShortcutsPane()
                    case .updates: UpdatesPane()
                    case .about: AboutPane()
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 34)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1060, height: 700)
        .background(Color.snapGround)
        .snapWindowStyle()
    }
}

// MARK: Shared rows

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.snapMuted)
                .padding(.top, 14)
                .padding(.bottom, 6)
            content
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .snapCard()
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            }
            Spacer()
            control
        }
        .frame(minHeight: 56)
        .overlay(alignment: .top) { Rectangle().fill(Color.snapRaised).frame(height: 1) }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(.snapAccent)
        }
    }
}

private struct ChoiceMenu<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minWidth: 130, minHeight: 34)
            .background(Color.snapRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Panes

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsGroup(title: "Startup") {
            ToggleRow(
                title: "Launch at login",
                detail: loginError ?? "Be ready as soon as you sign in",
                isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)
            )
            ToggleRow(title: "Open Home when Snapframe starts", detail: "Otherwise it waits quietly in the menu bar", isOn: $settings.openHomeAtLaunch)
        }
        SettingsGroup(title: "Feedback") {
            ToggleRow(title: "Capture sound", detail: "Play a sound after each capture", isOn: $settings.playSound)
            SettingRow(title: "After capture", detail: "Hold Control while capturing to copy only") {
                ChoiceMenu(options: AfterCapture.allCases.map { ($0, $0.title) }, selection: $settings.afterCapture)
            }
        }
        SettingsGroup(title: "Desktop") {
            ToggleRow(title: "Hide desktop icons while capturing", detail: "Shows only your wallpaper in screenshots", isOn: $settings.hideIconsWhileCapturing)
        }
        SettingsGroup(title: "Automation") {
            SettingRow(title: "Commands from other apps", detail: "Controls snapframe:// links from scripts and launchers") {
                ChoiceMenu(options: AutomationPolicy.allCases.map { ($0, $0.title) }, selection: $settings.automationPolicy)
            }
        }
        SettingsGroup(title: "Self-timer") {
            SettingRow(title: "Default delay", detail: "Used by the Self-Timer action") {
                ChoiceMenu(options: [3, 5, 10].map { ($0, "\($0) seconds") }, selection: $settings.timerSeconds)
            }
        }
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
}

private struct CapturePane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup(title: "Selection") {
            ToggleRow(title: "Freeze screen", detail: "Hold the screen still while you select", isOn: $settings.freezeScreen)
            ToggleRow(title: "Adjust before capturing", detail: "Show handles, then press Return", isOn: $settings.adjustBeforeCapture)
        }
        SettingsGroup(title: "Image") {
            ToggleRow(title: "Window shadow", detail: "Keep the shadow around windows", isOn: $settings.windowShadow)
            ToggleRow(title: "Show cursor", detail: "Include the pointer in captures", isOn: $settings.showCursor)
            ToggleRow(title: "Scale Retina to 1x", detail: "Save smaller images", isOn: $settings.scaleTo1x)
            ToggleRow(title: "Convert to sRGB", detail: "Consistent colors everywhere", isOn: $settings.convertToSRGB)
        }
        SettingsGroup(title: "Text recognition") {
            ToggleRow(title: "Keep line breaks", detail: "Copy text with the same lines as the image", isOn: $settings.keepLineBreaks)
            ToggleRow(title: "Detect language", detail: "Runs on this Mac", isOn: $settings.detectTextLanguage)
        }
        SettingsGroup(title: "Library") {
            SettingRow(title: "Auto-delete captures", detail: "Library copies only. Pinned captures and saved files are kept") {
                ChoiceMenu(options: [(7, "After 7 days"), (30, "After 30 days"), (180, "After 6 months"), (0, "Never")], selection: Binding(
                    get: { settings.libraryRetentionDays },
                    set: {
                        settings.libraryRetentionDays = $0
                        CaptureLibrary.shared.purgeExpired()
                    }
                ))
            }
        }
    }
}

private struct RecordingPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup(title: "Quality") {
            SettingRow(title: "Frame rate", detail: "Higher is smoother, with larger files") {
                ChoiceMenu(options: [(60, "60 fps"), (30, "30 fps"), (24, "24 fps")], selection: $settings.recordFramesPerSecond)
            }
            SettingRow(title: "Maximum resolution", detail: "Limits the height of the video") {
                ChoiceMenu(options: [(0, "Native"), (1440, "1440p"), (1080, "1080p"), (720, "720p")], selection: $settings.recordMaximumHeight)
            }
        }
        SettingsGroup(title: "While recording") {
            ToggleRow(title: "Show time in menu bar", detail: "Click the menu bar icon to stop", isOn: $settings.showRecordingTime)
            ToggleRow(title: "Highlight clicks", detail: "Draws a ripple where you click", isOn: $settings.recordClicks)
            ToggleRow(title: "Show shortcuts pressed", detail: "Needs Accessibility. Ordinary typing is never shown", isOn: $settings.recordKeystrokes)
        }
    }
}

private struct FilesPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var customText = ""

    private var chips: [String] { NameTemplate.chips(from: settings.namePattern) }

    private var unusedTokens: [String] {
        NameTemplate.tokens.map { "{\($0)}" }.filter { !chips.contains($0) }
    }

    private var preview: String {
        NameTemplate(pattern: settings.namePattern).render(date: Date(), mode: "Area") + "." + settings.format.fileExtension
    }

    private func setChips(_ newChips: [String]) {
        settings.namePattern = NameTemplate.pattern(from: newChips)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File name").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Reset") { settings.namePattern = NameTemplate.defaultPattern }.buttonStyle(QuietButtonStyle())
            }

            FlowLayout {
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    Button {
                        var updated = chips
                        updated.remove(at: index)
                        setChips(updated)
                    } label: {
                        Text(NameTemplate.chipTitle(chip))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.snapInk)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Color.snapAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(Color.snapGround, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.snapLine))

            FlowLayout {
                Text("Add").font(.system(size: 13)).foregroundStyle(Color.snapMuted).frame(height: 28)
                ForEach(unusedTokens, id: \.self) { token in
                    Button {
                        setChips(chips + [token])
                    } label: {
                        Text(NameTemplate.chipTitle(token))
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color(hex: 0x3F4148)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("Custom text", text: $customText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(width: 120, height: 28)
                    .background(Color.snapRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onSubmit {
                        setChips(chips + NameTemplate.chips(from: customText))
                        customText = ""
                    }
            }

            HStack(spacing: 10) {
                Image(systemName: "doc").foregroundStyle(Color(hex: 0xFF8A63))
                Text(preview).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.snapSidebar, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(18)
        .snapCard()

        HStack(spacing: 10) {
            ForEach(ImageFormat.allCases, id: \.self) { format in
                Button {
                    settings.format = format
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(format.title).font(.system(size: 18, weight: .semibold))
                        Text(description(format)).font(.system(size: 13)).foregroundStyle(Color.snapMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    .snapCard(radius: 12)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(settings.format == format ? Color.snapAccent : Color.clear, lineWidth: 2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        if settings.format.usesQuality {
            HStack(spacing: 14) {
                Text("Quality").font(.system(size: 14, weight: .medium))
                Slider(value: $settings.quality, in: 0.3...1)
                Text("\(Int(settings.quality * 100))%").font(.system(size: 13)).foregroundStyle(Color.snapMuted).frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .snapCard()
        }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export folder").font(.system(size: 14, weight: .medium))
                Text(settings.exportDirectory.lastPathComponent).font(.system(size: 13)).foregroundStyle(Color.snapMuted)
            }
            Spacer()
            Button("Choose…", action: chooseFolder).buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
        .snapCard()
    }

    private func description(_ format: ImageFormat) -> String {
        switch format {
        case .png: return "Sharpest quality, keeps transparency"
        case .jpeg: return "Small files for sharing"
        case .heic: return "Modern and very compact"
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
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyCenter.shared

    private var hasProblems: Bool {
        !hotKeys.failed.isEmpty || ShortcutAction.allCases.contains { settings.conflictMessage(for: $0) != nil }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                ShortcutCard(action: action)
            }
        }

        HStack(spacing: 12) {
            Circle().fill(hasProblems ? Color.snapAccent : Color.snapTeal).frame(width: 10, height: 10)
            Text(hasProblems ? "Some shortcuts clash. Look for the orange notes above." : "No conflicts with macOS or other apps.")
                .font(.system(size: 14))
            Spacer()
            Button("Restore Defaults") {
                settings.shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .snapCard()

        Text("Press Delete while recording to clear a shortcut, or Esc to cancel.")
            .font(.system(size: 13))
            .foregroundStyle(Color.snapMuted)
    }
}

private struct ShortcutCard: View {
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
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.symbol).font(.system(size: 20)).foregroundStyle(Color(hex: 0xFF8A63)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 14, weight: .medium))
                    if let warning {
                        Text(warning).font(.system(size: 12)).foregroundStyle(Color.snapAccent)
                    }
                }
                Spacer()
                if recording {
                    Text("Press keys…").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.snapAccent)
                } else if let shortcut = settings.shortcuts[action] {
                    KeyCaps(parts: shortcut.keyParts)
                } else {
                    Text("Not set").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 76)
            .snapCard(radius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(recording ? Color.snapAccent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct UpdatesPane: View {
    @ObservedObject private var updates = UpdateController.shared

    private var lastChecked: String {
        updates.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    private var status: String {
        if let version = updates.availableVersion { return "\(version) available" }
        if updates.phase == .checking { return "Checking…" }
        return updates.phase == .upToDate ? "Up to date" : "Installed"
    }

    var body: some View {
        SettingsGroup(title: "Current version") {
            SettingRow(title: "Snapframe \(UpdateService.currentVersion.description)", detail: status) {
                Button("Check Now") { updates.checkForUpdates() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!updates.isConfigured)
            }
            SettingRow(title: "Last checked", detail: "From GitHub Releases") {
                Text(lastChecked).font(.system(size: 13)).foregroundStyle(Color(hex: 0xC4C6CC))
            }
        }
        SettingsGroup(title: "Automatic updates") {
            ToggleRow(title: "Check when Snapframe starts", detail: "You choose when to install", isOn: $updates.automaticallyChecks)
        }
        if !updates.isConfigured {
            Text("Updates are not set up in this build.").font(.system(size: 13)).foregroundStyle(Color.snapMuted)
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        HStack(spacing: 16) {
            BrandMark(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Snapframe").font(.snapDisplay(24))
                Text("A free screenshot app for your Mac").font(.system(size: 14)).foregroundStyle(Color.snapMuted)
            }
            Spacer()
        }
        .padding(18)
        .snapCard()

        SettingsGroup(title: "Details") {
            info("Version", "Installed release", UpdateService.currentVersion.description)
            info("Price", "Every feature included", "Free")
            info("Minimum macOS", "Apple silicon and Intel", "14.0")
            info("Network use", "Nothing else goes online", "Update checks only")
        }
    }

    private func info(_ title: String, _ detail: String, _ value: String) -> some View {
        SettingRow(title: title, detail: detail) {
            Text(value).font(.system(size: 13)).foregroundStyle(Color(hex: 0xC4C6CC))
        }
    }
}
