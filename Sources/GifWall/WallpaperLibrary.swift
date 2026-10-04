import AppKit

/// One saved wallpaper: a converted, screen-sized HEVC loop plus a thumbnail.
struct WallpaperItem: Codable, Identifiable, Equatable {
    /// Also the asset id of its Aerial in the macOS wallpaper list.
    let id: String
    var name: String
    let added: Date

    var video: URL { WallpaperLibrary.dir.appendingPathComponent("\(id).mov") }
    var thumbnail: URL { WallpaperLibrary.dir.appendingPathComponent("\(id).png") }
}

/// The user's wallpapers, newest first. Files live in Application Support/GifWall/library.
final class WallpaperLibrary {
    static let dir = AppPaths.support.appendingPathComponent("library", isDirectory: true)
    private static let indexURL = dir.appendingPathComponent("library.json")
    private let fm = FileManager.default

    private(set) var items: [WallpaperItem] = []

    init() {
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([WallpaperItem].self, from: data) {
            // Drop entries whose video went missing.
            items = saved.filter { fm.fileExists(atPath: $0.video.path) }
        }
    }

    /// Moves `video` (a converted file) into the library under `id`.
    @discardableResult
    func add(video: URL, name: String, id: String = SystemWallpaper.newAssetID()) async throws -> WallpaperItem {
        let item = WallpaperItem(id: id, name: name, added: Date())
        try? fm.removeItem(at: item.video)
        try fm.moveItem(at: video, to: item.video)
        try await writeThumbnail(item)
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        save()
        return item
    }

    func remove(_ item: WallpaperItem) {
        try? fm.removeItem(at: item.video)
        try? fm.removeItem(at: item.thumbnail)
        items.removeAll { $0.id == item.id }
        save()
    }

    func rename(_ item: WallpaperItem, to name: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].name = name
        save()
    }

    /// Swaps in a re-encoded video for an existing item (keeps id, name and position).
    func replaceVideo(of item: WallpaperItem, with video: URL) async throws {
        try? fm.removeItem(at: item.video)
        try fm.moveItem(at: video, to: item.video)
        try await writeThumbnail(item)
    }

    private func writeThumbnail(_ item: WallpaperItem) async throws {
        let frame = try await MediaConverter.firstFrame(ofVideo: item.video)
        try MediaConverter.writePNG(frame, to: item.thumbnail, maxSide: 1280)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    // MARK: migration

    /// Versions before the library kept a single `current.mov`; it becomes the first library item.
    /// It keeps the asset id it was registered under, so the current system selection stays valid.
    func migrateLegacy() async {
        let support = AppPaths.support
        let legacy = support.appendingPathComponent("current.mov")
        let defaults = UserDefaults.standard
        if fm.fileExists(atPath: legacy.path) {
            var name = defaults.string(forKey: "gifName") ?? ""
            // Archive picks were stored as "pack.zip › file.mp4".
            if let last = name.components(separatedBy: " › ").last { name = last }
            name = (name as NSString).deletingPathExtension
            _ = try? await add(video: legacy, name: name.isEmpty ? "Обои" : name, id: SystemWallpaper.legacyAssetID)
        }
        // Leftovers of the single-video lock screen modes.
        for file in (try? fm.contentsOfDirectory(atPath: support.path)) ?? []
        where file == "still.png" || file.hasPrefix("still-") || file == "lock.mov" || file == "incoming.mov" {
            try? fm.removeItem(at: support.appendingPathComponent(file))
        }
        defaults.removeObject(forKey: "gifName")
        defaults.removeObject(forKey: "lockMode")
    }
}

/// Calls `onChange` (debounced) when files in a directory are created, replaced or removed.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(_ dir: URL, onChange: @escaping () -> Void) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
