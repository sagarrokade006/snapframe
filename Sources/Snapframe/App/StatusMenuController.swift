import AppKit
import Combine
import SnapframeCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private var updateObserver: AnyCancellable?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let settings = AppSettings.shared

    var onCapture: ((ShortcutAction) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    override init() {
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Snapframe")
            image?.isTemplate = true
            button.image = image
        }
        menu.delegate = self
        statusItem.menu = menu

        updateObserver = UpdateController.shared.$availableVersion.sink { [weak self] version in
            self?.statusItem.button?.contentTintColor = version == nil ? nil : Palette.accent
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = UpdateController.shared.availableVersion {
            menu.addItem(item("Update to Snapframe \(version)…", #selector(checkForUpdates)))
            menu.addItem(.separator())
        }

        if !PermissionManager.isScreenRecordingGranted {
            menu.addItem(item("Grant Screen Recording…", #selector(showPermissions)))
            menu.addItem(.separator())
        }

        for action in ShortcutAction.allCases {
            let entry = item(action.title, #selector(captureClicked(_:)))
            entry.representedObject = action.rawValue
            if let shortcut = settings.shortcuts[action], let key = shortcut.menuKeyEquivalent {
                entry.keyEquivalent = key
                entry.keyEquivalentModifierMask = modifierFlags(shortcut.modifiers)
            }
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(item("Open Export Folder", #selector(openExportFolder)))
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        if UpdateController.shared.isConfigured {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snapframe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func modifierFlags(_ modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @objc private func captureClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        onCapture?(action)
    }

    @objc private func openExportFolder() {
        NSWorkspace.shared.open(settings.exportDirectory)
    }

    @objc private func checkForUpdates() { UpdateController.shared.checkForUpdates() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func showPermissions() { onShowPermissions?() }
}
