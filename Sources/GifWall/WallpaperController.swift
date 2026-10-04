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
    static let video = support.appendingPathComponent("current.mov")
    static let still = support.appendingPathComponent("still.png")
}

enum LockMode: String, CaseIterable, Identifiable {
    case off, still, animated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Нет"
        case .still: return "Кадр"
        case .animated: return "Анимация"
        }
    }
}

@MainActor
final class WallpaperController: ObservableObject {
    /// Master switch. Off: animation stops and the user's original system wallpaper comes back;
    /// the chosen file and the other settings are kept for when it's turned on again.
    @AppStorage("enabled") private var enabledStored = true
    var enabled: Bool {
        get { enabledStored }
        set {
            guard newValue != enabledStored else { return }
            enabledStored = newValue
            objectWillChange.send()
            Task { await applyEnabled() }
        }
    }
    @AppStorage("lockMode") private var lockModeRaw = LockMode.still.rawValue
    @AppStorage("gifName") private(set) var sourceName = ""

    /// Bumped whenever the video is replaced, so the preview player reloads.
    @Published private(set) var videoVersion = 0
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double?
    /// Files found in a dropped archive, waiting for the user to pick one.
    @Published private(set) var archiveItems: [URL] = []
    private var archiveName = ""
    @Published var error: String?
    @Published private(set) var warning: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var lockMode: LockMode {
        get { LockMode(rawValue: lockModeRaw) ?? .still }
        set {
            let old = lockMode
            lockModeRaw = newValue.rawValue
            objectWillChange.send()
            Task { await applyLock(previous: old) }
        }
    }

    var hasVideo: Bool { FileManager.default.fileExists(atPath: AppPaths.video.path) }

    private let desktop = DesktopWallpaper()

    static let shared = WallpaperController()

    private init() {
        // Pre-video versions kept the source GIF next to the video; it's no longer needed.
        try? FileManager.default.removeItem(at: AppPaths.support.appendingPathComponent("current.gif"))
        ArchiveExtractor.cleanup()
        Task {
            // A crash or force-quit skips the restore on exit; finish it now so we start from the original.
            if LockScreenWallpaper.needsRestore {
                await LockScreenWallpaper.restoreOriginal()
            }
            cleanupStills()
            // System changes are undone on every quit, so they are re-applied on every launch.
            if hasVideo && enabled {
                applyDesktop()
                await applyLock(previous: .off)
            }
        }
    }

    /// Undo everything GifWall changed in the system (on quit). Settings and the chosen file are kept.
    func restoreSystem() async {
        desktop.hide()
        await LockScreenWallpaper.restoreOriginal()
        cleanupStills()
    }

    private func applyEnabled() async {
        error = nil
        applyDesktop()
        if enabled {
            await applyLock(previous: .off)
        } else {
            await LockScreenWallpaper.restoreOriginal()
            cleanupStills()
        }
    }

    func choose(_ url: URL) {
        cancelArchive()
        if ArchiveExtractor.isArchive(url) {
            Task { await openArchive(url) }
            return
        }
        guard MediaConverter.isSupported(url) else {
            error = MediaConverterError.unsupported.localizedDescription
            return
        }
        Task { await load(url) }
    }

    func chooseFromArchive(_ url: URL) {
        let name = "\(archiveName) › \(url.lastPathComponent)"
        archiveItems = []
        Task {
            await load(url, displayName: name)
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
        error = nil
        busy = "Распаковка…"
        do {
            let files = try await ArchiveExtractor.extract(url)
            busy = nil
            archiveName = url.lastPathComponent
            if files.count == 1 {
                chooseFromArchive(files[0])
            } else {
                archiveItems = files
            }
        } catch {
            busy = nil
            self.error = error.localizedDescription
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaConverter.allowedTypes + [.zip]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func load(_ url: URL, displayName: String? = nil) async {
        error = nil
        warning = nil
        busy = "Конвертация…"
        progress = 0
        defer { busy = nil; progress = nil }
        let fm = FileManager.default
        let video = AppPaths.support.appendingPathComponent("incoming.mov")
        do {
            let result = try await MediaConverter.convert(url, to: video, screen: Self.screenSize()) { value in
                Task { @MainActor [weak self] in
                    if self?.busy != nil { self?.progress = value }
                }
            }
            try? fm.removeItem(at: AppPaths.video)
            try fm.moveItem(at: video, to: AppPaths.video)

            sourceName = displayName ?? url.lastPathComponent
            if result.upscale > 2 {
                let s = result.sourceSize
                warning = "Исходник \(Int(s.width))×\(Int(s.height)) растянут в \(Int(result.upscale.rounded()))× — будет размыто"
            }
            videoVersion += 1
            // Picking a new file means the user wants it shown.
            if !enabledStored {
                enabledStored = true
                objectWillChange.send()
            }
            applyDesktop()
            await applyLock(previous: lockMode)
        } catch {
            try? fm.removeItem(at: video)
            self.error = error.localizedDescription
        }
    }

    private func applyDesktop() {
        if enabled && hasVideo { desktop.show(video: AppPaths.video) } else { desktop.hide() }
    }

    private func applyLock(previous: LockMode) async {
        guard hasVideo, enabled else { return }
        error = nil
        // Leaving the Aerial mode: put the system selection back first, the new mode starts from the original.
        if previous == .animated && lockMode != .animated { await LockScreenWallpaper.restoreOriginal() }
        do {
            switch lockMode {
            case .off:
                // The lock screen shows the desktop picture, so "off" means the user's own wallpaper.
                await LockScreenWallpaper.restoreOriginal()
                cleanupStills()
            case .still:
                try await writeStill()
                // Unique name each time: macOS caches desktop pictures by URL.
                let url = AppPaths.support.appendingPathComponent("still-\(Int(Date().timeIntervalSince1970)).png")
                cleanupStills()
                try FileManager.default.copyItem(at: AppPaths.still, to: url)
                try LockScreenWallpaper.setStatic(image: url)
            case .animated:
                guard LockScreenWallpaper.isSupported else {
                    error = "Эта версия macOS не поддерживает анимированный экран блокировки"
                    return
                }
                busy = "Экран блокировки…"
                defer { busy = nil }
                let long = AppPaths.support.appendingPathComponent("lock.mov")
                try await MediaConverter.extend(AppPaths.video, to: long, duration: 3600)
                let frame = try await MediaConverter.firstFrame(ofVideo: AppPaths.video)
                try LockScreenWallpaper.setAnimated(video: long, thumbnail: frame)
                try? FileManager.default.removeItem(at: long)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func writeStill() async throws {
        let frame = try await MediaConverter.firstFrame(ofVideo: AppPaths.video)
        try MediaConverter.writePNG(frame, to: AppPaths.still)
    }

    private func cleanupStills() {
        let items = (try? FileManager.default.contentsOfDirectory(at: AppPaths.support, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("still-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Largest screen in pixels.
    private static func screenSize() -> CGSize {
        let px = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                               height: $0.frame.height * $0.backingScaleFactor) }
        return px.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 2880, height: 1800)
    }
}
