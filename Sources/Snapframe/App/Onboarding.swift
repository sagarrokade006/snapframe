import AppKit
import Combine
import SwiftUI

@MainActor
enum PermissionManager {
    static var isScreenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS often applies a new Screen Recording grant only after the app restarts.
    static func relaunch() {
        AppRelauncher.relaunch()
    }
}

struct OnboardingView: View {
    @State private var granted = PermissionManager.isScreenRecordingGranted
    @State private var requested = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40))
                .foregroundStyle(Color.snapAccent)

            Text("Snapframe needs Screen Recording")
                .font(.title2.weight(.semibold))

            Text("macOS requires this permission for any app that captures the screen. Your captures stay on this Mac. Snapframe only goes online to check for app updates.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? Color.snapAccent : .secondary)
                Text(granted ? "Permission granted" : "Permission not granted yet")
            }

            Spacer(minLength: 0)

            HStack {
                if granted {
                    Button("Later", action: close)
                    Spacer()
                    Button("Restart Snapframe") { PermissionManager.relaunch() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: close)
                    Spacer()
                    if requested {
                        Button("Open System Settings") { PermissionManager.openSystemSettings() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Grant Access") {
                            requested = true
                            PermissionManager.request()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 440, height: 300)
        .background(Color.snapPanel)
        .preferredColorScheme(.dark)
        .tint(Color.snapAccent)
        .onReceive(poll) { _ in granted = PermissionManager.isScreenRecordingGranted }
    }
}

extension Color {
    static let snapAccent = Color(red: 1, green: 0.42, blue: 0.24)
    static let snapPanel = Color(nsColor: Palette.panel)
}
