import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct GifWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = WallpaperController.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(controller)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject private var c: WallpaperController
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Живые обои").font(.system(size: 13, weight: .semibold))
                    Text(c.enabled ? "Включены" : "Выключены · стандартные обои")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(c.busy != nil || !c.hasVideo)
            }

            preview
                .opacity(c.enabled ? 1 : 0.45)
                .saturation(c.enabled ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: c.enabled)
            if !c.archiveItems.isEmpty {
                archivePicker
            } else if !c.sourceName.isEmpty {
                Text(c.sourceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(spacing: 10) {
                // Title above the picker: side by side, the three segments leave no room for it.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Экран блокировки").font(.system(size: 13))
                    Picker("", selection: Binding(get: { c.lockMode }, set: { c.lockMode = $0 })) {
                        ForEach(LockMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                row("Запуск при входе") {
                    Toggle("", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            .disabled(c.busy != nil)
            .opacity(c.enabled ? 1 : 0.6)

            if let warning = c.warning, c.error == nil {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = c.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack {
                Button("Выбрать файл…") { c.openPanel() }
                    .buttonStyle(.borderless)
                    .disabled(c.busy != nil)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 300)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if c.hasVideo {
                LoopingVideo(url: AppPaths.video, version: c.videoVersion)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 22, weight: .light))
                    Text("Перетащите видео или GIF")
                        .font(.system(size: 12))
                    Text("MP4 · MOV · GIF · WebP · APNG · ZIP")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            if let busy = c.busy {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45))
                VStack(spacing: 8) {
                    if let p = c.progress, p > 0 {
                        ProgressView(value: p).progressViewStyle(.linear).tint(.white).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(busy).font(.system(size: 11)).foregroundStyle(.white)
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .frame(height: 168)
        .contentShape(Rectangle())
        .onTapGesture { if c.busy == nil { c.openPanel() } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in c.choose(url) }
            }
            return true
        }
    }

    private var archivePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Файлы в архиве")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { c.cancelArchive() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(c.archiveItems, id: \.self) { url in
                        ArchiveRow(title: c.archiveLabel(url), isVideo: MediaConverter.isVideo(url)) {
                            c.chooseFromArchive(url)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            content()
        }
    }
}

struct ArchiveRow: View {
    let title: String
    let isVideo: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isVideo ? "film" : "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Muted looping preview of the converted video.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    let version: Int

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var version = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        required init?(coder: NSCoder) { fatalError() }

        // Play only while the menu bar panel is on screen.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? player.pause() : player.play()
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ v: PlayerView, context: Context) {
        guard v.version != version else { return }
        v.version = version
        v.looper?.disableLooping()
        v.player.removeAllItems()
        v.looper = AVPlayerLooper(player: v.player, templateItem: AVPlayerItem(url: url))
        if v.window != nil { v.player.play() }
    }

    static func dismantleNSView(_ v: PlayerView, coordinator: ()) {
        v.player.pause()
        v.looper?.disableLooping()
        v.player.removeAllItems()
    }
}

/// Leaves the system as if GifWall had never run: on quit (menu, ⌘Q, logout, shutdown) the original
/// wallpaper is restored before the process exits. The next launch applies the live wallpaper again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var replied = false
    private var uninstallWatcher: UninstallWatcher?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        uninstallWatcher = UninstallWatcher()
        uninstallWatcher?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await WallpaperController.shared.restoreSystem()
            self.reply(sender)
        }
        // Never hold up logout/shutdown; whatever didn't finish is completed on the next launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.reply(sender) }
        return .terminateLater
    }

    private func reply(_ sender: NSApplication) {
        guard !replied else { return }
        replied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
