import AppKit
import AVFoundation
import CoreImage
import Metal
import SnapframeCore

/// The project a compositor should draw. AVFoundation creates compositors itself, so this is shared.
final class StudioRenderState: @unchecked Sendable {
    static let shared = StudioRenderState()

    private let lock = NSLock()
    private var stored: StudioProject?

    var project: StudioProject? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?) {
        self.timeRange = timeRange
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        requiredSourceTrackIDs = ([screenTrack] + (cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class StudioCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "app.snapframe.compositor", qos: .userInitiated)
    private let renderer = StudioRenderer()
    private var cancelled = false

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync { cancelled = true }
        queue.async { self.cancelled = false }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard !self.cancelled else {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                  let screen = request.sourceFrame(byTrackID: instruction.screenTrack),
                  let project = StudioRenderState.shared.project,
                  let output = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: NSError(domain: "Snapframe", code: 1))
                return
            }
            let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }
            self.renderer.render(
                screen: screen, camera: camera, project: project,
                timeline: request.compositionTime.seconds,
                size: request.renderContext.size, into: output
            )
            request.finish(withComposedVideoFrame: output)
        }
    }
}

/// Draws one finished frame with Core Image on the GPU.
final class StudioRenderer {
    private let context: CIContext
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private var background: (key: String, image: CIImage)?
    private var keysCache: [String: CIImage] = [:]
    private var cursorCache: [String: CIImage] = [:]
    private var ring: CIImage?

    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func render(screen: CVPixelBuffer, camera: CVPixelBuffer?, project: StudioProject, timeline: Double, size: CGSize, into output: CVPixelBuffer) {
        let image = compose(CIImage(cvPixelBuffer: screen), camera: camera.map { CIImage(cvPixelBuffer: $0) }, project: project, timeline: timeline, size: size)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
    }

    private func compose(_ screen: CIImage, camera: CIImage?, project: StudioProject, timeline: Double, size: CGSize) -> CIImage {
        let appearance = project.appearance
        let style = appearance.canvas
        let canvas = CGRect(origin: .zero, size: size)
        let nominalWidth = Double(project.pixelWidth) + style.effectivePadding * project.scale * 2
        let unit = size.width / nominalWidth
        let pointUnit = project.scale * unit
        let padding = style.effectivePadding * pointUnit
        let area = canvas.insetBy(dx: padding, dy: padding)
        let source = project.sourceTime(at: timeline)

        var result = backgroundImage(style.fill, canvas: canvas)

        let cursor = StudioMotion.cursor(project.mouse, at: source, smooth: appearance.smoothCursor)
        let view = StudioMotion.camera(zooms: project.zooms, cursor: cursor, at: source)

        let sourceWidth = screen.extent.width, sourceHeight = screen.extent.height
        let scale = area.width / sourceWidth * view.level
        let tx = area.midX - view.x * sourceWidth * scale
        let ty = area.midY - (1 - view.y) * sourceHeight * scale

        func place(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * sourceWidth * scale + tx, y: (1 - y) * sourceHeight * scale + ty)
        }

        var content = screen.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: tx, y: ty))).cropped(to: area)

        if appearance.showClicks, let click = StudioMotion.clickProgress(project.clicks, at: source) {
            content = ripple(at: place(click.click.x, click.click.y), progress: click.progress, unit: pointUnit).composited(over: content)
        }
        if appearance.showCursor, let cursor {
            let opacity = appearance.hideCursorWhenIdle ? StudioMotion.cursorOpacity(project.mouse, at: source) : 1
            if opacity > 0 {
                let side = 34 * pointUnit * appearance.cursorScale * (1 + (view.level - 1) * 0.5)
                content = cursorImage(appearance.cursorStyle, at: place(cursor.x, cursor.y), side: side, opacity: opacity).composited(over: content)
            }
        }

        if padding > 0 {
            let radius = min(style.cornerRadius * pointUnit, min(area.width, area.height) / 2)
            let mask = rounded(area, radius: radius)
            if style.shadow > 0 {
                let shadow = mask
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: style.shadow * 0.65),
                    ])
                    .applyingGaussianBlur(sigma: 22 * style.shadow * pointUnit)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -18 * style.shadow * pointUnit))
                result = shadow.composited(over: result).cropped(to: canvas)
            }
            content = content.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        result = content.composited(over: result)

        if appearance.showCamera, let camera {
            result = cameraBubble(camera, appearance: appearance, area: area, level: view.level, unit: pointUnit).composited(over: result)
        }
        if appearance.showKeys, let keys = StudioMotion.activeKeys(project.keys, at: source) {
            let pill = keysImage(keys.parts, unit: pointUnit)
            let origin = CGPoint(x: area.midX - pill.extent.width / 2, y: area.minY + 26 * pointUnit)
            result = pill.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).composited(over: result)
        }
        return result.cropped(to: canvas)
    }

    private func color(_ hex: UInt32) -> CIColor {
        CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, colorSpace: space) ?? .black
    }

    private func backgroundImage(_ fill: CanvasFill, canvas: CGRect) -> CIImage {
        let key = "\(fill)-\(canvas.size)"
        if let background, background.key == key { return background.image }

        let image: CIImage
        switch fill {
        case .none:
            image = CIImage(color: .black).cropped(to: canvas)
        case .color(let hex):
            image = CIImage(color: color(hex)).cropped(to: canvas)
        case .gradient(let start, let end):
            image = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: canvas.height),
                "inputPoint1": CIVector(x: canvas.width, y: 0),
                "inputColor0": color(start),
                "inputColor1": color(end),
            ])?.outputImage?.cropped(to: canvas) ?? CIImage(color: .black).cropped(to: canvas)
        }
        background = (key, image)
        return image
    }

    private func rounded(_ rect: CGRect, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
    }

    private func drawn(width: Int, height: Int, _ body: (CGContext) -> Void) -> CIImage {
        guard let context = CGContext(
            data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }
        body(context)
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// Cursors are drawn large once and scaled, with y pointing up.
    private func cursorImage(_ style: CursorStyle, at point: CGPoint, side: CGFloat, opacity: Double) -> CIImage {
        let base: CIImage
        if let cached = cursorCache[style.rawValue] {
            base = cached
        } else {
            base = drawn(width: 128, height: 128) { c in
                switch style {
                case .pointer:
                    let path = CGMutablePath()
                    let points: [(CGFloat, CGFloat)] = [(8, 120), (8, 28), (32, 50), (48, 12), (68, 20), (52, 58), (86, 58)]
                    path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
                    path.closeSubpath()
                    c.addPath(path)
                    c.setLineWidth(8)
                    c.setLineJoin(.round)
                    c.setStrokeColor(CGColor(gray: 1, alpha: 1))
                    c.setFillColor(CGColor(gray: 0.08, alpha: 1))
                    c.drawPath(using: .fillStroke)
                case .dot:
                    c.setFillColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 0.9))
                    c.fillEllipse(in: CGRect(x: 34, y: 34, width: 60, height: 60))
                case .ring:
                    c.setStrokeColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 1))
                    c.setLineWidth(10)
                    c.strokeEllipse(in: CGRect(x: 24, y: 24, width: 80, height: 80))
                }
            }
            cursorCache[style.rawValue] = base
        }

        let factor = side / 128 * (style == .pointer ? 1 : 1.3)
        let drawnSide = 128 * factor
        let origin = style == .pointer
            ? CGPoint(x: point.x - 8 * factor, y: point.y - 120 * factor)
            : CGPoint(x: point.x - drawnSide / 2, y: point.y - drawnSide / 2)

        return base
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    private func ripple(at point: CGPoint, progress: Double, unit: CGFloat) -> CIImage {
        if ring == nil {
            ring = drawn(width: 256, height: 256) { c in
                let circle = CGRect(x: 12, y: 12, width: 232, height: 232)
                c.setFillColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 0.28))
                c.fillEllipse(in: circle)
                c.setStrokeColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 1))
                c.setLineWidth(9)
                c.strokeEllipse(in: circle)
            }
        }
        let diameter = (24 + 56 * progress) * unit
        let factor = diameter / 256
        return (ring ?? .empty())
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor).concatenating(CGAffineTransform(translationX: point.x - diameter / 2, y: point.y - diameter / 2)))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - progress)])
    }

    private func keysImage(_ parts: [String], unit: CGFloat) -> CIImage {
        let key = parts.joined(separator: " ") + "-\(Int(unit * 100))"
        if let cached = keysCache[key] { return cached }

        let font = NSFont.systemFont(ofSize: 24 * unit, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sizes = parts.map { ($0 as NSString).size(withAttributes: attributes) }
        let widths = sizes.map { max($0.width + 20 * unit, 42 * unit) }
        let gap = 8 * unit, inset = 12 * unit, height = 66 * unit
        let total = widths.reduce(0, +) + gap * CGFloat(parts.count - 1) + inset * 2

        let image = drawn(width: Int(total.rounded(.up)), height: Int(height.rounded(.up))) { c in
            let area = CGRect(x: 0, y: 0, width: total, height: height)
            c.addPath(CGPath(roundedRect: area, cornerWidth: 14 * unit, cornerHeight: 14 * unit, transform: nil))
            c.setFillColor(CGColor(srgbRed: 0.09, green: 0.094, blue: 0.106, alpha: 0.94))
            c.fillPath()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            var x = inset
            for (index, part) in parts.enumerated() {
                let cap = CGRect(x: x, y: inset, width: widths[index], height: height - inset * 2)
                c.addPath(CGPath(roundedRect: cap, cornerWidth: 7 * unit, cornerHeight: 7 * unit, transform: nil))
                c.setFillColor(CGColor(gray: 0.24, alpha: 1))
                c.fillPath()
                (part as NSString).draw(at: CGPoint(x: cap.midX - sizes[index].width / 2, y: cap.midY - sizes[index].height / 2), withAttributes: attributes)
                x += widths[index] + gap
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        keysCache[key] = image
        return image
    }

    private func cameraBubble(_ camera: CIImage, appearance: StudioAppearance, area: CGRect, level: Double, unit: CGFloat) -> CIImage {
        var diameter = min(area.width, area.height) * appearance.cameraSize * 1.6
        if appearance.shrinkCameraDuringZoom, level > 1 { diameter /= 1 + (level - 1) * 0.5 }

        let margin = 28 * unit
        let x: CGFloat, y: CGFloat
        switch appearance.cameraCorner {
        case .bottomRight: (x, y) = (area.maxX - diameter - margin, area.minY + margin)
        case .bottomLeft: (x, y) = (area.minX + margin, area.minY + margin)
        case .topRight: (x, y) = (area.maxX - diameter - margin, area.maxY - diameter - margin)
        case .topLeft: (x, y) = (area.minX + margin, area.maxY - diameter - margin)
        }

        let extent = camera.extent
        let cover = max(diameter / extent.width, diameter / extent.height)
        var transform = CGAffineTransform.identity
        if appearance.flipCamera {
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0)
        }
        let scaled = camera
            .transformed(by: transform.concatenating(CGAffineTransform(scaleX: cover, y: cover)))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: x + (diameter - scaled.extent.width) / 2 - scaled.extent.minX,
            y: y + (diameter - scaled.extent.height) / 2 - scaled.extent.minY
        ))
        let box = CGRect(x: x, y: y, width: diameter, height: diameter)
        let mask = rounded(box, radius: diameter / 2)
        let border = rounded(box.insetBy(dx: -3 * unit, dy: -3 * unit), radius: diameter / 2 + 3 * unit)
        return centered.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask]).composited(over: border)
    }
}

/// Builds the playable and exportable movie for a project.
enum StudioComposition {
    struct Result {
        let composition: AVMutableComposition
        let video: AVMutableVideoComposition
        let audio: AVMutableAudioMix
    }

    static func renderSize(for project: StudioProject, maximumHeight: Int = 0) -> CGSize {
        let padding = project.appearance.canvas.effectivePadding * project.scale
        let size = RecordingFormat.outputSize(
            width: Int(Double(project.pixelWidth) + padding * 2),
            height: Int(Double(project.pixelHeight) + padding * 2),
            maximumHeight: maximumHeight
        )
        return CGSize(width: size.width, height: size.height)
    }

    static func build(project: StudioProject, package: URL, maximumHeight: Int = 0) async throws -> Result {
        let screen = AVURLAsset(url: package.appendingPathComponent(StudioProject.screenFile))
        guard let sourceVideo = try await screen.loadTracks(withMediaType: .video).first else { throw RecordingError.nothingRecorded }
        let sourceAudio = try await screen.loadTracks(withMediaType: .audio)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.nothingRecorded
        }
        var audioTracks: [(source: AVAssetTrack, target: AVMutableCompositionTrack)] = []
        for track in sourceAudio {
            if let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                audioTracks.append((track, target))
            }
        }

        // A track only stays usable while its asset is alive, so this one lives as long as the build.
        let cameraAsset = project.hasCamera ? AVURLAsset(url: package.appendingPathComponent(StudioProject.cameraFile)) : nil
        var cameraSource: AVAssetTrack?
        var cameraTrack: AVMutableCompositionTrack?
        if let cameraAsset {
            if let track = try? await cameraAsset.loadTracks(withMediaType: .video).first {
                cameraSource = track
                cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
        }
        let cameraDuration = (try? await cameraSource?.load(.timeRange).duration.seconds) ?? 0

        var cursor = CMTime.zero
        for clip in project.clips {
            let range = CMTimeRange(start: time(clip.start), end: time(clip.end))
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            for pair in audioTracks { try? pair.target.insertTimeRange(range, of: pair.source, at: cursor) }

            if let cameraSource, let cameraTrack {
                let start = max(clip.start - project.cameraOffset, 0)
                let end = min(clip.end - project.cameraOffset, cameraDuration)
                if end > start {
                    let offset = CMTimeAdd(cursor, time(max(project.cameraOffset - clip.start, 0)))
                    try? cameraTrack.insertTimeRange(CMTimeRange(start: time(start), end: time(end)), of: cameraSource, at: offset)
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        let instruction = StudioInstruction(
            timeRange: CMTimeRange(start: .zero, duration: cursor),
            screenTrack: videoTrack.trackID,
            cameraTrack: cameraTrack?.trackID
        )
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = StudioCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: 60)
        video.renderSize = renderSize(for: project, maximumHeight: maximumHeight)
        video.instructions = [instruction]

        // The writer adds system audio before the microphone.
        var volumes: [Double] = []
        if project.hasSystemAudio { volumes.append(project.appearance.systemVolume) }
        if project.hasMicrophone { volumes.append(project.appearance.microphoneVolume) }
        let audio = AVMutableAudioMix()
        audio.inputParameters = audioTracks.enumerated().map { index, pair in
            let parameters = AVMutableAudioMixInputParameters(track: pair.target)
            parameters.setVolume(Float(index < volumes.count ? volumes[index] : 1), at: .zero)
            return parameters
        }
        return Result(composition: composition, video: video, audio: audio)
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }

    /// A rough loudness outline for the timeline.
    static func waveform(package: URL, buckets: Int) async -> [Float] {
        let asset = AVURLAsset(url: package.appendingPathComponent(StudioProject.screenFile))
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8_000,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        guard !samples.isEmpty, buckets > 0 else { return [] }

        let size = max(samples.count / buckets, 1)
        return stride(from: 0, to: samples.count, by: size).map { start in
            let slice = samples[start..<min(start + size, samples.count)]
            let peak = slice.reduce(Int32(0)) { max($0, abs(Int32($1))) }
            return min(Float(peak) / 16_000, 1)
        }
    }
}
