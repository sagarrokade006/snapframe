#if DEBUG
import AppKit
import AVFoundation
import ScreenCaptureKit
import SnapframeCore

/// Debug-only checks for Milestone 4. Nothing here runs in release builds.
enum PreviewRecording {
    private static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    private static func videoSample(_ index: Int, width: Int, height: Int, at time: CMTime) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(40 + index % 180), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    private static func audioSample(channels: UInt32, frames: Int, at time: CMTime) -> CMSampleBuffer? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let size = frames * Int(4 * channels)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block, let format else { return nil }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = Int(4 * channels)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        return sample
    }

    private static func feed(_ writer: RecordingWriter, seconds: Double, startIndex: Int = 0) async {
        let end = Date().addingTimeInterval(seconds)
        var index = startIndex
        while Date() < end {
            let now = hostNow
            writer.queue.sync {
                if let frame = videoSample(index, width: 640, height: 360, at: now) { writer.appendVideo(frame) }
                if let system = audioSample(channels: 2, frames: 1600, at: now) { writer.appendAudio(system, track: .system) }
                if let microphone = audioSample(channels: 1, frames: 1600, at: now) { writer.appendAudio(microphone, track: .microphone) }
            }
            index += 1
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func describe(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? -1
        let video = (try? await asset.loadTracks(withMediaType: .video))?.count ?? -1
        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? -1
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return String(format: "%.2fs, video tracks %d, audio tracks %d, %d KB", duration, video, audio, size / 1024)
    }

    /// Writes synthetic video and two audio tracks, with a pause in the middle.
    static func checkWriter(directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("writer.mov")
        try? FileManager.default.removeItem(at: movie)
        do {
            let writer = try RecordingWriter(url: movie, width: 640, height: 360, framesPerSecond: 30, system: true, microphone: true)
            await feed(writer, seconds: 2)
            writer.pause()
            await feed(writer, seconds: 2, startIndex: 500)
            writer.resume()
            await feed(writer, seconds: 1, startIndex: 900)
            print(String(format: "writer: elapsed reported %.2f", writer.elapsed))
            try await writer.finish()
            print("writer: mov \(await describe(movie)) (2s, 2s paused, 1s, so about 3s)")

            let mp4 = directory.appendingPathComponent("writer.mp4")
            try? FileManager.default.removeItem(at: mp4)
            try await RecordingExport.makeMP4(from: movie, to: mp4)
            print("writer: mp4 \(await describe(mp4))")

            let gif = directory.appendingPathComponent("writer.gif")
            try? FileManager.default.removeItem(at: gif)
            try await RecordingExport.makeGIF(from: movie, to: gif)
            let frames = CGImageSourceCreateWithURL(gif as CFURL, nil).map(CGImageSourceGetCount) ?? 0
            print("writer: gif frames \(frames)")
            print("writer: poster \(await RecordingExport.poster(of: movie) != nil)")
        } catch {
            print("writer: FAILED \(error)")
        }
    }

    /// Writes for a few seconds, then kills this process with no chance to clean up.
    static func crashWhileRecording(movie: URL) async {
        try? FileManager.default.removeItem(at: movie)
        guard let writer = try? RecordingWriter(url: movie, width: 640, height: 360, framesPerSecond: 30, system: true, microphone: true) else { return }
        await feed(writer, seconds: 7)
        print("crash: killing process now")
        fflush(stdout)
        kill(getpid(), SIGKILL)
    }

    static func inspectCrashed(movie: URL, directory: URL) async {
        print("recovered: \(await describe(movie))")
        let mp4 = directory.appendingPathComponent("recovered.mp4")
        try? FileManager.default.removeItem(at: mp4)
        do {
            try await RecordingExport.makeMP4(from: movie, to: mp4)
            print("recovered mp4: \(await describe(mp4))")
        } catch {
            print("recovered: FAILED \(error)")
        }
    }

    /// Records a real screen area with the real capture stream.
    @MainActor
    static func probe(rect: CGRect, seconds: Double, directory: URL) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("real.mov")
        try? FileManager.default.removeItem(at: movie)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = NSScreen.main?.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let size = RecordingFormat.outputSize(width: Int(rect.width * scale), height: Int(rect.height * scale), maximumHeight: 0)

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect
            configuration.width = size.width
            configuration.height = size.height
            configuration.scalesToFit = true
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 8
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = true
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let writer = try RecordingWriter(url: movie, width: size.width, height: size.height, framesPerSecond: 30, system: true, microphone: false)
            let recorder = ScreenRecorder(writer: writer, filter: filter, configuration: configuration)
            recorder.onFailure = { print("probe: stream stopped \($0)") }
            print("probe: starting stream")
            try await recorder.start(system: true, useMicrophone: false)
            print("probe: stream started")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            print(String(format: "probe: elapsed %.2f", writer.elapsed))
            await recorder.stop()
            print("probe: stream stopped")
            try await writer.finish()
            print("probe: mov \(await describe(movie))")
            let mp4 = directory.appendingPathComponent("real.mp4")
            try? FileManager.default.removeItem(at: mp4)
            try await RecordingExport.makeMP4(from: movie, to: mp4)
            print("probe: mp4 \(await describe(mp4))")
        } catch {
            print("probe: FAILED \(error)")
        }
    }
}
#endif
