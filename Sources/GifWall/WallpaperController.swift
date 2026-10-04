import AppKit
import ServiceManagement
import SwiftUI

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GifWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

@MainActor
final class WallpaperController: ObservableObject {
    /// Master switch for the live desktop. The library stays in System Settings either way.
    @AppStorage("enabled") private var enabledStored = true
    var enabled: Bool {
        get { enabledStored }
        set {
            guard newValue != enabledStored else { return }
            enabledStored = newValue
            objectWillChange.send()
            applyDesktop()
        }
    }

    @Published private(set) var items: [WallpaperItem] = []
    /// Our wallpaper chosen in System Settings (or in the panel); nil when the user picked something else.
    @Published private(set) var selectedID: String?
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double?
    /// Files found in a dropped archive, waiting for the user to pick one.
    @Published private(set) var archiveItems: [URL] = []
    private var archiveName = ""
    @Published var error: String?
    @Published private(set) var warning: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var selected: WallpaperItem? { items.first { $0.id == selectedID } }

    private let library = WallpaperLibrary()
    private let desktop = DesktopWallpaper()
    private var storeWatcher: DirectoryWatcher?
    /// Files queued by a multi-file drop or open panel.
    private var queue: [(url: URL, name: String?)] = []

    static let shared = WallpaperController()

    private init() {
        ArchiveExtractor.cleanup()
        Task {
            await library.migrateLegacy()
            items = library.items
            await SystemWallpaper.sync(items)
            // Picking happens in System Settings: follow the wallpaper store.
            storeWatcher = DirectoryWatcher(SystemWallpaper.storeDir) { [weak self] in self?.refreshSelection() }
            refreshSelection()
            await optimizeExisting()
        }
    }

    // MARK: selection

    /// Reads which wallpaper System Settings shows and plays it (or nothing, if it isn't ours).
    private func refreshSelection() {
        let id = SystemWallpaper.selectedID()
        guard id != selectedID || !desktop.isShowing(selected?.video) else { return }
        selectedID = id
        applyDesktop()
    }

    func select(_ item: WallpaperItem) {
        guard item.id != selectedID else { return }
        error = nil
        selectedID = item.id
        applyDesktop()
        do { try SystemWallpaper.select(item.id) } catch { self.error = error.localizedDescription }
    }

    private func applyDesktop() {
        if enabled, let item = selected { desktop.show(video: item.video) } else { desktop.hide() }
    }

    // MARK: library

    func remove(_ item: WallpaperItem) {
        library.remove(item)
        items = library.items
        if selectedID == item.id {
            selectedID = nil
            applyDesktop()
        }
        Task {
            await SystemWallpaper.sync(items)   // also re-points System Settings if it showed this one
            refreshSelection()
        }
    }

    func rename(_ item: WallpaperItem, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        library.rename(item, to: name)
        items = library.items
        Task { await SystemWallpaper.sync(items) }
    }

    /// Videos added with older versions were kept at full size and frame rate; shrink them once, like new files are.
    private func optimizeExisting() async {
        for item in items where busy == nil {
            guard await MediaConverter.needsOptimizing(item.video, screen: Self.screenSize()) else { continue }
            busy = "Оптимизация…"
            progress = 0
            let tmp = AppPaths.support.appendingPathComponent("incoming.mov")
            do {
                try await MediaConverter.convert(item.video, to: tmp, screen: Self.screenSize()) { value in
                    Task { @MainActor [weak self] in if self?.busy != nil { self?.progress = value } }
                }
                desktop.hide()
                try await library.replaceVideo(of: item, with: tmp)
                SystemWallpaper.invalidate(item.id)
                await SystemWallpaper.sync(items)
                applyDesktop()
            } catch {
                // Not worth bothering the user: the old video keeps working as before.
                try? FileManager.default.removeItem(at: tmp)
            }
            busy = nil
            progress = nil
        }
    }

    // MARK: adding

    func add(_ urls: [URL]) {
        error = nil
        warning = nil
        cancelArchive()
        for url in urls {
            if ArchiveExtractor.isArchive(url) {
                if urls.count == 1 { Task { await openArchive(url) } }
                else { queue.append((url, nil)) }
            } else if MediaConverter.isSupported(url) {
                queue.append((url, nil))
            }
        }
        if queue.isEmpty, archiveItems.isEmpty, busy == nil, urls.count > 0, !urls.contains(where: ArchiveExtractor.isArchive) {
            error = MediaConverterError.unsupported.localizedDescription
        }
        Task { await drainQueue() }
    }

    func addFromArchive(_ urls: [URL]) {
        archiveItems = []
        queue.append(contentsOf: urls.map { ($0, Optional($0.deletingPathExtension().lastPathComponent)) })
        Task {
            await drainQueue()
            ArchiveExtractor.cleanup()
        }
    }

    func cancelArchive() {
        guard !archiveItems.isEmpty else { return }
        archiveItems = []
        ArchiveExtractor.cleanup()
    }

    /// Path relative to the extraction dir, for the archive picker list.
    func archiveLabel(_ url: URL) -> String {
        let root = ArchiveExtractor.dir.resolvingSymlinksInPath().path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.lastPathComponent
    }

    private func openArchive(_ url: URL) async {
        busy = "Распаковка…"
        do {
            let files = try await ArchiveExtractor.extract(url)
            busy = nil
            archiveName = url.lastPathComponent
            if files.count == 1 {
                addFromArchive(files)
            } else {
                archiveItems = files
            }
        } catch {
            busy = nil
            self.error = error.localizedDescription
        }
    }

    /// Converts queued files one by one; the last added becomes the wallpaper.
    private func drainQueue() async {
        guard busy == nil else { return }
        var added: WallpaperItem?
        while !queue.isEmpty {
            let (url, name) = queue.removeFirst()
            if ArchiveExtractor.isArchive(url) {
                // Archives inside a multi-file drop: take every wallpaper in them.
                if let files = try? await ArchiveExtractor.extract(url) {
                    queue.insert(contentsOf: files.map { ($0, Optional($0.deletingPathExtension().lastPathComponent)) }, at: 0)
                }
                continue
            }
            if let item = await convert(url, name: name ?? url.deletingPathExtension().lastPathComponent) {
                added = item
            }
        }
        ArchiveExtractor.cleanup()
        guard let added else { return }
        items = library.items
        busy = "Добавление в Системные настройки…"
        await SystemWallpaper.sync(items)
        busy = nil
        select(added)
    }

    private func convert(_ url: URL, name: String) async -> WallpaperItem? {
        busy = queue.isEmpty ? "Конвертация…" : "Конвертация… (ещё \(queue.count))"
        progress = 0
        defer { busy = nil; progress = nil }
        let tmp = AppPaths.support.appendingPathComponent("incoming.mov")
        do {
            let result = try await MediaConverter.convert(url, to: tmp, screen: Self.screenSize()) { value in
                Task { @MainActor [weak self] in if self?.busy != nil { self?.progress = value } }
            }
            if result.upscale > 2 {
                let s = result.sourceSize
                warning = "\(name): исходник \(Int(s.width))×\(Int(s.height)) растянут в \(Int(result.upscale.rounded()))× — будет размыто"
            }
            let item = try await library.add(video: tmp, name: name)
            items = library.items
            return item
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            self.error = "\(name): \(error.localizedDescription)"
            return nil
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaConverter.allowedTypes + [.zip]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }

    // MARK: app lifecycle

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// On quit only the desktop animation stops; the library stays in System Settings, whose
    /// lock screen and screen saver keep playing it, and the desktop shows the Aerial's still frame.
    func stopDesktop() {
        desktop.hide()
    }

    /// Uninstall: removes the library from System Settings and restores the original wallpaper.
    func removeEverything() async {
        desktop.hide()
        storeWatcher = nil
        await SystemWallpaper.removeAll()
    }

    /// Largest screen in pixels.
    private static func screenSize() -> CGSize {
        let px = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                               height: $0.frame.height * $0.backingScaleFactor) }
        return px.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 2880, height: 1800)
    }
}
