import AppKit
import Combine
import SnapframeCore
import SwiftUI

/// Builds one tall image from successive frames of a scrolling area.
///
/// Sidebars and other still parts of the selection would stop rows from lining up, so frames
/// are compared, and the result is built, using only the columns that actually scroll.
final class ScrollStitcher {
    static let maximumRows = 32_000

    private var first: CGImage?
    private var firstFooter = 0
    private var last: CGImage?
    private var lastFooter = 0
    private var strips: [CGImage] = []
    private var previous: [RowSignature] = []
    private var columns: Range<Int>?
    private var outputColumns: Range<Int>?

    private(set) var totalRows = 0

    var hasMoved: Bool { !strips.isEmpty }
    var isTooLong: Bool { totalRows >= Self.maximumRows }

    /// Compares a frame with the last accepted one and keeps any newly revealed rows.
    @discardableResult
    func ingest(_ frame: CGImage) -> ScrollMatch {
        guard let reference = last else {
            first = frame
            last = frame
            totalRows = frame.height
            return .unchanged
        }

        if columns == nil {
            guard let found = Self.movingColumns(from: reference, to: frame) else { return .unchanged }
            columns = found.moving
            outputColumns = found.output
            previous = Self.signatures(of: reference, columns: found.moving)
        }
        guard let columns, let outputColumns else { return .unchanged }

        let signatures = Self.signatures(of: frame, columns: columns)
        let match = ScrollMatcher.compare(previous: previous, current: signatures)
        guard case .moved(let offset, let footer) = match else {
            // Early on, the area in motion may have been misjudged, so look again.
            if match == .lost, strips.isEmpty { self.columns = nil }
            return match
        }

        // Blank page rows beside a footer can look fixed for a frame or two. The smallest footer seen
        // is the real one, and when it shrinks the rows held back earlier are added here.
        let settled = strips.isEmpty ? footer : min(lastFooter, footer)
        let heldBack = strips.isEmpty ? 0 : lastFooter - settled
        let newRows = ScrollMatcher.newRows(rowCount: frame.height, offset: offset, footer: settled)
        let rows = max(newRows.lowerBound - heldBack, 0)..<newRows.upperBound
        let area = CGRect(x: outputColumns.lowerBound, y: rows.lowerBound, width: outputColumns.count, height: rows.count)
        guard let strip = frame.cropping(to: area) else { return .lost }

        if strips.isEmpty { firstFooter = settled }
        strips.append(strip)
        last = frame
        lastFooter = settled
        previous = signatures
        totalRows += rows.count
        return match
    }

    func compose() -> CGImage? {
        guard let first, let last else { return nil }
        guard !strips.isEmpty, let columns = outputColumns else { return first }

        var pieces: [CGImage] = []
        if let top = first.cropping(to: CGRect(x: columns.lowerBound, y: 0, width: columns.count, height: first.height - firstFooter)) {
            pieces.append(top)
        }
        pieces += strips
        if lastFooter > 0, let footer = last.cropping(to: CGRect(x: columns.lowerBound, y: last.height - lastFooter, width: columns.count, height: lastFooter)) {
            pieces.append(footer)
        }

        let height = pieces.reduce(0) { $0 + $1.height }
        guard let context = CGContext(
            data: nil, width: columns.count, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        var top = height
        for piece in pieces {
            top -= piece.height
            context.draw(piece, in: CGRect(x: 0, y: top, width: piece.width, height: piece.height))
        }
        return context.makeImage()
    }

    private static func pixels(of image: CGImage) -> [UInt32]? {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Which columns moved between two frames, and how far the pane reaches once its blank margins are included.
    static func movingColumns(from older: CGImage, to newer: CGImage) -> (moving: Range<Int>, output: Range<Int>)? {
        guard older.width == newer.width, older.height == newer.height,
              let a = pixels(of: older), let b = pixels(of: newer)
        else { return nil }

        let width = older.width, height = older.height
        let rows = Array(stride(from: 0, to: height, by: 4))
        let required = max(rows.count * 6 / 100, 3)
        let changed = (0..<width).map { column in
            rows.reduce(0) { $0 + (a[$1 * width + column] != b[$1 * width + column] ? 1 : 0) } >= required
        }
        guard let left = changed.firstIndex(of: true), let right = changed.lastIndex(of: true),
              right - left + 1 >= max(width / 50, 40)
        else { return nil }

        func similar(_ x: UInt32, _ y: UInt32) -> Bool {
            abs(Int((x >> 16) & 0xFF) - Int((y >> 16) & 0xFF)) <= 3
                && abs(Int((x >> 8) & 0xFF) - Int((y >> 8) & 0xFF)) <= 3
                && abs(Int(x & 0xFF) - Int(y & 0xFF)) <= 3
        }

        /// The most common color in a column, when it covers most of the column.
        func marginColor(_ column: Int) -> UInt32? {
            var counts: [UInt32: Int] = [:]
            for row in rows { counts[a[row * width + column], default: 0] += 1 }
            guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
            let matching = rows.reduce(0) { $0 + (similar(a[$1 * width + column], top.key) ? 1 : 0) }
            return matching * 100 >= rows.count * 80 ? top.key : nil
        }

        // Toolbars can cross a margin, so most of the column has to match rather than all of it.
        var outerLeft = left
        if left > 0, let color = marginColor(left - 1) {
            while outerLeft > 0, let next = marginColor(outerLeft - 1), similar(next, color) { outerLeft -= 1 }
        }
        var outerRight = right
        if right < width - 1, let color = marginColor(right + 1) {
            while outerRight < width - 1, let next = marginColor(outerRight + 1), similar(next, color) { outerRight += 1 }
        }
        return (left..<(right + 1), outerLeft..<(outerRight + 1))
    }

    static func signatures(of image: CGImage) -> [RowSignature] {
        signatures(of: image, columns: 0..<image.width)
    }

    /// Ignores the right edge, where a scroll bar moves independently of the page.
    static func signatures(of image: CGImage, columns: Range<Int>) -> [RowSignature] {
        guard let pixels = pixels(of: image) else { return [] }
        let width = image.width
        let usable = max(columns.count - max(columns.count / 32, 8), 1)
        let buckets = 40
        let bucketWidth = max(usable / buckets, 1)

        return (0..<image.height).map { row in
            let start = row * width + columns.lowerBound
            let reference = pixels[start]
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            var flat = true
            var profile = [UInt8](repeating: 0, count: buckets)
            var sums = [Int](repeating: 0, count: buckets)
            var counts = [Int](repeating: 0, count: buckets)

            var column = 0
            while column < usable {
                let pixel = pixels[start + column]
                if pixel != reference { flat = false }
                hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                let bucket = min(column / bucketWidth, buckets - 1)
                sums[bucket] += Int((pixel >> 16) & 0xFF) + 2 * Int((pixel >> 8) & 0xFF) + Int(pixel & 0xFF)
                counts[bucket] += 4
                column += 2
            }
            for index in 0..<buckets where counts[index] > 0 {
                profile[index] = UInt8(min(sums[index] / counts[index], 255))
            }
            return RowSignature(hash: hash, isFlat: flat, profile: profile)
        }
    }
}

/// Runs a scrolling capture: outlines the area, samples it, and shows live progress.
@MainActor
final class ScrollCaptureController: ObservableObject {
    @Published private(set) var note = "Scroll down at a steady speed."
    @Published private(set) var isWarning = false
    @Published private(set) var rows = 0
    @Published private(set) var preview: NSImage?

    private var stopped = false
    private var cancelled = false
    private var panels: [NSPanel] = []
    private var lostFrames = 0

    private static let captureInterval: UInt64 = 40_000_000

    typealias Frame = (image: CGImage, scale: CGFloat)

    static func run(displayID: CGDirectDisplayID, rect: CGRect, capture: @escaping () async throws -> Frame) async throws -> Frame? {
        let controller = ScrollCaptureController()
        controller.presentPanels(displayID: displayID, rect: rect)
        defer { controller.closePanels() }
        return try await controller.loop(capture: capture)
    }

    func finish() { stopped = true }

    func cancel() {
        cancelled = true
        stopped = true
    }

    private func loop(capture: @escaping () async throws -> Frame) async throws -> Frame? {
        let stitcher = ScrollStitcher()
        var scale: CGFloat = 1

        while !stopped {
            let frame = try await capture()
            scale = frame.scale
            let image = frame.image
            let match = await Task.detached(priority: .userInitiated) { stitcher.ingest(image) }.value
            update(match, rows: stitcher.totalRows)
            if case .moved = match { preview = NSImage(cgImage: image, size: .zero) }
            if preview == nil { preview = NSImage(cgImage: image, size: .zero) }

            if stitcher.isTooLong {
                note = "Reached the maximum length."
                stopped = true
            }
            try? await Task.sleep(nanoseconds: Self.captureInterval)
        }

        guard !cancelled else { return nil }
        guard stitcher.hasMoved else { throw CaptureError.nothingStitched }
        let result = await Task.detached(priority: .userInitiated) { stitcher.compose() }.value
        return result.map { ($0, scale) }
    }

    private func update(_ match: ScrollMatch, rows: Int) {
        self.rows = rows
        if match != .lost { lostFrames = 0 }
        switch match {
        case .moved:
            note = "Keep scrolling. Fixed headers are skipped."
            isWarning = false
        case .unchanged:
            break
        case .reversed:
            note = "Scroll down only. Go back to where you stopped."
            isWarning = true
        case .lost:
            // One unmatched frame is normal, so only speak up if it keeps happening.
            lostFrames += 1
            if lostFrames >= 4 {
                note = "Can't line up this content. Scroll back a little and go slower, or select only the part that scrolls."
                isWarning = true
            }
        }
    }

    private func presentPanels(displayID: CGDirectDisplayID, rect: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let global = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)

        let outline = KeylessPanel(size: CGSize(width: global.width + 8, height: global.height + 8))
        outline.level = .statusBar
        outline.ignoresMouseEvents = true
        outline.hasShadow = false
        outline.contentView = NSHostingView(rootView: Rectangle().stroke(Color.snapAccent, lineWidth: 2).padding(1))
        outline.setFrameOrigin(CGPoint(x: global.minX - 4, y: global.minY - 4))
        outline.orderFrontRegardless()

        let size = CGSize(width: 230, height: min(max(global.height, 340), 460))
        let panel = KeylessPanel(size: size)
        panel.level = .statusBar
        panel.contentView = FirstMouseHostingView(rootView: ScrollProgressView(controller: self, height: size.height))

        let area = screen.visibleFrame
        var x = global.maxX + 16
        if x + size.width > area.maxX { x = global.minX - 16 - size.width }
        if x < area.minX { x = global.maxX - size.width - 12 }
        let y = min(max(global.maxY - size.height, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()

        panels = [outline, panel]
    }

    private func closePanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }
}

struct ScrollProgressView: View {
    @ObservedObject var controller: ScrollCaptureController
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stitching").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(verbatim: "\(controller.rows) px").font(.system(size: 12)).foregroundStyle(Color.snapMuted).monospacedDigit()
            }

            ZStack {
                Color(hex: 0x26282D)
                if let preview = controller.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(controller.note)
                .font(.system(size: 13))
                .foregroundStyle(controller.isWarning ? Color.snapAccent : Color(hex: 0xC4C6CC))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") { controller.cancel() }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Finish") { controller.finish() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 230, height: height)
        .background(Color.snapSidebar)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .snapWindowStyle()
    }
}
