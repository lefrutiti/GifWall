import AppKit
import ServiceManagement

/// macOS has no uninstall hook. While GifWall runs it watches its own bundle: when the app is moved to the Trash
/// or deleted, it removes its wallpapers from System Settings, restores the original wallpaper, deletes its
/// data, settings and login item, and quits. (When it isn't running, uninstall.sh does the same.)
@MainActor
final class UninstallWatcher {
    private let bundleURL = Bundle.main.bundleURL
    private var source: DispatchSourceFileSystemObject?

    func start() {
        let fd = open(bundleURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .revoke], queue: .main)
        src.setEventHandler { [weak self] in self?.bundleChanged() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func bundleChanged() {
        source?.cancel()
        source = nil
        Task {
            // Updates (build.sh, copying a new version over) also remove the bundle, but put one back in place.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if FileManager.default.fileExists(atPath: bundleURL.path) { return }
            await uninstall()
        }
    }

    private func uninstall() async {
        await WallpaperController.shared.removeEverything()
        try? await SMAppService.mainApp.unregister()
        try? FileManager.default.removeItem(at: AppPaths.support)
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
        // Not NSApp.terminate: the quit path would run again and could write settings back.
        exit(0)
    }
}
