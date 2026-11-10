import CoreGraphics
import Foundation

public enum RedactionMode: String, Codable, CaseIterable, Sendable {
    case secure, smooth, blackout

    public var title: String {
        switch self {
        case .secure: return "Secure"
        case .smooth: return "Smooth"
        case .blackout: return "Black Out"
        }
    }
}

public enum AnnotationShape: Codable, Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rectangle(CGRect, filled: Bool)
    case ellipse(CGRect)
    case freehand([CGPoint])
    case marker([CGPoint])
    case text(CGRect, string: String, fontSize: CGFloat)
    case counter(center: CGPoint, number: Int, radius: CGFloat)
    case spotlight(CGRect, oval: Bool)
    case redaction(CGRect, mode: RedactionMode)
    case image(CGRect, png: Data)
}

/// One editable object on the canvas. Coordinates are image points with y pointing down.
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var shape: AnnotationShape
    public var color: UInt32
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), shape: AnnotationShape, color: UInt32, lineWidth: CGFloat) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }

    public var bounds: CGRect {
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return Self.boundingBox([from, to])
        case .rectangle(let rect, _), .ellipse(let rect), .text(let rect, _, _),
             .spotlight(let rect, _), .redaction(let rect, _), .image(let rect, _):
            return rect
        case .freehand(let points), .marker(let points):
            return Self.boundingBox(points)
        case .counter(let center, _, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Hollow shapes only respond near their outline, so objects beneath them stay reachable.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + lineWidth / 2
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return Self.distance(point, toSegment: from, to) <= reach
        case .freehand(let points), .marker(let points):
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
            return zip(points, points.dropFirst()).contains { Self.distance(point, toSegment: $0, $1) <= reach }
        case .rectangle(let rect, let filled):
            if filled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            return rect.insetBy(dx: -reach, dy: -reach).contains(point) && !rect.insetBy(dx: reach, dy: reach).contains(point)
        case .ellipse(let rect):
            guard rect.width > 0, rect.height > 0 else { return false }
            let nx = (point.x - rect.midX) / (rect.width / 2)
            let ny = (point.y - rect.midY) / (rect.height / 2)
            let radial = sqrt(nx * nx + ny * ny)
            return abs(radial - 1) * min(rect.width, rect.height) / 2 <= reach
        case .counter(let center, _, let radius):
            return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
        case .text(let rect, _, _), .spotlight(let rect, _), .redaction(let rect, _), .image(let rect, _):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    public func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        mapped { CGPoint(x: $0.x + dx, y: $0.y + dy) } size: { $0 }
    }

    /// Stretches the object so its bounds become `target`.
    public func resized(to target: CGRect) -> Annotation {
        let old = bounds
        let sx = old.width > 0 ? target.width / old.width : 1
        let sy = old.height > 0 ? target.height / old.height : 1
        var copy = mapped {
            CGPoint(x: target.minX + ($0.x - old.minX) * sx, y: target.minY + ($0.y - old.minY) * sy)
        } size: {
            $0 * min(sx, sy)
        }
        if case .text(_, let string, let fontSize) = shape {
            copy.shape = .text(target, string: string, fontSize: fontSize * sy)
        }
        return copy
    }

    private func mapped(_ point: (CGPoint) -> CGPoint, size: (CGFloat) -> CGFloat) -> Annotation {
        func rect(_ value: CGRect) -> CGRect {
            let a = point(CGPoint(x: value.minX, y: value.minY))
            let b = point(CGPoint(x: value.maxX, y: value.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }

        var copy = self
        switch shape {
        case .arrow(let from, let to): copy.shape = .arrow(from: point(from), to: point(to))
        case .line(let from, let to): copy.shape = .line(from: point(from), to: point(to))
        case .rectangle(let value, let filled): copy.shape = .rectangle(rect(value), filled: filled)
        case .ellipse(let value): copy.shape = .ellipse(rect(value))
        case .freehand(let points): copy.shape = .freehand(points.map(point))
        case .marker(let points): copy.shape = .marker(points.map(point))
        case .text(let value, let string, let fontSize): copy.shape = .text(rect(value), string: string, fontSize: fontSize)
        case .counter(let center, let number, let radius): copy.shape = .counter(center: point(center), number: number, radius: size(radius))
        case .spotlight(let value, let oval): copy.shape = .spotlight(rect(value), oval: oval)
        case .redaction(let value, let mode): copy.shape = .redaction(rect(value), mode: mode)
        case .image(let value, let png): copy.shape = .image(rect(value), png: png)
        }
        return copy
    }

    public var isRedaction: Bool {
        if case .redaction = shape { return true }
        return false
    }
}

public enum CanvasFill: Codable, Equatable, Sendable {
    case none
    case color(UInt32)
    case gradient(UInt32, UInt32)
    /// Any number of evenly spaced colors at any angle.
    case linear([UInt32], angle: Double)
}

public struct CanvasStyle: Codable, Equatable, Sendable {
    public var fill: CanvasFill
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var shadow: CGFloat

    public init(fill: CanvasFill = .none, padding: CGFloat = 56, cornerRadius: CGFloat = 12, shadow: CGFloat = 0.55) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// Padding only exists when there is a background to show through it.
    public var effectivePadding: CGFloat { fill == .none ? 0 : padding }
}

public struct AnnotateDocument: Codable, Equatable, Sendable {
    public var imageSize: CGSize
    public var crop: CGRect?
    public var objects: [Annotation]
    public var style: CanvasStyle

    public init(imageSize: CGSize, crop: CGRect? = nil, objects: [Annotation] = [], style: CanvasStyle = CanvasStyle()) {
        self.imageSize = imageSize
        self.crop = crop
        self.objects = objects
        self.style = style
    }

    public var visibleRect: CGRect { crop ?? CGRect(origin: .zero, size: imageSize) }

    public var outputSize: CGSize {
        let visible = visibleRect.size
        let padding = style.effectivePadding
        return CGSize(width: visible.width + padding * 2, height: visible.height + padding * 2)
    }

    public var nextCounterNumber: Int {
        objects.reduce(0) { highest, object in
            if case .counter(_, let number, _) = object.shape { return max(highest, number) }
            return highest
        } + 1
    }

    /// The top-most object at a point.
    public func object(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        objects.last { $0.hitTest(point, tolerance: tolerance) }
    }

    public mutating func replace(_ annotation: Annotation) {
        guard let index = objects.firstIndex(where: { $0.id == annotation.id }) else { return }
        objects[index] = annotation
    }

    /// Returns the copy's id, or nil when the id is unknown.
    @discardableResult
    public mutating func duplicate(id: UUID, offset: CGFloat) -> UUID? {
        guard let original = objects.first(where: { $0.id == id }) else { return nil }
        var copy = original.translated(dx: offset, dy: offset)
        copy.id = UUID()
        objects.append(copy)
        return copy.id
    }
}

/// Snapshot undo. Each `record` adds one step, and recording clears anything that could be redone.
public struct EditHistory<State: Equatable> {
    private var past: [State] = []
    private var future: [State] = []
    public private(set) var current: State
    private let limit: Int

    public init(_ initial: State, limit: Int = 100) {
        current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public mutating func record(_ state: State) {
        guard state != current else { return }
        past.append(current)
        if past.count > limit { past.removeFirst() }
        future.removeAll()
        current = state
    }

    public mutating func undo() -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return previous
    }

    public mutating func redo() -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return next
    }
}

/// A `.snapframe` file: the edited document and the image beneath it.
public struct SnapframeProject: Codable, Equatable, Sendable {
    public static let fileExtension = "snapframe"
    public static let currentVersion = 1

    public var formatVersion: Int
    public var document: AnnotateDocument
    public var scale: Double
    public var basePNG: Data

    public init(document: AnnotateDocument, scale: Double, basePNG: Data) {
        formatVersion = Self.currentVersion
        self.document = document
        self.scale = scale
        self.basePNG = basePNG
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SnapframeProject {
        let project = try JSONDecoder().decode(SnapframeProject.self, from: data)
        guard project.formatVersion <= currentVersion else { throw ProjectError.newerVersion }
        return project
    }

    public enum ProjectError: LocalizedError {
        case newerVersion

        public var errorDescription: String? { "This project was made by a newer version of Snapframe." }
    }
}

public enum ProtectedPDF {
    public enum PDFError: LocalizedError, Equatable {
        case emptyPassword, couldNotCreate

        public var errorDescription: String? {
            self == .emptyPassword ? "Enter a password." : "The PDF could not be created."
        }
    }

    /// Writes one page containing the image. The password is required to open the file.
    public static func data(image: CGImage, scale: CGFloat, password: String) throws -> Data {
        guard !password.isEmpty else { throw PDFError.emptyPassword }

        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: password,
            kCGPDFContextOwnerPassword: password,
            kCGPDFContextEncryptionKeyLength: 128,
        ]
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary)
        else { throw PDFError.couldNotCreate }

        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}

extension SelectionGeometry {
    /// Moves `end` onto the nearest 45-degree direction from `start`.
    public static func snappedToAngle(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }
}
