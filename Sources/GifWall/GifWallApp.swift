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
    @State private var renaming: WallpaperItem?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Живые обои").font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { c.enabled }, set: { c.enabled = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            preview
                .opacity(c.enabled ? 1 : 0.45)
                .saturation(c.enabled ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: c.enabled)

            if !c.archiveItems.isEmpty {
                archivePicker
            } else if !c.items.isEmpty {
                library
            }

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

            row("Запуск при входе") {
                Toggle("", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                Button("Добавить…") { c.openPanel() }
                    .disabled(c.busy != nil)
                Button("Системные настройки") { c.openSystemSettings() }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 320)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .sheet(item: $renaming) { item in renameSheet(item) }
    }

    private var subtitle: String {
        if !c.enabled { return "Выключены" }
        if let item = c.selected { return item.name }
        return c.items.isEmpty ? "Добавьте видео или GIF" : "Выберите обои ниже или в Системных настройках"
    }

    // MARK: preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if let item = c.selected {
                LoopingVideo(url: item.video)
                    .id(item.id)
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
        .onTapGesture { if c.busy == nil && c.items.isEmpty { c.openPanel() } }
    }

    // MARK: library

    private var library: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Мои обои · \(c.items.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(c.items) { item in
                        LibraryTile(item: item, selected: item.id == c.selectedID) { c.select(item) }
                            .contextMenu {
                                Button("Переименовать…") { newName = item.name; renaming = item }
                                Button("Удалить", role: .destructive) { c.remove(item) }
                            }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(c.busy != nil)
    }

    private func renameSheet(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Название обоев").font(.system(size: 13, weight: .semibold))
            TextField("", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(item) }
            HStack {
                Spacer()
                Button("Отмена") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { commitRename(item) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func commitRename(_ item: WallpaperItem) {
        c.rename(item, to: newName)
        renaming = nil
    }

    // MARK: archive

    private var archivePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Файлы в архиве")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Добавить все") { c.addFromArchive(c.archiveItems) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Отмена") { c.cancelArchive() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(c.archiveItems, id: \.self) { url in
                        ArchiveRow(title: c.archiveLabel(url), isVideo: MediaConverter.isVideo(url)) {
                            c.addFromArchive([url])
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { c.add(urls) }
        return true
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            content()
        }
    }
}

struct LibraryTile: View {
    let item: WallpaperItem
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let image = NSImage(contentsOf: item.thumbnail) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.25 : 0.08),
                                          lineWidth: selected ? 2 : 1)
                    }
                Text(item.name)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.name)
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

/// Muted looping preview of a library video.
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        required init?(coder: NSCoder) { fatalError() }

        // Play only while the menu bar panel is on screen.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? player.pause() : player.play()
        }
    }

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }

    func updateNSView(_ v: PlayerView, context: Context) {}

    static func dismantleNSView(_ v: PlayerView, coordinator: ()) {
        v.player.pause()
        v.looper?.disableLooping()
        v.player.removeAllItems()
    }
}

/// On quit only the live desktop stops: the library stays in System Settings (lock screen and screen saver
/// keep playing it). Everything is removed from the system only on uninstall, see UninstallWatcher.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var uninstallWatcher: UninstallWatcher?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        uninstallWatcher = UninstallWatcher()
        uninstallWatcher?.start()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        WallpaperController.shared.stopDesktop()
    }

    /// Files dropped on the app icon or opened with GifWall from Finder go into the library.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        WallpaperController.shared.add(urls)
    }
}
