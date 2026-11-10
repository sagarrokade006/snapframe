import AppKit
import SnapframeCore
import SwiftUI

struct UpdateView: View {
    @ObservedObject private var updates = UpdateController.shared
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                switch updates.phase {
                case .available: changelog
                case .downloading, .installing: progress
                default: statusCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .snapCard()

            HStack(spacing: 11) {
                Image(systemName: "checkmark.shield").font(.system(size: 17)).foregroundStyle(Color.snapTeal)
                Text("Your settings, shortcuts, library and permissions stay as they are.").font(.system(size: 14))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .snapCard(radius: 11)

            HStack(spacing: 10) {
                Spacer()
                if !isInstalling {
                    Button(updates.phase == .available ? "Later" : "Close", action: close).buttonStyle(QuietButtonStyle())
                }
                if updates.phase == .available {
                    Button("Install and Relaunch") { updates.install() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 720, height: 620)
        .background(Color.snapSidebar)
        .snapWindowStyle()
    }

    private var isInstalling: Bool {
        updates.phase == .downloading || updates.phase == .installing
    }

    private var headline: String {
        switch updates.phase {
        case .available: return "A new version is ready"
        case .upToDate: return "Snapframe is up to date"
        case .downloading, .installing: return "Updating Snapframe"
        case .failed: return "Update failed"
        case .idle, .checking: return "Checking for updates"
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 68, height: 68).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(headline).font(.snapDisplay(26))
                HStack(spacing: 8) {
                    versionChip(UpdateService.currentVersion.description, highlighted: false)
                    if let version = updates.availableVersion, let release = updates.release {
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.snapMuted)
                        versionChip(version, highlighted: true)
                        Text(CaptureFormatting.bytes(release.size)).font(.system(size: 14)).foregroundStyle(Color.snapMuted)
                    }
                }
            }
            Spacer()
        }
    }

    private func versionChip(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? Color.snapInk : Color.snapText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(highlighted ? Color.snapAccent : Color.snapRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var changelog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changelog").font(.system(size: 15, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Changelog.parse(updates.release?.notes ?? "").enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.kind.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.snapInk)
                                .frame(width: 58)
                                .padding(.vertical, 2)
                                .background(color(entry.kind), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(entry.text).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    private func color(_ kind: ChangelogEntry.Kind) -> Color {
        switch kind {
        case .new: return .snapTeal
        case .better: return Color(hex: 0x8FB7D9)
        case .fixed: return Color(hex: 0xF2C14E)
        case .note: return Color(hex: 0xD9D7D0)
        }
    }

    private var progress: some View {
        let current = updates.phase == .downloading ? 0 : 1
        let stages = ["Downloading from GitHub", "Checking the signature and replacing the app", "Relaunching Snapframe"]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(index < current ? Color.snapTeal : (index == current ? Color.snapAccent : Color(hex: 0x33353B)))
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.snapInk)
                        } else if index == current {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 26, height: 26)
                    Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(index <= current ? Color.snapText : Color.snapMuted)
                }
                .frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(22)
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            switch updates.phase {
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(Color.snapAccent)
                Text(message).font(.system(size: 14)).multilineTextAlignment(.center)
            case .upToDate:
                Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(Color.snapTeal)
                Text("You have the latest version.").font(.system(size: 14))
            default:
                ProgressView()
                Text("Looking at the latest release on GitHub.").font(.system(size: 14)).foregroundStyle(Color.snapMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(22)
    }
}
