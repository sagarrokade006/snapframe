import CoreGraphics
import Foundation

public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Pure geometry for the capture overlay. All coordinates are display-local points with y pointing down.
public enum SelectionGeometry {
    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    public static func rect(anchor: CGPoint, current: CGPoint, aspect: CGFloat?, bounds: CGRect) -> CGRect {
        let start = clamp(anchor, to: bounds)
        let end = clamp(current, to: bounds)
        guard let aspect else {
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        }

        let goesRight = end.x >= start.x
        let goesDown = end.y >= start.y
        let roomX = goesRight ? bounds.maxX - start.x : start.x - bounds.minX
        let roomY = goesDown ? bounds.maxY - start.y : start.y - bounds.minY
        let width = min(max(abs(end.x - start.x), abs(end.y - start.y) * aspect), roomX, roomY * aspect)
        let height = width / aspect
        return CGRect(
            x: goesRight ? start.x : start.x - width,
            y: goesDown ? start.y : start.y - height,
            width: width,
            height: height
        )
    }

    /// Moves a point onto the nearest guide on each axis when it is within `threshold`.
    public static func snapped(_ point: CGPoint, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat) -> CGPoint {
        func nearest(_ value: CGFloat, _ guides: [CGFloat]) -> CGFloat {
            guard let best = guides.min(by: { abs($0 - value) < abs($1 - value) }),
                  abs(best - value) <= threshold
            else { return value }
            return best
        }
        return CGPoint(x: nearest(point.x, xs), y: nearest(point.y, ys))
    }

    public static func point(of handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    public static func handle(at point: CGPoint, in rect: CGRect, radius: CGFloat) -> SelectionHandle? {
        SelectionHandle.allCases.first { handle in
            let target = Self.point(of: handle, in: rect)
            return abs(target.x - point.x) <= radius && abs(target.y - point.y) <= radius
        }
    }

    /// Drags one handle while the opposite edges stay fixed. Dragging past the far edge stops at `minSize`.
    public static func resized(
        _ rect: CGRect,
        handle: SelectionHandle,
        to rawPoint: CGPoint,
        minSize: CGFloat,
        bounds: CGRect
    ) -> CGRect {
        let point = clamp(rawPoint, to: bounds)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(point.x, maxX - minSize)
        case .topRight, .right, .bottomRight: maxX = max(point.x, minX + minSize)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(point.y, maxY - minSize)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(point.y, minY + minSize)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func moved(_ rect: CGRect, by delta: CGVector, bounds: CGRect) -> CGRect {
        var result = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// Converts points to a whole-pixel crop that contains the selection and stays inside the image.
    public static func pixelCrop(_ rect: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let minX = floor(rect.minX * scale)
        let minY = floor(rect.minY * scale)
        let maxX = ceil(rect.maxX * scale)
        let maxY = ceil(rect.maxY * scale)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Places the loupe beside the cursor, flipping to the other side near a screen edge.
    public static func loupeOrigin(cursor: CGPoint, size: CGFloat, offset: CGFloat, bounds: CGRect) -> CGPoint {
        var x = cursor.x + offset
        var y = cursor.y + offset
        if x + size > bounds.maxX { x = cursor.x - offset - size }
        if y + size > bounds.maxY { y = cursor.y - offset - size }
        return CGPoint(x: max(x, bounds.minX), y: max(y, bounds.minY))
    }
}
