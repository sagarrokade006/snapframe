import CoreGraphics
import Foundation

public enum RecordMode: String, Codable, CaseIterable, Sendable {
    case video, gif, studio

    public var title: String {
        switch self {
        case .video: return "Video"
        case .gif: return "GIF"
        case .studio: return "Studio"
        }
    }
}

/// Positions are 0 to 1 across the recorded area, with y pointing down. Times are seconds into the recording.
public struct MouseSample: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct ClickEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct KeyEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var parts: [String]

    public init(t: Double, parts: [String]) {
        self.t = t
        self.parts = parts
    }
}

public struct WindowSample: Codable, Equatable, Sendable {
    public var t: Double
    public var rect: CGRect

    public init(t: Double, rect: CGRect) {
        self.t = t
        self.rect = rect
    }
}

public struct StudioClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// Times are in the original recording, so zooms keep their place when clips are cut.
public struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var level: Double
    /// Nil follows the cursor. Otherwise the fixed point to zoom into.
    public var centerX: Double?
    public var centerY: Double?

    public init(id: UUID = UUID(), start: Double, end: Double, level: Double, centerX: Double? = nil, centerY: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.level = level
        self.centerX = centerX
        self.centerY = centerY
    }

    public var followsCursor: Bool { centerX == nil || centerY == nil }
}

public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    case pointer, dot, ring

    public var title: String { rawValue.capitalized }
}

public enum CameraCorner: String, Codable, CaseIterable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft

    public var title: String {
        switch self {
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }
}

public struct StudioAppearance: Codable, Equatable, Sendable {
    public var canvas = CanvasStyle(fill: .gradient(0x2A2C30, 0x5C8B94), padding: 64, cornerRadius: 14, shadow: 0.55)
    public var showCursor = true
    public var cursorStyle = CursorStyle.pointer
    public var cursorScale = 1.0
    public var smoothCursor = true
    public var hideCursorWhenIdle = true
    public var showClicks = true
    public var showKeys = true
    public var showCamera = true
    public var cameraCorner = CameraCorner.bottomRight
    public var cameraSize = 0.2
    public var flipCamera = true
    public var shrinkCameraDuringZoom = true
    public var microphoneVolume = 1.0
    public var systemVolume = 1.0

    public init() {}
}

/// Everything about a Studio recording except the media files beside it.
public struct StudioProject: Codable, Equatable, Sendable {
    public static let packageExtension = "snapframevideo"
    public static let projectFile = "project.json"
    public static let screenFile = "screen.mov"
    public static let cameraFile = "camera.mov"

    public var name: String
    public var isComplete = false
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var hasCamera = false
    public var hasSystemAudio = false
    public var hasMicrophone = false
    public var cameraOffset = 0.0

    public var mouse: [MouseSample] = []
    public var clicks: [ClickEvent] = []
    public var keys: [KeyEvent] = []
    public var windows: [WindowSample] = []

    public var clips: [StudioClip]
    public var zooms: [ZoomSegment] = []
    public var appearance = StudioAppearance()

    public init(name: String, duration: Double, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.name = name
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        clips = [StudioClip(start: 0, end: duration)]
    }

    public static let minimumClip = 0.2

    public var editedDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// The original-recording time shown at a point on the timeline.
    public func sourceTime(at timeline: Double) -> Double {
        var remaining = max(timeline, 0)
        for clip in clips {
            if remaining < clip.duration { return clip.start + remaining }
            remaining -= clip.duration
        }
        return clips.last?.end ?? 0
    }

    /// Where an original-recording time falls on the timeline, or nil if that moment was cut.
    public func timelineTime(forSource source: Double) -> Double? {
        var elapsed = 0.0
        for clip in clips {
            if source >= clip.start, source <= clip.end { return elapsed + source - clip.start }
            elapsed += clip.duration
        }
        return nil
    }

    /// Returns false when the point is too close to a clip edge.
    @discardableResult
    public mutating func split(atTimeline timeline: Double) -> Bool {
        var remaining = timeline
        for (index, clip) in clips.enumerated() {
            if remaining < clip.duration {
                guard remaining >= Self.minimumClip, clip.duration - remaining >= Self.minimumClip else { return false }
                let cut = clip.start + remaining
                clips[index].end = cut
                clips.insert(StudioClip(start: cut, end: clip.end), at: index + 1)
                return true
            }
            remaining -= clip.duration
        }
        return false
    }

    /// The last remaining clip can't be deleted.
    @discardableResult
    public mutating func deleteClip(id: UUID) -> Bool {
        guard clips.count > 1, let index = clips.firstIndex(where: { $0.id == id }) else { return false }
        clips.remove(at: index)
        return true
    }

    public mutating func trimClip(id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? clips[index - 1].end : 0
        let upper = index < clips.count - 1 ? clips[index + 1].start : duration
        if let start {
            clips[index].start = min(max(start, lower), clips[index].end - Self.minimumClip)
        }
        if let end {
            clips[index].end = max(min(end, upper), clips[index].start + Self.minimumClip)
        }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> StudioProject { try JSONDecoder().decode(StudioProject.self, from: data) }
}

public struct SmartZoomOptions: Sendable {
    public var leadIn = 0.5
    public var trailAfter = 1.6
    public var minimumDuration = 1.0
    public var maximumDuration = 8.0
    public var minimumScore = 1.0
    public var minimumSeparation = 1.2
    public var neighborTime = 1.5
    public var neighborDistance = 0.12
    public var dwellDuration = 1.0
    public var dwellRadius = 0.015
    public var mergeGap = 0.8
    public var normalLevel = 1.5
    public var strongLevel = 1.9

    public init() {}
}

/// Decides where zooms belong from what the cursor did.
public enum SmartZoom {
    private struct Moment {
        let t: Double
        let x: Double
        let y: Double
        var score: Double
    }

    public static func analyze(clicks: [ClickEvent], mouse: [MouseSample], duration: Double, options: SmartZoomOptions = SmartZoomOptions()) -> [ZoomSegment] {
        guard duration > 0 else { return [] }

        var moments = clicks.map { Moment(t: $0.t, x: $0.x, y: $0.y, score: 1) }
        moments += dwells(in: mouse, options: options)

        let base = moments
        for index in moments.indices {
            for other in base where other.t != moments[index].t {
                if abs(other.t - moments[index].t) <= options.neighborTime,
                   hypot(other.x - moments[index].x, other.y - moments[index].y) <= options.neighborDistance {
                    moments[index].score += 0.5
                }
            }
        }

        var peaks: [Moment] = []
        for moment in moments.sorted(by: { $0.score > $1.score }) where moment.score >= options.minimumScore {
            if peaks.allSatisfy({ abs($0.t - moment.t) >= options.minimumSeparation }) { peaks.append(moment) }
        }

        var zooms: [ZoomSegment] = []
        for peak in peaks.sorted(by: { $0.t < $1.t }) {
            let start = max(peak.t - options.leadIn, 0)
            let end = min(max(peak.t + options.trailAfter, start + options.minimumDuration), duration)
            let level = peak.score >= 2 ? options.strongLevel : options.normalLevel

            if let last = zooms.last, start - last.end <= options.mergeGap,
               end - last.start <= options.maximumDuration {
                zooms[zooms.count - 1].end = end
                zooms[zooms.count - 1].level = max(last.level, level)
                continue
            }
            guard end > start else { continue }
            zooms.append(ZoomSegment(start: start, end: min(end, start + options.maximumDuration), level: level, centerX: peak.x, centerY: peak.y))
        }
        return zooms
    }

    /// Moments where the cursor rested after moving.
    private static func dwells(in mouse: [MouseSample], options: SmartZoomOptions) -> [Moment] {
        guard mouse.count > 1 else { return [] }
        var result: [Moment] = []
        var anchor = 0
        var hadMovement = false
        for index in 1..<mouse.count {
            if hypot(mouse[index].x - mouse[anchor].x, mouse[index].y - mouse[anchor].y) > options.dwellRadius {
                if hadMovement, mouse[index - 1].t - mouse[anchor].t >= options.dwellDuration {
                    result.append(Moment(t: mouse[anchor].t, x: mouse[anchor].x, y: mouse[anchor].y, score: 0.5))
                }
                anchor = index
                hadMovement = true
            }
        }
        return result
    }
}

/// Answers where things are at a moment in the recording. Used for every rendered frame.
public enum StudioMotion {
    public static func interpolated(_ samples: [MouseSample], at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }

        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].t <= t { low = middle } else { high = middle }
        }
        let a = samples[low], b = samples[high]
        let span = b.t - a.t
        let amount = span > 0 ? (t - a.t) / span : 0
        return (a.x + (b.x - a.x) * amount, a.y + (b.y - a.y) * amount)
    }

    public static func cursor(_ samples: [MouseSample], at t: Double, smooth: Bool) -> (x: Double, y: Double)? {
        guard smooth else { return interpolated(samples, at: t) }
        var x = 0.0, y = 0.0, weight = 0.0
        for step in -4...4 {
            let offset = Double(step) * 0.03
            let w = 5.0 - Double(abs(step))
            guard let point = interpolated(samples, at: t + offset) else { return nil }
            x += point.x * w
            y += point.y * w
            weight += w
        }
        return (x / weight, y / weight)
    }

    /// Opacity of the cursor, which fades out after it has rested for a while.
    public static func cursorOpacity(_ samples: [MouseSample], at t: Double, idleAfter: Double = 2, fade: Double = 0.3) -> Double {
        guard let current = interpolated(samples, at: t), let firstSample = samples.first else { return 1 }
        let start = max(firstSample.t, t - idleAfter - fade)
        var lastMoved = start
        var probe = t
        while probe > start {
            if let point = interpolated(samples, at: probe), hypot(point.x - current.x, point.y - current.y) > 0.002 {
                lastMoved = probe
                break
            }
            probe -= 0.05
        }
        if lastMoved == start, t - start < idleAfter { return 1 }
        let rest = t - lastMoved
        if rest <= idleAfter { return 1 }
        return max(0, 1 - (rest - idleAfter) / fade)
    }

    public static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    public struct Camera: Equatable, Sendable {
        public let level: Double
        public let x: Double
        public let y: Double
    }

    /// The zoom level and focus point at a moment, easing in and out of each zoom.
    public static func camera(zooms: [ZoomSegment], cursor: (x: Double, y: Double)?, at t: Double, ramp: Double = 0.4) -> Camera {
        guard let zoom = zooms.first(where: { t >= $0.start && t <= $0.end }) else { return Camera(level: 1, x: 0.5, y: 0.5) }
        let halfway = (zoom.end - zoom.start) / 2
        let usable = min(ramp, halfway)
        let amount = usable > 0 ? smoothstep(min((t - zoom.start) / usable, (zoom.end - t) / usable)) : 1
        let level = 1 + (zoom.level - 1) * amount

        let targetX = zoom.followsCursor ? (cursor?.x ?? 0.5) : (zoom.centerX ?? 0.5)
        let targetY = zoom.followsCursor ? (cursor?.y ?? 0.5) : (zoom.centerY ?? 0.5)
        let half = 0.5 / level
        return Camera(
            level: level,
            x: 0.5 + (min(max(targetX, half), 1 - half) - 0.5) * (level > 1 ? 1 : 0),
            y: 0.5 + (min(max(targetY, half), 1 - half) - 0.5) * (level > 1 ? 1 : 0)
        )
    }

    public static func clickProgress(_ clicks: [ClickEvent], at t: Double, duration: Double = 0.45) -> (click: ClickEvent, progress: Double)? {
        guard let click = clicks.last(where: { $0.t <= t && t - $0.t <= duration }) else { return nil }
        return (click, (t - click.t) / duration)
    }

    public static func activeKeys(_ keys: [KeyEvent], at t: Double, duration: Double = 1.3) -> KeyEvent? {
        keys.last { $0.t <= t && t - $0.t <= duration }
    }
}
