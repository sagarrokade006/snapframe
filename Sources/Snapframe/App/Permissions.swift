import AppKit

@MainActor
enum PermissionManager {
    static var isScreenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
