import Foundation
import UniformTypeIdentifiers

enum ArchiveError: LocalizedError {
    case extractFailed
    case tooLarge
    case noMedia
    case wallpaperEngine(String)

    var errorDescription: String? {
        switch self {
        case .extractFailed: return "Не удалось распаковать архив"
        case .tooLarge: return "Архив слишком большой"
        case .noMedia: return "В архиве нет подходящих файлов"
        case .wallpaperEngine(let type):
            return "Это обои Wallpaper Engine типа «\(type)»: они рисуются движком WE и не являются видео. Подходят только обои типа «video»."
        }
    }
}

/// Unpacks ZIP archives and finds wallpaper files inside.
enum ArchiveExtractor {
    /// Guards against zip bombs: real wallpaper packs are far smaller.
    static let maxUncompressedBytes: Int64 = 4 << 30

    static let dir = AppPaths.support.appendingPathComponent("archive", isDirectory: true)

    static func isArchive(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .zip) ?? false
    }

    /// Extracts `zip` into a fresh temp dir and returns supported files: videos first, then larger files first.
    static func extract(_ zip: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            if let size = uncompressedSize(zip), size > maxUncompressedBytes { throw ArchiveError.tooLarge }

            cleanup()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // ditto handles macOS-made archives (UTF-8 names, resource forks) better than unzip.
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) != nil else {
                cleanup()
                throw ArchiveError.extractFailed
            }

            do {
                let files = try wallpaperEngineFiles(in: dir) ?? mediaFiles(in: dir)
                guard !files.isEmpty else { throw ArchiveError.noMedia }
                return files
            } catch {
                cleanup()
                throw error
            }
        }.value
    }

    static func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Wallpaper Engine projects ship a `project.json`; its "file" is the real wallpaper and "preview" a tiny thumbnail.
    /// Returns nil when the archive is not a WE project.
    private static func wallpaperEngineFiles(in root: URL) throws -> [URL]? {
        let projects = files(in: root).filter { $0.lastPathComponent.lowercased() == "project.json" }
        guard !projects.isEmpty else { return nil }
        var found: [URL] = []
        var rejectedType: String?
        for project in projects {
            guard let data = try? Data(contentsOf: project),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = (json["type"] as? String)?.lowercased() ?? ""
            let dir = project.deletingLastPathComponent()
            if type == "video", let file = json["file"] as? String {
                let url = dir.appendingPathComponent(file).standardizedFileURL
                if isInside(url, root), FileManager.default.fileExists(atPath: url.path), MediaConverter.isSupported(url) {
                    found.append(url)
                }
            } else if !type.isEmpty {
                rejectedType = type
            }
        }
        if found.isEmpty, let rejectedType { throw ArchiveError.wallpaperEngine(rejectedType) }
        return found.isEmpty ? nil : found
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
    }

    private static func files(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in e {
            if url.lastPathComponent == "__MACOSX" { e.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { result.append(url) }
        }
        return result
    }

    private static func mediaFiles(in root: URL) -> [URL] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(url: URL, size: Int, video: Bool)] = []
        for case let url as URL in e {
            if url.lastPathComponent == "__MACOSX" { e.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, MediaConverter.isSupported(url) else { continue }
            // Catalog thumbnails ("preview.gif", "thumbnail.webp"…), never the actual wallpaper.
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if ["preview", "thumbnail", "thumb"].contains(stem) { continue }
            // Ignore anything that resolves outside the extraction dir (symlinks, "../" entries).
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            found.append((resolved, values?.fileSize ?? 0, MediaConverter.isVideo(resolved)))
        }
        return found
            .sorted { $0.video != $1.video ? $0.video : $0.size > $1.size }
            .map(\.url)
    }

    /// Sum of uncompressed sizes from the zip directory, without extracting.
    private static func uncompressedSize(_ zip: URL) -> Int64? {
        // Last line of `zipinfo -t`: "N files, X bytes uncompressed, Y bytes compressed: Z%"
        guard let out = run("/usr/bin/zipinfo", ["-t", zip.path]),
              let marker = out.range(of: " bytes uncompressed") else { return nil }
        let digits = out[..<marker.lowerBound].reversed().prefix { $0.isNumber }
        return Int64(String(digits.reversed()))
    }

    /// Runs a tool and returns its stdout, or nil on non-zero exit.
    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
