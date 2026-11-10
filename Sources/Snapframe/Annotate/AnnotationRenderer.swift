import AppKit
import CoreImage
import ImageIO
import SnapframeCore

func snapCGColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws a document. The same code paints the canvas and produces exports, so they always match.
final class AnnotationRenderer {
    let base: CGImage
    let scale: CGFloat

    private var redactionCache: [String: CGImage] = [:]
    private var imageCache: [UUID: CGImage] = [:]
    private static let imageContext = CIContext()

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale
    }

    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let bounds = (string as NSString).boundingRect(
            with: CGSize(width: 4000, height: 4000),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: textFont(size: fontSize)]
        )
        return CGSize(width: ceil(bounds.width) + 4, height: ceil(bounds.height) + 2)
    }

    /// `context` must already use output points with y pointing down.
    func render(_ document: AnnotateDocument, draft: Annotation? = nil, in context: CGContext, showFullImage: Bool = false) {
        let visible = showFullImage ? CGRect(origin: .zero, size: document.imageSize) : document.visibleRect
        let padding = showFullImage ? 0 : document.style.effectivePadding
        let output = CGRect(x: 0, y: 0, width: visible.width + padding * 2, height: visible.height + padding * 2)
        let imageRect = CGRect(x: padding, y: padding, width: visible.width, height: visible.height)
        let radius = padding > 0 ? min(document.style.cornerRadius, min(visible.width, visible.height) / 2) : 0
        let shape = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if padding > 0 {
            drawFill(document.style.fill, in: output, context: context)
            let strength = document.style.shadow
            if strength > 0 {
                let device = abs(context.ctm.a)
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 0, height: -18 * strength * device),
                    blur: 44 * strength * device,
                    color: CGColor(gray: 0, alpha: min(strength, 1) * 0.65)
                )
                context.addPath(shape)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillPath()
                context.restoreGState()
            }
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.translateBy(x: imageRect.minX - visible.minX, y: imageRect.minY - visible.minY)
        drawImage(base, in: CGRect(origin: .zero, size: document.imageSize), context: context)
        for object in document.objects { draw(object, document: document, context: context) }
        if let draft { draw(draft, document: document, context: context) }
        context.restoreGState()
    }

    private func drawFill(_ fill: CanvasFill, in rect: CGRect, context: CGContext) {
        switch fill {
        case .none:
            return
        case .color(let hex):
            context.setFillColor(snapCGColor(hex))
            context.fill(rect)
        case .gradient(let start, let end):
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [snapCGColor(start), snapCGColor(end)] as CFArray,
                locations: [0, 1]
            ) else { return }
            context.saveGState()
            context.clip(to: rect)
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            context.restoreGState()
        case .linear(let stops, let angle):
            guard stops.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { snapCGColor($0) } as CFArray, locations: nil) else { return }
            let line = CanvasFill.gradientLine(angle: angle, size: rect.size)
            context.saveGState()
            context.clip(to: rect)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX + line.start.x, y: rect.minY + line.start.y),
                end: CGPoint(x: rect.minX + line.end.x, y: rect.minY + line.end.y),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func draw(_ object: Annotation, document: AnnotateDocument, context: CGContext) {
        let color = snapCGColor(object.color)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(object.lineWidth)
        context.setStrokeColor(color)
        context.setFillColor(color)

        switch object.shape {
        case .line(let from, let to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: object.lineWidth, context: context)

        case .rectangle(let rect, let filled):
            let path = CGPath(roundedRect: rect, cornerWidth: min(4, rect.width / 2), cornerHeight: min(4, rect.height / 2), transform: nil)
            context.addPath(path)
            if filled { context.fillPath() } else { context.strokePath() }

        case .ellipse(let rect):
            context.strokeEllipse(in: rect)

        case .freehand(let points):
            addSmoothPath(points, context: context)
            context.strokePath()

        case .marker(let points):
            context.setBlendMode(.multiply)
            context.setStrokeColor(snapCGColor(object.color, alpha: 0.55))
            context.setLineWidth(object.lineWidth * 5)
            context.setLineCap(.butt)
            addSmoothPath(points, context: context)
            context.strokePath()

        case .text(let rect, let string, let fontSize):
            withAppKit(context) {
                (string as NSString).draw(
                    with: rect,
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: Self.textFont(size: fontSize), .foregroundColor: NSColor(cgColor: color) ?? .white]
                )
            }

        case .counter(let center, let number, let radius):
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            drawCentered("\(number)", in: circle, fontSize: radius * 1.1, background: object.color, context: context)

        case .spotlight(let rect, let oval):
            let dim = CGMutablePath()
            dim.addRect(CGRect(origin: .zero, size: document.imageSize))
            if oval {
                dim.addEllipse(in: rect)
            } else {
                dim.addRoundedRect(in: rect, cornerWidth: min(8, rect.width / 2), cornerHeight: min(8, rect.height / 2))
            }
            context.addPath(dim)
            context.setFillColor(CGColor(gray: 0, alpha: 0.58))
            context.fillPath(using: .evenOdd)

        case .redaction(let rect, let mode):
            drawRedaction(object.id, rect: rect, mode: mode, context: context)

        case .image(let rect, let png):
            if let image = decoded(object.id, png: png) { drawImage(image, in: rect, context: context) }
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, context: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return }
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let head = min(max(lineWidth * 4.5, 16), length)
        let halfWidth = head * 0.56
        let neck = CGPoint(x: to.x - ux * head, y: to.y - uy * head)

        context.move(to: from)
        context.addLine(to: CGPoint(x: to.x - ux * head * 0.7, y: to.y - uy * head * 0.7))
        context.strokePath()

        context.move(to: to)
        context.addLine(to: CGPoint(x: neck.x - uy * halfWidth, y: neck.y + ux * halfWidth))
        context.addLine(to: CGPoint(x: neck.x + uy * halfWidth, y: neck.y - ux * halfWidth))
        context.closePath()
        context.fillPath()
    }

    private func addSmoothPath(_ points: [CGPoint], context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { context.addLine(to: $0) }
            if points.count == 1 { context.addLine(to: first) }
            return
        }
        for index in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            context.addQuadCurve(to: mid, control: points[index])
        }
        context.addLine(to: points[points.count - 1])
    }

    private func withAppKit(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCentered(_ string: String, in rect: CGRect, fontSize: CGFloat, background: UInt32, context: CGContext) {
        let red = CGFloat((background >> 16) & 0xFF), green = CGFloat((background >> 8) & 0xFF), blue = CGFloat(background & 0xFF)
        let isLight = 0.299 * red + 0.587 * green + 0.114 * blue > 140
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: isLight ? NSColor.black : NSColor.white,
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        withAppKit(context) {
            (string as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func decoded(_ id: UUID, png: Data) -> CGImage? {
        if let cached = imageCache[id] { return cached }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        imageCache[id] = image
        return image
    }

    private func drawRedaction(_ id: UUID, rect: CGRect, mode: RedactionMode, context: CGContext) {
        guard mode != .blackout else {
            context.setFillColor(CGColor(gray: 0.04, alpha: 1))
            context.fill(rect)
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(bounds)
        guard !pixels.isEmpty else { return }

        let key = "\(mode.rawValue)-\(pixels)"
        var result = redactionCache[key]
        if result == nil, let crop = base.cropping(to: pixels) {
            result = Self.obscure(crop, mode: mode, scale: scale)
            redactionCache[key] = result
        }
        if let result {
            drawImage(result, in: CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale), context: context)
        }
    }

    private static func obscure(_ image: CGImage, mode: RedactionMode, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter: CIFilter?
        switch mode {
        case .secure:
            filter = CIFilter(name: "CIPixellate", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputScaleKey: 22 * scale])
        case .smooth:
            filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 16 * scale])
        case .blackout:
            return nil
        }
        guard let output = filter?.outputImage else { return nil }
        return imageContext.createCGImage(output.cropped(to: input.extent), from: input.extent)
    }

    private func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// The finished image at full resolution.
    func flatten(_ document: AnnotateDocument) -> CGImage? {
        let output = document.outputSize
        let height = Int((output.height * scale).rounded())
        guard let context = bitmap(width: Int((output.width * scale).rounded()), height: height) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        render(document, in: context)
        return context.makeImage()
    }

    /// Paints redactions into the image itself and removes them as objects, so the original pixels can't be recovered.
    func burningRedactions(_ document: AnnotateDocument) -> (image: CGImage, document: AnnotateDocument)? {
        let redactions = document.objects.filter(\.isRedaction)
        guard !redactions.isEmpty else { return (base, document) }
        guard let context = bitmap(width: base.width, height: base.height) else { return nil }
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: scale, y: -scale)
        drawImage(base, in: CGRect(origin: .zero, size: document.imageSize), context: context)
        for object in redactions { draw(object, document: document, context: context) }
        guard let burned = context.makeImage() else { return nil }

        var updated = document
        updated.objects.removeAll(where: \.isRedaction)
        return (burned, updated)
    }
}
