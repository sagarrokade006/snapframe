import CoreGraphics
import Foundation

/// Removes paused time from a recording. All times are seconds on one shared clock.
public struct PauseClock: Equatable, Sendable {
    public private(set) var start: Double?
    public private(set) var pausedTotal: Double = 0
    public private(set) var pausedAt: Double?

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    public mutating func begin(at time: Double) {
        if start == nil { start = time }
    }

    public mutating func pause(at time: Double) {
        guard start != nil, pausedAt == nil else { return }
        pausedAt = time
    }

    public mutating func resume(at time: Double) {
        guard let pausedAt else { return }
        pausedTotal += max(time - pausedAt, 0)
        self.pausedAt = nil
    }

    /// The position of a sample in the finished movie. Nil means the sample should be dropped.
    public func position(of time: Double) -> Double? {
        guard let start, time >= start, pausedAt == nil else { return nil }
        return time - start - pausedTotal
    }

    public func elapsed(at time: Double) -> Double {
        guard let start else { return 0 }
        return max((pausedAt ?? time) - start - pausedTotal, 0)
    }
}

public enum RecordingFormat {
    /// `1:05`, or `1:02:05` past an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }

    /// Scales pixel dimensions to fit a height limit. Video encoders need even numbers. Zero means no limit.
    public static func outputSize(width: Int, height: Int, maximumHeight: Int) -> (width: Int, height: Int) {
        var scaledWidth = Double(width), scaledHeight = Double(height)
        if maximumHeight > 0, height > maximumHeight {
            let ratio = Double(maximumHeight) / Double(height)
            scaledWidth *= ratio
            scaledHeight *= ratio
        }
        return (max(Int(scaledWidth) & ~1, 2), max(Int(scaledHeight) & ~1, 2))
    }

    /// Times for each GIF frame. Long clips use fewer frames per second, so files stay a usable size.
    public static func gifFrameTimes(duration: Double, framesPerSecond: Double, maximumFrames: Int) -> [Double] {
        guard duration > 0, framesPerSecond > 0, maximumFrames > 0 else { return [] }
        let count = min(max(Int((duration * framesPerSecond).rounded()), 1), maximumFrames)
        let step = duration / Double(count)
        return (0..<count).map { Double($0) * step }
    }
}

/// Written beside an in-progress recording, so a later launch can find and rescue it.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var isGIF: Bool

    public init(id: UUID = UUID(), startedAt: Date, isGIF: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.isGIF = isGIF
    }
}

extension CaptureItem {
    public static let recordingKind = "Recording"
    public static let gifKind = "GIF"

    public static let studioKind = "Studio"

    public var isStudio: Bool { kind == Self.studioKind }
    public var isVideo: Bool { kind == Self.recordingKind || kind == Self.gifKind }
    public var canTrim: Bool { kind == Self.recordingKind }
}
