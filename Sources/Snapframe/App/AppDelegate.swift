import AppKit
import Combine
import CoreServices
import SnapframeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = CaptureCoordinator()
    private let settings = AppSettings.shared
    private var statusMenu: StatusMenuController?
    private var homeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var updateWindow: NSWindow?
    private var shortcutObserver: AnyCancellable?
    private var launchHint: PillPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)

        let menu = StatusMenuController()
        menu.onCapture = { [weak self] in self?.capture($0) }
        menu.onOpenHome = { [weak self] in self?.showHome() }
        menu.onOpenSettings = { [weak self] in self?.showSettings() }
        statusMenu = menu

        coordinator.onPermissionNeeded = { [weak self] in
            self?.settings.onboardingStep = 1
            self?.showOnboarding()
        }

        UpdateController.shared.onShowWindow = { [weak self] in self?.showUpdates() }
        UpdateController.shared.start()

        let hotKeys = HotKeyCenter.shared
        hotKeys.onAction = { [weak self] in self?.capture($0) }
        hotKeys.register(settings.shortcuts)
        shortcutObserver = settings.$shortcuts.dropFirst().sink { hotKeys.register($0) }

        if !settings.onboardingCompleted || !PermissionManager.isScreenRecordingGranted {
            showOnboarding()
        } else if settings.openHomeAtLaunch && !launchedAtLogin {
            showHome()
        } else {
            showRunningHint()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == AutomationCommand.scheme {
                perform(url)
            } else {
                AnnotateController.shared.open(fileURL: url)
            }
        }
    }

    /// Another app can open these links at any time, so nothing runs without the user's consent.
    private func perform(_ url: URL) {
        guard let command = AutomationCommand.parse(url), isAllowed(url) else { return }
        switch command {
        case .capture(let action): capture(action)
        case .captureRegion(let rect, let display): coordinator.captureRegion(rect, displayIndex: display)
        case .openHome: showHome()
        case .openSettings: showSettings()
        case .icons(let change):
            let cover = DesktopIconCover.shared
            Task {
                switch change {
                case .hide: await cover.show()
                case .show: cover.hide()
                case .toggle: await cover.toggle()
                }
            }
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        switch settings.automationPolicy {
        case .never: return false
        case .always: return true
        case .ask: break
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "An app wants to control Snapframe"
        alert.informativeText = "Requested action: \(url.host ?? "unknown")"
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Don't Allow")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn:
            settings.automationPolicy = .always
            return true
        default: return false
        }
    }

    /// A menu-bar app has no Dock window, so opening it again brings up Home.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings.onboardingCompleted && PermissionManager.isScreenRecordingGranted {
            showHome()
        } else {
            showOnboarding()
        }
        return false
    }

    /// Windows belonging to Snapframe are excluded from captures, but Home would still hide what's beneath it.
    private func capture(_ action: ShortcutAction) {
        if action != .toggleDesktopIcons { homeWindow?.orderOut(nil) }
        coordinator.begin(action)
    }

    private func showRunningHint() {
        let shortcut = settings.shortcuts[.area]?.displayString
        let message = "Snapframe is in the menu bar" + (shortcut.map { "  ·  Press \($0) to capture" } ?? "")
        let hint = PillPanel(message: message, fontSize: 13)
        hint.onClick = { [weak self, weak hint] in
            hint?.close()
            self?.showHome()
        }
        hint.showBottomLeft()
        launchHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                self?.launchHint?.close()
                self?.launchHint = nil
            }
        }
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(title: String, size: CGSize, resizable: Bool = false, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0.063, green: 0.067, blue: 0.075, alpha: 1)

        let host = NSHostingView(rootView: content)
        host.sizingOptions = resizable ? [.minSize] : []
        window.contentView = host
        window.setContentSize(size)
        window.center()
        return window
    }

    private func showHome() {
        if homeWindow == nil {
            let view = HomeView(
                onCapture: { [weak self] in self?.capture($0) },
                onSettings: { [weak self] in self?.showSettings() }
            )
            homeWindow = makeWindow(title: "Snapframe", size: CGSize(width: 1280, height: 800), resizable: true, content: view)
        }
        if let homeWindow { present(homeWindow) }
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Snapframe Settings", size: CGSize(width: 1060, height: 700), content: SettingsView())
        }
        if let settingsWindow { present(settingsWindow) }
    }

    private func showUpdates() {
        if updateWindow == nil {
            let view = UpdateView { [weak self] in self?.updateWindow?.close() }
            updateWindow = makeWindow(title: "Software Update", size: CGSize(width: 720, height: 620), content: view)
        }
        if let updateWindow { present(updateWindow) }
    }

    private func showOnboarding() {
        onboardingWindow?.close()
        let view = OnboardingView(
            finish: { [weak self] in
                self?.onboardingWindow?.close()
                self?.showHome()
            },
            later: { [weak self] in self?.onboardingWindow?.close() }
        )
        onboardingWindow = makeWindow(title: "Welcome to Snapframe", size: CGSize(width: 920, height: 580), content: view)
        if let onboardingWindow { present(onboardingWindow) }
    }
}
