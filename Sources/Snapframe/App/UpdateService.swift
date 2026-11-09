import AppKit
import Security
import SnapframeCore

enum UpdateError: LocalizedError {
    case server(Int)
    case incompleteDownload
    case commandFailed(String)
    case appNotFoundInDiskImage
    case wrongApplication
    case notNewer
    case signatureMismatch
    case locationNotWritable

    var errorDescription: String? {
        switch self {
        case .server(let code): return "GitHub returned error \(code)."
        case .incompleteDownload: return "The download was incomplete."
        case .commandFailed(let name): return "\(name) could not open the update."
        case .appNotFoundInDiskImage: return "The DMG does not contain Snapframe.app."
        case .wrongApplication: return "This DMG contains a different app."
        case .notNewer: return "The DMG is not newer than this version."
        case .signatureMismatch: return "This update was not signed by the same developer, so it was not installed."
        case .locationNotWritable: return "Snapframe can't replace itself here. Move it to Applications and try again."
        }
    }
}

/// The steps of an update, with no UI so they can be exercised end to end.
enum UpdateService {
    static var currentVersion: AppVersion {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AppVersion(text ?? "") ?? AppVersion("0")!
    }

    /// Returns nil when the repository has no published release yet.
    static func fetchLatest(from url: URL, requiredPrefix: String?) async throws -> AvailableRelease? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Snapframe-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { throw UpdateError.server(http.statusCode) }
        }
        return try ReleaseFeed.parse(data, requiredPrefix: requiredPrefix)
    }

    static func download(_ release: AvailableRelease) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.server(http.statusCode)
        }

        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("SnapframeUpdate-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("update.dmg")
        try manager.moveItem(at: temporary, to: destination)

        let size = (try manager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
        guard size == release.size else { throw UpdateError.incompleteDownload }
        return destination
    }

    /// Swaps the new app into the running app's exact location.
    ///
    /// macOS identifies an app by bundle ID, signature and location. Keeping all three means
    /// no duplicate app appears, and settings, Screen Recording access and login items carry over.
    static func install(diskImage: URL, release: AvailableRelease) throws {
        let manager = FileManager.default
        let target = Bundle.main.bundleURL
        guard manager.isWritableFile(atPath: target.deletingLastPathComponent().path),
              !target.path.contains("/AppTranslocation/")
        else { throw UpdateError.locationNotWritable }

        let mountPoint = manager.temporaryDirectory.appendingPathComponent("SnapframeMount-\(UUID().uuidString)")
        try manager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? manager.removeItem(at: mountPoint)
        }

        let candidate = mountPoint.appendingPathComponent(target.lastPathComponent)
        guard manager.fileExists(atPath: candidate.path) else { throw UpdateError.appNotFoundInDiskImage }
        try verify(candidate, release: release)

        let staging = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
        )
        defer { try? manager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try run("/usr/bin/ditto", [candidate.path, staged.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        // Checked again because this is the copy that actually gets installed.
        try verify(staged, release: release)

        _ = try manager.replaceItemAt(target, withItemAt: staged)
    }

    private static func verify(_ candidate: URL, release: AvailableRelease) throws {
        guard let plist = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { throw UpdateError.wrongApplication }

        guard let text = plist["CFBundleShortVersionString"] as? String,
              let version = AppVersion(text), version > currentVersion, version == release.version
        else { throw UpdateError.notNewer }

        try checkSignatureMatchesThisApp(candidate)
    }

    /// The candidate must satisfy this running app's own signing requirement.
    /// Only the holder of the same certificate can produce an update that passes.
    private static func checkSignatureMatchesThisApp(_ candidate: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidateCode: SecStaticCode?

        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess, let candidateCode
        else { throw UpdateError.signatureMismatch }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.signatureMismatch
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)
        }
    }
}

enum AppRelauncher {
    /// Waits for this process to exit first, so the new one can claim the global shortcuts.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}
