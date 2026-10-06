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

    /// A wallpaper is ambient motion: 30 fps looks the same as 60 and halves decoding and compositing work.
    static let maxFps: Double = 30

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
            ? try await encodeVideo(src, to: out, screen: screen, progress: progress)
            : try await encodeImage(src, to: out, screen: screen, progress: progress)
        let cover = max(screen.width / source.width, screen.height / source.height)
        return Result(sourceSize: source, upscale: Double(cover))
    }

    /// Scales `size` down so its longest side fits `maxSide`, rounded to even numbers (HEVC requirement).
    private static func fitted(_ size: CGSize, scale: CGFloat = 1) -> (Int, Int) {
        let s = min(scale, maxSide / max(size.width, size.height))
        return (max(2, Int((size.width * s).rounded()) & ~1), max(2, Int((size.height * s).rounded()) & ~1))
    }


    // MARK: video

    /// Downscaled to what it takes to cover `screen` (bigger frames are thrown away by the aspect-fill anyway),
    /// at most `maxFps`. Never upscaled: that only costs CPU without adding detail.
    private static func encodeVideo(_ src: URL, to out: URL, screen: CGSize, progress: Progress?) async throws -> CGSize {
        let asset = AVURLAsset(url: src)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              try await asset.load(.isReadable) else { throw MediaConverterError.unsupported }
        let (nominalFps, range, natural, transform) = try await track.load(
            .nominalFrameRate, .timeRange, .naturalSize, .preferredTransform)
        let display = natural.applying(transform)
        let sourceSize = CGSize(width: abs(display.width), height: abs(display.height))
        let duration = min(range.duration.seconds, maxVideoDuration)
        guard duration > 0 else { throw MediaConverterError.empty }
        let timeRange = CMTimeRange(start: range.start, duration: CMTime(seconds: duration, preferredTimescale: 600))

        let fps = nominalFps > 0 ? min(Double(nominalFps), maxFps) : maxFps
        let cover = max(screen.width / sourceSize.width, screen.height / sourceSize.height)
        let (w, h) = fitted(sourceSize, scale: min(1, cover))

        // Always re-encoded, even HEVC that fits: the lock screen needs the temporal layers (see LayeredHEVCWriter).
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

        let writer = try LayeredHEVCWriter(url: out, width: w, height: h, fps: fps)

        var start: CMTime?
        var last = CMTime.zero
        // The reader delivers every source frame regardless of frameDuration; drop the extra ones here.
        let step = 1 / fps
        var next = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if start == nil { start = pts }
            let t = (pts - start!).seconds
            // Small tolerance so 59.94 fps sources keep an even every-other-frame cadence.
            if t + step * 0.25 < next { continue }
            next = max(next + step, t)
            // Rebased to zero: trimmed or edited sources may not start there.
            try await writer.append(pixels, at: pts - start!)
            last = pts - start!
            progress?(min(1, t / duration))
        }
        if reader.status == .failed { throw MediaConverterError.writerFailed(reader.error?.localizedDescription ?? "?") }
        guard start != nil else { throw MediaConverterError.empty }
        try await writer.finish(at: last + composition.frameDuration)
        return sourceSize
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
        let fps = min(maxFps, Double(count) / loopDuration)

        let writer = try LayeredHEVCWriter(url: out, width: w, height: h, fps: fps)
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary, &pool)
        guard let pool else { throw MediaConverterError.writerFailed("нет буфера") }

        let size = CGSize(width: w, height: h)
        let total = Double(count * loops)
        var t = CMTime.zero
        var written = 0
        for _ in 0..<loops {
            for i in 0..<count {
                guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw MediaConverterError.writerFailed("нет буфера") }
                draw(image, into: pb, size: size)
                try await writer.append(pb, at: t)
                t = t + CMTime(seconds: delays[i], preferredTimescale: 600)
                written += 1
                progress?(Double(written) / total)
            }
        }
        guard written > 0 else { throw MediaConverterError.empty }
        try await writer.finish(at: t)
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

    /// Whether a previously converted video is bigger or faster than `convert` would produce today
    /// (files from versions without the screen/fps limits).
    static func needsOptimizing(_ url: URL, screen: CGSize) async -> Bool {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (fps, natural) = try? await track.load(.nominalFrameRate, .naturalSize) else { return false }
        let cover = max(screen.width / natural.width, screen.height / natural.height)
        return Double(fps) > maxFps + 0.5 || cover < 0.9 || !hasTemporalLayers(url)
    }

    /// Whether the file carries HEVC temporal-layer sample groups (`tscl`), which the lock screen needs.
    /// Older versions wrote single-layer streams; those are re-encoded once.
    static func hasTemporalLayers(_ url: URL) -> Bool {
        // The movie header sits at the end of our files; the group type appears in plain text inside it.
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail = min(size, 4 << 20)
        try? fh.seek(toOffset: size - tail)
        guard let data = try? fh.read(upToCount: Int(tail)) else { return false }
        return data.range(of: Data("tscl".utf8)) != nil
    }

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
