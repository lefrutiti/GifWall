import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum MediaConverterError: LocalizedError {
    case unsupported
    case empty
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Формат не поддерживается"
        case .empty: return "В файле нет кадров"
        case .writerFailed(let msg): return "Ошибка кодирования: \(msg)"
        }
    }
}

/// Converts videos and animated images into HEVC videos (hardware decoded, low CPU playback).
/// Output keeps the source aspect ratio; the player aspect-fills it on screen.
enum MediaConverter {
    typealias Progress = @Sendable (Double) -> Void

    struct Result {
        /// Source size in pixels, after rotation.
        let sourceSize: CGSize
        /// How much the source has to be stretched to cover the screen; above ~2 it looks soft.
        let upscale: Double
    }

    /// Longest output side. 4K-class sources are kept as is, bigger ones are downscaled.
    static let maxSide: CGFloat = 4096

    /// Videos longer than this are trimmed: a wallpaper doesn't need more, and conversion time grows linearly.
    static let maxVideoDuration: Double = 600

    static let heics = UTType("public.heics") ?? .heic
    static let imageTypes: [UTType] = [.gif, .webP, .png, .heic, heics]
    static let allowedTypes: [UTType] = [.movie] + imageTypes

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    /// `screen` is the largest display in pixels.
    @discardableResult
    static func convert(_ src: URL, to out: URL, screen: CGSize, progress: Progress? = nil) async throws -> Result {
        try? FileManager.default.removeItem(at: out)
        let source = isVideo(src)
            ? try await encodeVideo(src, to: out, progress: progress)
            : try await encodeImage(src, to: out, screen: screen, progress: progress)
        let cover = max(screen.width / source.width, screen.height / source.height)
        return Result(sourceSize: source, upscale: Double(cover))
    }

    /// Scales `size` down so its longest side fits `maxSide`, rounded to even numbers (HEVC requirement).
    private static func fitted(_ size: CGSize, scale: CGFloat = 1) -> (Int, Int) {
        let s = min(scale, maxSide / max(size.width, size.height))
        return (max(2, Int((size.width * s).rounded()) & ~1), max(2, Int((size.height * s).rounded()) & ~1))
    }

    // MARK: writer

    private static func makeWriter(_ out: URL, width: Int, height: Int, fps: Double) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Constant quality instead of a fixed bitrate: detailed footage gets the bits it needs.
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return (writer, input)
    }

    private static func finish(_ writer: AVAssetWriter, _ input: AVAssetWriterInput, at end: CMTime) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?")
        }
    }

    private static func waitReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
    }

    // MARK: video

    private static func encodeVideo(_ src: URL, to out: URL, progress: Progress?) async throws -> CGSize {
        let asset = AVURLAsset(url: src)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              try await asset.load(.isReadable) else { throw MediaConverterError.unsupported }
        let (nominalFps, range, natural, transform, formats) = try await track.load(
            .nominalFrameRate, .timeRange, .naturalSize, .preferredTransform, .formatDescriptions)
        let display = natural.applying(transform)
        let sourceSize = CGSize(width: abs(display.width), height: abs(display.height))
        let duration = min(range.duration.seconds, maxVideoDuration)
        guard duration > 0 else { throw MediaConverterError.empty }
        let timeRange = CMTimeRange(start: range.start, duration: CMTime(seconds: duration, preferredTimescale: 600))

        // HEVC that already fits: copy the stream untouched, zero quality loss.
        let isHEVC = formats.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC } ?? false
        if isHEVC && transform.isIdentity && max(sourceSize.width, sourceSize.height) <= maxSide {
            try await copyVideoTrack(track, range: timeRange, to: out)
            progress?(1)
            return sourceSize
        }

        let fps = nominalFps > 0 ? min(Double(nominalFps), 60) : 30
        let (w, h) = fitted(sourceSize)
        let target = CGRect(x: 0, y: 0, width: w, height: h)
        // Source frames arrive with the track's rotation applied; only scale (same aspect, nothing is cropped).
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let e = request.sourceImage.extent
            let image = request.sourceImage
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: target.width / e.width, y: target.height / e.height))
                .cropped(to: target)
            request.finish(with: image, context: nil)
        }
        composition.renderSize = target.size
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw MediaConverterError.writerFailed(reader.error?.localizedDescription ?? "?") }

        let (writer, input) = try makeWriter(out, width: w, height: h, fps: fps)
        guard writer.startWriting() else { throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?") }

        var start: CMTime?
        var last = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if start == nil {
                start = pts
                writer.startSession(atSourceTime: pts)
            }
            try await waitReady(input)
            guard input.append(sample) else { throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?") }
            last = pts
            progress?(min(1, (pts - start!).seconds / duration))
        }
        if reader.status == .failed { throw MediaConverterError.writerFailed(reader.error?.localizedDescription ?? "?") }
        guard start != nil else { throw MediaConverterError.empty }
        try await finish(writer, input, at: last + composition.frameDuration)
        return sourceSize
    }

    /// Video track only (audio dropped), samples copied as is.
    private static func copyVideoTrack(_ track: AVAssetTrack, range: CMTimeRange, to out: URL) async throws {
        let comp = AVMutableComposition()
        guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaConverterError.writerFailed("export")
        }
        try ct.insertTimeRange(range, of: track, at: .zero)
        if #available(macOS 15, *) {
            try await export.export(to: out, as: .mov)
        } else {
            export.outputURL = out
            export.outputFileType = .mov
            await export.export()
            if let error = export.error { throw error }
        }
    }

    // MARK: animated images (GIF, WebP, APNG, HEICS)

    /// Encodes the animation (repeated until at least `minDuration`, so the looper has no visible seams on tiny loops).
    /// Small images are upscaled here with smooth interpolation, enough to cover the screen without further stretching.
    /// Frames are decoded one at a time: a long GIF scaled to 4K would not fit in memory all at once.
    private static func encodeImage(_ src: URL, to out: URL, screen: CGSize,
                                    minDuration: Double = 4, progress: Progress?) async throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw MediaConverterError.unsupported }
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iw = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let ih = props[kCGImagePropertyPixelHeight] as? CGFloat else { throw MediaConverterError.empty }
        let sourceSize = CGSize(width: iw, height: ih)
        let cover = max(screen.width / iw, screen.height / ih)
        let (w, h) = fitted(sourceSize, scale: max(1, cover))
        let delays = (0..<count).map { delay(source, $0) }
        let loopDuration = delays.reduce(0, +)
        let loops = max(1, Int((minDuration / loopDuration).rounded(.up)))
        let fps = min(60, Double(count) / loopDuration)

        let (writer, input) = try makeWriter(out, width: w, height: h, fps: fps)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.startWriting() else { throw MediaConverterError.writerFailed(writer.error?.localizedDescription ?? "?") }
        writer.startSession(atSourceTime: .zero)

        let size = CGSize(width: w, height: h)
        let total = Double(count * loops)
        var t = CMTime.zero
        var written = 0
        for _ in 0..<loops {
            for i in 0..<count {
                guard let image = CGImageSourceCreateImageAtIndex(source, i, nil),
                      let pool = adaptor.pixelBufferPool else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw MediaConverterError.writerFailed("нет буфера") }
                draw(image, into: pb, size: size)
                try await waitReady(input)
                adaptor.append(pb, withPresentationTime: t)
                t = t + CMTime(seconds: delays[i], preferredTimescale: 600)
                written += 1
                progress?(Double(written) / total)
            }
        }
        guard written > 0 else { throw MediaConverterError.empty }
        try await finish(writer, input, at: t)
        return sourceSize
    }

    private static let delayKeys: [(dict: CFString, unclamped: CFString, clamped: CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
    ]

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        var raw = 0.1
        for key in delayKeys {
            guard let dict = props?[key.dict] as? [CFString: Any] else { continue }
            if let v = (dict[key.unclamped] as? Double) ?? (dict[key.clamped] as? Double) { raw = v; break }
        }
        // Browsers treat tiny delays as 100ms; do the same.
        return raw < 0.02 ? 0.1 : raw
    }

    /// Aspect-fill draw into a BGRA pixel buffer, smoothly interpolated.
    private static func draw(_ image: CGImage, into pb: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        ctx.setFillColor(.black)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(size.width / iw, size.height / ih)
        let dw = iw * scale, dh = ih * scale
        ctx.draw(image, in: CGRect(x: (size.width - dw) / 2, y: (size.height - dh) / 2, width: dw, height: dh))
    }

    // MARK: helpers

    static func firstFrame(ofVideo url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: .zero).image
    }

    /// Repeats `src` via edit list (no sample copy) until it lasts at least `duration` seconds.
    /// The new movie header is appended to a copy of `src`, so the file stays self-contained and small.
    static func extend(_ src: URL, to out: URL, duration: Double) async throws {
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: src, to: out)

        let movie = AVMutableMovie(url: out, options: nil)
        guard let track = try await movie.loadTracks(withMediaType: .video).first else { throw MediaConverterError.empty }
        let range = try await track.load(.timeRange)
        let reps = max(1, Int((duration / range.duration.seconds).rounded(.up)))
        var at = range.duration
        for _ in 1..<reps {
            try track.insertTimeRange(range, of: track, at: at, copySampleData: false)
            at = at + range.duration
        }
        try movie.writeHeader(to: out, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    static func writePNG(_ image: CGImage, to url: URL, maxSide: CGFloat? = nil) throws {
        var img = image
        if let maxSide, CGFloat(max(image.width, image.height)) > maxSide {
            let s = maxSide / CGFloat(max(image.width, image.height))
            let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                img = ctx.makeImage() ?? image
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaConverterError.writerFailed("png")
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
