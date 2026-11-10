#if DEBUG
import AppKit
import CoreImage
import SnapframeCore
import SwiftUI

/// Debug-only checks for Milestone 3, using synthetic pages and real system frameworks.
@MainActor
enum PreviewSmart {
    private static func bitmap(_ width: Int, _ height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
    }

    /// A tall page with a distinct line of text every 40 rows. Row 0 of the result is the top of the page.
    private static func tallPage(width: Int, height: Int) -> CGImage {
        let context = bitmap(width, height)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for line in 0..<(height / 40) {
            let text = "Line \(line): the quick brown fox jumps over \(line * 37 % 101) lazy dogs"
            (text as NSString).draw(
                at: CGPoint(x: 24 + CGFloat(line % 7) * 9, y: CGFloat(height - 34 - line * 40)),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func frame(page: CGImage, scroll: Int, width: Int, header: Int, body: Int, footer: Int) -> CGImage {
        let height = header + body + footer
        let context = bitmap(width, height)
        let visible = page.cropping(to: CGRect(x: 0, y: scroll, width: width, height: body))!
        context.draw(visible, in: CGRect(x: 0, y: footer, width: width, height: body))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: height - header, width: width, height: header))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        for mark in stride(from: 8, to: width - 40, by: 26) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: mark, y: height - header + 8, width: 10, height: 14))
            context.fill(CGRect(x: mark, y: 8, width: 10, height: 14))
        }
        return context.makeImage()!
    }

    static func checkStitching() {
        let width = 1000, header = 60, body = 700, footer = 40
        let page = tallPage(width: width, height: 4000)
        let stitcher = ScrollStitcher()
        let positions = [0, 120, 333, 600, 601, 950, 1290, 1700, 2100, 2500]
        var results: [ScrollMatch] = []
        for scroll in positions {
            results.append(stitcher.ingest(frame(page: page, scroll: scroll, width: width, header: header, body: body, footer: footer)))
        }
        let expectedRows = header + positions.last! + body + footer
        let composed = stitcher.compose()!
        let expected = bitmap(width, expectedRows)
        let content = page.cropping(to: CGRect(x: 0, y: 0, width: width, height: positions.last! + body))!
        let source = frame(page: page, scroll: 0, width: width, header: header, body: body, footer: footer)
        expected.draw(content, in: CGRect(x: 0, y: footer, width: width, height: positions.last! + body))
        expected.draw(source.cropping(to: CGRect(x: 0, y: 0, width: width, height: header))!, in: CGRect(x: 0, y: expectedRows - header, width: width, height: header))
        expected.draw(source.cropping(to: CGRect(x: 0, y: header + body, width: width, height: footer))!, in: CGRect(x: 0, y: 0, width: width, height: footer))

        let equal = ScrollStitcher.signatures(of: composed) == ScrollStitcher.signatures(of: expected.makeImage()!)
        let moved = results.filter { if case .moved = $0 { return true } else { return false } }.count
        print("stitch: moves \(moved)/\(positions.count - 1), rows \(composed.height) expected \(expectedRows), identical to page: \(equal)")

        let back = ScrollStitcher()
        back.ingest(frame(page: page, scroll: 800, width: width, header: header, body: body, footer: footer))
        let reversed = back.ingest(frame(page: page, scroll: 700, width: width, header: header, body: body, footer: footer))
        print("stitch: scrolling up reported as \(reversed)")

        func withSidebar(_ image: CGImage, noise: Bool) -> CGImage {
            let w = image.width, h = image.height
            let context = bitmap(w, h)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.92, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: h))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 200, y: 0, width: 2, height: h))
            for line in stride(from: 20, to: h - 20, by: 34) {
                context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                context.fill(CGRect(x: 20, y: line, width: 90 + line % 70, height: 12))
            }
            if noise, let data = context.data {
                let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * h)
                var seed = UInt32(truncatingIfNeeded: h &* 31)
                for index in stride(from: 0, to: context.bytesPerRow * h, by: 7) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    bytes[index] = UInt8(clamping: Int(bytes[index]) + Int(seed >> 30) - 1)
                }
            }
            return context.makeImage()!
        }

        for noise in [false, true] {
            let side = ScrollStitcher()
            var moved = 0
            for scroll in positions {
                if case .moved = side.ingest(withSidebar(frame(page: page, scroll: scroll, width: width, header: header, body: body, footer: footer), noise: noise)) { moved += 1 }
            }
            let result = side.compose()
            print("stitch: sidebar\(noise ? " and pixel noise" : ""), moves \(moved)/\(positions.count - 1), size \(result?.width ?? 0)x\(result?.height ?? 0)")
        }
    }

    static func checkRecognition(screen: DisplaySnapshot) async {
        let crop = SelectionGeometry.pixelCrop(CGRect(x: 230, y: 120, width: 700, height: 220), scale: screen.scale, imageSize: CGSize(width: screen.image.width, height: screen.image.height))
        let content = await TextCapture.recognize(screen.image.cropping(to: crop)!, detectLanguage: true)
        print("ocr: \(TextComposer.compose(content.fragments, keepLineBreaks: false))")

        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/snapframe".utf8), "inputCorrectionLevel": "M"])!
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let qr = CIContext().createCGImage(scaled, from: scaled.extent)!
        let codes = await TextCapture.recognize(qr, detectLanguage: true)
        print("qr: \(codes.codes), openable: \(codes.codes.first.flatMap(CapturedLink.openableURL) != nil)")
    }

    /// Stitches a real screen region for a while and reports how each frame matched.
    static func scrollProbe(rect: CGRect, seconds: Double, output: URL) async {
        guard let id = NSScreen.main?.displayID else { return }
        let service = CaptureService()
        let options = CaptureOptions(showsCursor: false, convertToSRGB: true, windowShadow: false)
        let stitcher = ScrollStitcher()
        var counts: [String: Int] = [:]
        var frameTimes: [Double] = []
        var scale: CGFloat = 1
        let end = Date().addingTimeInterval(seconds)

        do {
            while Date() < end {
                let started = Date()
                let frame = try await service.captureRegion(displayID: id, rect: rect, options: options)
                scale = frame.scale
                let match = stitcher.ingest(frame.image)
                let name: String
                switch match {
                case .moved: name = "moved"
                case .unchanged: name = "unchanged"
                case .reversed: name = "reversed"
                case .lost: name = "lost"
                }
                counts[name, default: 0] += 1
                frameTimes.append(Date().timeIntervalSince(started) * 1000)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        } catch {
            print("probe error: \(error)")
        }
        let average = frameTimes.isEmpty ? 0 : frameTimes.reduce(0, +) / Double(frameTimes.count)
        print("probe: frames \(frameTimes.count), matches \(counts), capture and match \(Int(average)) ms, stitched rows \(stitcher.totalRows), scale \(scale)")
        if let image = stitcher.compose(), let png = try? OutputService.encode(image, format: .png, quality: 1, scale: scale) {
            try? png.write(to: output)
            print("probe: wrote \(image.width)x\(image.height)")
        }
    }

    static func sampleResult() -> RecognizedContent {
        RecognizedContent(
            fragments: [
                TextFragment(text: "Check the onboarding copy before the next build.", x: 0.05, y: 0.1, height: 0.1),
                TextFragment(text: "Confirm the shortcut defaults on a clean account.", x: 0.05, y: 0.3, height: 0.1),
            ],
            codes: ["https://example.com/snapframe"]
        )
    }

    /// Briefly places the cover on the real desktop and reports what a capture would include.
    static func checkCover() async {
        let cover = DesktopIconCover.shared
        await cover.show()
        let ids = cover.windowIDs
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let levels = list.filter { ids.contains(($0[kCGWindowNumber as String] as? CGWindowID) ?? 0) }.compactMap { $0[kCGWindowLayer as String] as? Int }
        print("cover: windows \(ids.count), layers \(levels), icon level \(CGWindowLevelForKey(.desktopIconWindow))")
        cover.hide()
        print("cover: hidden, windows left \(cover.windowIDs.count)")
    }
}
#endif
