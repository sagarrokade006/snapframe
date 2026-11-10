import AVFoundation
import ScreenCaptureKit
import SnapframeCore

enum RecordingError: LocalizedError {
    case writerFailed(String)
    case nothingRecorded
    case lowDisk
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .writerFailed(let reason): return "The recording could not be written. \(reason)"
        case .nothingRecorded: return "Nothing was recorded."
        case .lowDisk: return "Your disk is almost full, so the recording did not start."
        case .displayNotFound: return "That display is no longer connected."
        }
    }
}

/// Writes video and separate audio tracks to a movie that stays readable if the app is killed.
final class RecordingWriter: @unchecked Sendable {
    enum AudioTrack { case system, microphone }

    /// Every append must happen on this queue.
    let queue = DispatchQueue(label: "app.snapframe.recording", qos: .userInitiated)

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let frameDuration: Double

    private var clock = PauseClock()
    private var started = false
    private var lastFrame: CMSampleBuffer?
    private var lastPosition = 0.0

    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    init(url: URL, width: Int, height: Int, framesPerSecond: Int, system: Bool, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Regularly flushed fragments are what make a crashed recording playable.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        frameDuration = 1 / Double(max(framesPerSecond, 1))

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * framesPerSecond / 8, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }

        systemInput = system ? audioInput(channels: 2) : nil
        microphoneInput = microphone ? audioInput(channels: 1) : nil
        [systemInput, microphoneInput].compactMap { $0 }.forEach { writer.add($0) }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard writer.status != .failed, writer.status != .cancelled else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds

        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            clock.begin(at: time)
            started = true
        }
        guard let position = clock.position(of: time), videoInput.isReadyForMoreMediaData,
              let timed = Self.retimed(sample, to: position)
        else { return }

        if videoInput.append(timed) {
            lastFrame = timed
            lastPosition = position
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: AudioTrack) {
        guard started, writer.status == .writing else { return }
        let input = track == .system ? systemInput : microphoneInput
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard let input, input.isReadyForMoreMediaData,
              let position = clock.position(of: time),
              let timed = Self.retimed(sample, to: position)
        else { return }
        input.append(timed)
    }

    private static func retimed(_ sample: CMSampleBuffer, to position: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)

        let first = timing[0].presentationTimeStamp
        let target = CMTime(seconds: position, preferredTimescale: 600_000)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeAdd(target, CMTimeSubtract(timing[index].presentationTimeStamp, first))
            timing[index].decodeTimeStamp = .invalid
        }

        var output: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &output
        )
        return output
    }

    func pause() { queue.sync { clock.pause(at: Self.now) } }
    func resume() { queue.sync { clock.resume(at: Self.now) } }
    var elapsed: Double { queue.sync { clock.elapsed(at: Self.now) } }

    func finish() async throws {
        let end: CMTime = try queue.sync {
            guard started else { throw RecordingError.nothingRecorded }
            if writer.status == .failed {
                throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "")
            }
            // A still screen produces no new frames, so hold the last one until the end.
            let total = max(clock.elapsed(at: Self.now), lastPosition + frameDuration)
            if let lastFrame, total > lastPosition + frameDuration, videoInput.isReadyForMoreMediaData,
               let held = Self.retimed(lastFrame, to: total) {
                videoInput.append(held)
            }
            self.lastFrame = nil
            videoInput.markAsFinished()
            systemInput?.markAsFinished()
            microphoneInput?.markAsFinished()
            return CMTime(seconds: total, preferredTimescale: 600_000)
        }

        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "")
        }
    }

    func cancel() {
        queue.sync { lastFrame = nil }
        if writer.status == .writing { writer.cancelWriting() }
    }
}

/// Feeds the screen, system audio and microphone into a writer.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: RecordingWriter
    private let stream: SCStream
    private var microphone: AVCaptureSession?

    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(writer: RecordingWriter, filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.writer = writer
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()
    }

    func start(system: Bool, useMicrophone: Bool) async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
        if system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue) }
        if useMicrophone { startMicrophone() }
        try await stream.startCapture()
    }

    private func startMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: writer.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        microphone = session
    }

    func stop() async {
        try? await stream.stopCapture()
        microphone?.stopRunning()
        microphone = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete
            else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendAudio(sampleBuffer, track: .system)
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.appendAudio(sampleBuffer, track: .microphone)
        if let power = connection.audioChannels.first?.averagePowerLevel {
            // Maps roughly -50 dB to silence and 0 dB to full.
            onLevel?(max(0, min(1, (power + 50) / 50)))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}
