import AppKit
import AVFoundation

/// Borderless window per screen, placed at desktop level (below icons), looping the video.
final class DesktopWallpaper {
    private var windows: [WallpaperWindow] = []
    private var videoURL: URL?
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rebuild()
            },
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.setPaused(true) }
            },
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.setPaused(true) }
            },
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.updatePlayback() }
            },
            ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.windows.forEach { $0.updatePlayback() }
            },
        ]
    }

    func show(video: URL) {
        videoURL = video
        rebuild()
    }

    func hide() {
        videoURL = nil
        rebuild()
    }

    private func rebuild() {
        windows.forEach { $0.tearDown() }
        windows = []
        guard let videoURL else { return }
        windows = NSScreen.screens.map { WallpaperWindow(screen: $0, video: videoURL) }
    }
}

private final class WallpaperWindow: NSWindow {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var paused = false

    init(screen: NSScreen, video: URL) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        contentView = view

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: video))

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: self)
        orderFront(nil)
        player.play()
    }

    @objc private func occlusionChanged() { updatePlayback() }

    func setPaused(_ value: Bool) {
        paused = value
        value ? player.pause() : updatePlayback()
    }

    /// Plays only while some part of the desktop is actually visible.
    func updatePlayback() {
        paused = false
        if occlusionState.contains(.visible) { player.play() } else { player.pause() }
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        orderOut(nil)
    }
}
