import AppKit
import ImageIO
import SnapframeCore
import UniformTypeIdentifiers

struct OutputRequest {
    var image: CGImage
    var scale: CGFloat
    var modeName: String
    var saves: Bool
    var copies: Bool
    var format: ImageFormat
    var quality: Double
    var scaleTo1x: Bool
    var namePattern: String
    var directory: URL
}

struct OutputResult {
    var savedURL: URL?
    var copied: Bool
    var saveError: String?
}

enum OutputError: LocalizedError {
    case encodingFailed

    var errorDescription: String? { "The image could not be encoded." }
}

enum OutputService {
    static func downscaled(_ image: CGImage, by scale: CGFloat) -> CGImage {
        guard scale > 1 else { return image }
        let width = Int((CGFloat(image.width) / scale).rounded())
        let height = Int((CGFloat(image.height) / scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// JPEG has no alpha, so window shadows need something opaque beneath them.
    static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    static func encode(_ image: CGImage, format: ImageFormat, quality: Double, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.typeIdentifier as CFString, 1, nil
        ) else { throw OutputError.encodingFailed }

        let dpi = 72 * scale
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format.usesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, format.supportsTransparency ? image : flattened(image), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OutputError.encodingFailed }
        return data as Data
    }

    /// Runs off the main thread: encoding a 5K image can take a noticeable moment.
    static func process(_ request: OutputRequest) async throws -> OutputResult {
        let output = try await Task.detached(priority: .userInitiated) { () -> (URL?, String?, Data?) in
            let image = request.scaleTo1x ? downscaled(request.image, by: request.scale) : request.image
            let scale = request.scaleTo1x ? 1 : request.scale

            var savedURL: URL?
            var saveError: String?
            if request.saves {
                do {
                    let data = try encode(image, format: request.format, quality: request.quality, scale: scale)
                    let manager = FileManager.default
                    try manager.createDirectory(at: request.directory, withIntermediateDirectories: true)
                    let name = NameTemplate(pattern: request.namePattern).render(date: Date(), mode: request.modeName)
                    let url = NameTemplate.uniqueURL(
                        directory: request.directory,
                        baseName: name,
                        fileExtension: request.format.fileExtension
                    ) { manager.fileExists(atPath: $0.path) }
                    try data.write(to: url, options: .withoutOverwriting)
                    savedURL = url
                } catch {
                    saveError = error.localizedDescription
                }
            }

            // A failed save still lands on the clipboard, so the capture is never lost.
            let clipboardPNG = (request.copies || saveError != nil)
                ? try encode(image, format: .png, quality: 1, scale: scale)
                : nil
            return (savedURL, saveError, clipboardPNG)
        }.value

        var copied = false
        if let png = output.2 {
            let board = NSPasteboard.general
            board.clearContents()
            copied = board.setData(png, forType: .png)
        }
        return OutputResult(savedURL: output.0, copied: copied, saveError: output.1)
    }
}
