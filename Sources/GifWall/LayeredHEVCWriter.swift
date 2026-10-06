import AVFoundation
import VideoToolbox

/// HEVC writer whose stream has two temporal layers, like Apple's own Aerials.
///
/// The lock screen's Aerial player changes playback speed to ramp down when it pauses (unlock, screen
/// saver end). It relies on the temporal-layer sample groups (`tscl`/`tsas`) to drop frames while doing
/// so; on a plain single-layer stream it fails with `VideoSampleReadingErrors` code 4 and stays frozen
/// on its first frame from then on. AVAssetWriter can't request layers for HEVC, so frames are
/// compressed with VideoToolbox directly and the result is muxed without re-encoding.
final class LayeredHEVCWriter {
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let session: VTCompressionSession
    private let fps: Double
    private var started = false
    private let output = EncodedFrames()

    init(url: URL, width: Int, height: Int, fps: Double) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        self.fps = fps
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let s else { throw MediaConverterError.writerFailed("HEVC encoder (\(status))") }
        session = s
        // Constant quality instead of a fixed bitrate: detailed footage gets the bits it needs.
        set(kVTCompressionPropertyKey_Quality, 0.9)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        // Base layer at half rate, every other frame droppable — what Apple's Aerials use.
        set("NumberOfTemporalLayers" as CFString, 2)
        set(kVTCompressionPropertyKey_BaseLayerFrameRate, fps / 2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func set(_ key: CFString, _ value: Any) {
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    }

    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) async throws {
        let output = self.output
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            output.add(status, sample)
        }
        guard status == noErr else { throw MediaConverterError.writerFailed("HEVC encode (\(status))") }
        try await drain()
    }

    func finish(at end: CMTime) async throws {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try await drain()
        VTCompressionSessionInvalidate(session)
        guard let input else { throw MediaConverterError.empty }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
    }

    /// Writes whatever the encoder has produced so far.
    private func drain() async throws {
        let (batch, failure) = output.take()
        guard failure == noErr else { throw MediaConverterError.writerFailed("HEVC encode (\(failure))") }

        for sample in batch {
            if !started {
                // The track's format comes from the first encoded frame (includes the layer info).
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                               sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                guard writer.startWriting() else {
                    throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?")
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                self.input = input
                started = true
            }
            while !input!.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard input!.append(sample) else {
                throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?")
            }
        }
    }
}

/// Encoder output is delivered on VideoToolbox's thread; collected here and written from the caller's.
private final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr

    func add(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.withLock {
            if status != noErr { failure = status } else if let sample { frames.append(sample) }
        }
    }

    func take() -> ([CMSampleBuffer], OSStatus) {
        lock.withLock {
            defer { frames.removeAll() }
            return (frames, failure)
        }
    }
}
