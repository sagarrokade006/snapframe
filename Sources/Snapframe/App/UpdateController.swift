import AppKit
import Combine
import SnapframeCore
import SwiftUI

enum UpdatePhase: Equatable {
    case idle, checking, upToDate, available, downloading, installing
    case failed(String)
}

/// Checks GitHub Releases for a newer DMG. This is the app's only network use.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var phase = UpdatePhase.idle
    @Published private(set) var availableVersion: String?
    @Published private(set) var release: AvailableRelease?
    @Published private(set) var lastCheckDate: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: "autoCheckUpdates") }
    }

    var onShowWindow: (() -> Void)?

    /// Empty in builds made without Packaging/update-repo.txt.
    private let repository: String
    private let defaults = UserDefaults.standard
    private var schedule: Timer?
    private var reminder: PillPanel?
    private var remindedVersion: AppVersion?

    private static let checkInterval: TimeInterval = 24 * 60 * 60

    var isConfigured: Bool { !repository.isEmpty }

    private init() {
        repository = Bundle.main.object(forInfoDictionaryKey: "SnapframeUpdateRepository") as? String ?? ""
        defaults.register(defaults: ["autoCheckUpdates": true])
        automaticallyChecks = defaults.bool(forKey: "autoCheckUpdates")
        lastCheckDate = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    func start() {
        guard isConfigured, schedule == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        schedule = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automaticallyChecks else { return }
        if let lastCheckDate, Date().timeIntervalSince(lastCheckDate) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// Opens the update window and looks for a release, unless one is already known.
    func checkForUpdates() {
        guard isConfigured else { return }
        dismissReminder()
        onShowWindow?()
        guard release == nil else { return }
        Task { await check(userInitiated: true) }
    }

    private var isBusy: Bool {
        phase == .checking || phase == .downloading || phase == .installing
    }

    private func check(userInitiated: Bool) async {
        guard isConfigured, !isBusy else { return }
        phase = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            let latest = try await UpdateService.fetchLatest(
                from: url,
                requiredPrefix: ReleaseFeed.downloadPrefix(repository: repository)
            )
            let now = Date()
            lastCheckDate = now
            defaults.set(now, forKey: "lastUpdateCheck")

            if let latest, latest.version > UpdateService.currentVersion {
                release = latest
                availableVersion = latest.version.description
                phase = .available
                if !userInitiated, remindedVersion != latest.version {
                    remindedVersion = latest.version
                    showReminder(version: latest.version.description)
                }
            } else {
                release = nil
                availableVersion = nil
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func install() {
        guard let release, !isBusy else { return }
        phase = .downloading
        Task {
            do {
                let diskImage = try await UpdateService.download(release)
                phase = .installing
                try await Task.detached(priority: .userInitiated) {
                    try UpdateService.install(diskImage: diskImage, release: release)
                    try? FileManager.default.removeItem(at: diskImage.deletingLastPathComponent())
                }.value
                AppRelauncher.relaunch()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func showReminder(version: String) {
        dismissReminder()
        let pill = PillPanel(message: "Snapframe \(version) is available  ·  Click to update", fontSize: 13)
        pill.onClick = { [weak self] in self?.checkForUpdates() }
        pill.showBottomLeft()
        reminder = pill

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak pill] in
            MainActor.assumeIsolated {
                guard let pill, self?.reminder === pill else { return }
                self?.dismissReminder()
            }
        }
    }

    private func dismissReminder() {
        reminder?.close()
        reminder = nil
    }
}

struct UpdateView: View {
    @ObservedObject private var updates = UpdateController.shared
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if updates.phase == .available, let notes = updates.release?.notes, !notes.isEmpty {
                ScrollView {
                    Text(Self.formatted(notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(10)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)

            if isWorking {
                ProgressView().progressViewStyle(.linear)
            }

            HStack {
                Spacer()
                Button(updates.phase == .available ? "Later" : "Close", action: close)
                    .disabled(isWorking && updates.phase != .checking)
                if updates.phase == .available {
                    Button("Install and Relaunch") { updates.install() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 320)
        .background(Color.snapPanel)
        .preferredColorScheme(.dark)
        .tint(Color.snapAccent)
    }

    /// GitHub release notes are Markdown. Headings and bullets become simple rich text.
    private static func formatted(_ notes: String) -> AttributedString {
        let text = notes
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: #"^#{1,6}\s+(.*)$"#, with: "**$1**", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "•  ", options: .regularExpression)
            }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(notes)
    }

    private var isWorking: Bool {
        [.checking, .downloading, .installing].contains(updates.phase)
    }

    private var title: String {
        switch updates.phase {
        case .available: return "Snapframe \(updates.availableVersion ?? "") is available"
        case .upToDate: return "Snapframe is up to date"
        case .downloading: return "Downloading update"
        case .installing: return "Installing update"
        case .failed: return "Update failed"
        case .idle, .checking: return "Checking for updates"
        }
    }

    private var detail: String {
        switch updates.phase {
        case .available: return "You have \(UpdateService.currentVersion). Your settings, shortcuts and permissions stay as they are."
        case .upToDate: return "You have the latest version, \(UpdateService.currentVersion)."
        case .downloading: return "Snapframe will restart when it's ready."
        case .installing: return "Checking the signature and replacing the app."
        case .failed(let message): return message
        case .idle, .checking: return "Looking at the latest release on GitHub."
        }
    }
}
