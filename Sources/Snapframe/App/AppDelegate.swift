import AppKit
import Combine
import SnapframeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = CaptureCoordinator()
    private let settings = AppSettings.shared
    private var statusMenu: StatusMenuController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var shortcutObserver: AnyCancellable?
    private var updateWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = StatusMenuController()
        menu.onCapture = { [weak self] in self?.coordinator.begin($0) }
        menu.onOpenSettings = { [weak self] in self?.showSettings() }
        menu.onShowPermissions = { [weak self] in self?.showOnboarding() }
        statusMenu = menu

        coordinator.onPermissionNeeded = { [weak self] in self?.showOnboarding() }

        UpdateController.shared.onShowWindow = { [weak self] in self?.showUpdates() }
        UpdateController.shared.start()

        let hotKeys = HotKeyCenter.shared
        hotKeys.onAction = { [weak self] in self?.coordinator.begin($0) }
        hotKeys.register(settings.shortcuts)
        shortcutObserver = settings.$shortcuts.dropFirst().sink { hotKeys.register($0) }

        if !PermissionManager.isScreenRecordingGranted {
            showOnboarding()
        }
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        return window
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Snapframe Settings", content: NSHostingView(rootView: SettingsView()))
        }
        if let settingsWindow { present(settingsWindow) }
    }

    private func showUpdates() {
        if updateWindow == nil {
            let view = UpdateView { [weak self] in self?.updateWindow?.close() }
            updateWindow = makeWindow(title: "Software Update", content: NSHostingView(rootView: view))
        }
        if let updateWindow { present(updateWindow) }
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in self?.onboardingWindow?.close() }
            onboardingWindow = makeWindow(title: "Welcome to Snapframe", content: NSHostingView(rootView: view))
        }
        if let onboardingWindow { present(onboardingWindow) }
    }
}
