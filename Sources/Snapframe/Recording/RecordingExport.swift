import AVFoundation
import ImageIO
import SnapframeCore
import UniformTypeIdentifiers

enum RecordingExport {
    private static var recordingsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapframe/Recordings", isDirectory: true)
    }

    static func makeWorkspace(isGIF: Bool) throws -> URL {
        let manifest = RecordingManifest(startedAt: Date(), isGIF: isGIF)
        let folder = recordingsFolder.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    static func movieURL(in workspace: URL) -> URL { workspace.appendingPathComponent("recording.mov") }

    /// Recordings left behind by a crash or forced quit. Unusable ones are removed.
    static func recoverableMovies() async -> [URL] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        var found: [URL] = []
        for folder in folders {
            let movie = movieURL(in: folder)
            let asset = AVURLAsset(url: movie)
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if manager.fileExists(atPath: movie.path), duration >= 1, !tracks.isEmpty {
                found.append(movie)
            } else {
                try? manager.removeItem(at: folder)
            }
        }
        return found
    }

    static func removeWorkspace(of movie: URL) {
        try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
    }

    static func hasEnoughSpace(minimumBytes: Int64) -> Bool {
        let values = try? recordingsFolder.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= minimumBytes
    }

    private static func export(_ asset: AVAsset, to destination: URL, range: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.writerFailed("The movie could not be exported.")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        if let range { session.timeRange = range }
        await session.export()
        if session.status != .completed {
            throw RecordingError.writerFailed(session.error?.localizedDescription ?? "The movie could not be exported.")
        }
    }

    /// Copies the tracks into an MP4 without re-encoding, so both audio tracks are kept.
    static func makeMP4(from movie: URL, to destination: URL) async throws {
        try await export(AVURLAsset(url: movie), to: destination)
    }

    static func makeGIF(from movie: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let times = RecordingFormat.gifFrameTimes(duration: duration, framesPerSecond: 15, maximumFrames: 450)
        guard !times.isEmpty, let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.gif.identifier as CFString, times.count, nil
        ) else { throw RecordingError.nothingRecorded }

        CGImageDestinationSetProperties(output, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let delay = duration / Double(times.count)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for time in times {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            CGImageDestinationAddImage(output, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(output) else { throw RecordingError.writerFailed("The GIF could not be written.") }
    }

    static func poster(of movie: URL) async -> CGImage? {
        let asset = AVURLAsset(url: movie)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    }

    /// Replaces a movie with the trimmed range. Keyframes are kept, so the cut can be slightly early.
    static func trim(_ file: URL, range: CMTimeRange) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Snapframe trim \(UUID().uuidString).mp4")
        try await export(AVURLAsset(url: file), to: temporary, range: range)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }
}
