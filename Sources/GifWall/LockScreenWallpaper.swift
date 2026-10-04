import AppKit

/// Lock screen handling.
/// - static: first GIF frame becomes the system desktop picture (lock screen shows it).
/// - animated: video is registered as a custom Aerial in the macOS wallpaper manifest and selected
///   for desktop + screen saver; the lock screen then plays it. Undocumented, may break with OS updates.
enum LockScreenWallpaper {
    static let categoryID = "6F000000-0000-4000-8000-000000000001"
    static let subcategoryID = "6F000000-0000-4000-8000-000000000002"
    static let assetID = "6F000000-0000-4000-8000-000000000010"

    private static let fm = FileManager.default
    private static var wallpaperDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    }
    private static var aerialsDir: URL { wallpaperDir.appendingPathComponent("aerials") }
    private static var manifestURL: URL { aerialsDir.appendingPathComponent("manifest/entries.json") }
    private static var indexURL: URL { wallpaperDir.appendingPathComponent("Store/Index.plist") }
    static var videoURL: URL { aerialsDir.appendingPathComponent("videos/\(assetID).mov") }
    static var thumbURL: URL { aerialsDir.appendingPathComponent("thumbnails/\(assetID).png") }

    static var isSupported: Bool { fm.fileExists(atPath: manifestURL.path) && fm.fileExists(atPath: indexURL.path) }

    // MARK: static

    static func setStatic(image: URL) throws {
        try backupOnce()
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        }
    }

    // MARK: animated

    /// `video` must already be the long (edit-list extended) HEVC file.
    static func setAnimated(video: URL, thumbnail: CGImage) throws {
        try fm.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: videoURL)
        try fm.copyItem(at: video, to: videoURL)
        try MediaConverter.writePNG(thumbnail, to: thumbURL, maxSide: 1280)

        try backupOnce()
        try registerInManifest()
        try selectInIndex()   // restarts the agent, which also picks up the manifest
    }

    /// Removes our Aerial from the system list and deletes its files.
    private static func unregister() {
        if var json = try? loadManifest() {
            json["assets"] = (json["assets"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != assetID }
            json["categories"] = (json["categories"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != categoryID }
            try? saveManifest(json)
        }
        try? fm.removeItem(at: videoURL)
        try? fm.removeItem(at: thumbURL)
    }

    // MARK: original wallpaper

    /// Whether GifWall has changed the system wallpaper and holds a copy of the original.
    static var hasBackup: Bool { fm.fileExists(atPath: backupURL.path) }

    /// Something of ours is still in the system (e.g. after a crash): a backup, our Aerial, or one of our stills.
    static var needsRestore: Bool {
        hasBackup || fm.fileExists(atPath: videoURL.path) || storeWithoutOurAerial() != nil
            || NSScreen.screens.contains { isOurs(NSWorkspace.shared.desktopImageURL(for: $0)) }
    }

    /// Puts back the wallpaper the user had before GifWall first changed it, and forgets the backup.
    static func restoreOriginal() async {
        let hadAerial = fm.fileExists(atPath: videoURL.path)
        let saved = NSDictionary(contentsOf: imagesBackupURL) as? [String: String] ?? [:]
        unregister()
        if hasBackup, let data = try? Data(contentsOf: backupURL) {
            // The store holds every wallpaper kind (pictures, Aerials, dynamic) for all displays and Spaces.
            try? writeStore(data)
        } else if let cleaned = storeWithoutOurAerial() {
            // No backup, yet the store still points at our (now deleted) Aerial: fall back to macOS defaults.
            try? writeStore(cleaned)
        } else if hadAerial {
            restartWallpaperAgent()
        }
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: imagesBackupURL)

        // Any screen still showing a GifWall still (e.g. a backup taken after an older version had already
        // replaced the picture) gets its saved picture back, or the macOS default one.
        guard NSScreen.screens.contains(where: { isOurs(NSWorkspace.shared.desktopImageURL(for: $0)) }) else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)   // let the restarted agent load the store first
        for screen in NSScreen.screens where isOurs(NSWorkspace.shared.desktopImageURL(for: screen)) {
            let path = screen.displayID.flatMap { saved[$0] }.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
            let url = path.map(URL.init(fileURLWithPath:)) ?? defaultPicture
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    private static let defaultPicture = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")

    private static func isOurs(_ url: URL?) -> Bool {
        url?.resolvingSymlinksInPath().path.hasPrefix(AppPaths.support.resolvingSymlinksInPath().path) ?? false
    }

    private static var backupURL: URL { AppPaths.support.appendingPathComponent("Index.plist.backup") }
    private static var imagesBackupURL: URL { AppPaths.support.appendingPathComponent("desktop-images.plist") }

    /// Saves the current wallpaper once, before GifWall first changes it; later changes keep the original.
    private static func backupOnce() throws {
        guard !hasBackup else { return }
        var images: [String: String] = [:]
        for screen in NSScreen.screens {
            // Skip our own pictures, e.g. if a crash left one in place.
            guard let id = screen.displayID, let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !isOurs(url) else { continue }
            images[id] = url.path
        }
        (images as NSDictionary).write(to: imagesBackupURL, atomically: true)
        try fm.copyItem(at: indexURL, to: backupURL)
    }

    /// The system may re-download the manifest; re-add our entry if it vanished.
    static func ensureRegistered() {
        guard fm.fileExists(atPath: videoURL.path), let json = try? loadManifest() else { return }
        let assets = json["assets"] as? [[String: Any]] ?? []
        if !assets.contains(where: { ($0["id"] as? String) == assetID }) {
            try? registerInManifest()
            restartWallpaperAgent()
        }
    }

    private static func loadManifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func saveManifest(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func registerInManifest() throws {
        var json = try loadManifest()
        let thumb = thumbURL.absoluteString
        let asset: [String: Any] = [
            "id": assetID,
            "accessibilityLabel": "GifWall",
            "localizedNameKey": "GifWall",
            "shotID": "GIFWALL_000010",
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "includeInShuffle": false,
            "showInTopLevel": true,
            "preferredOrder": 0,
            "pointsOfInterest": [String: String](),
            "previewImage": thumb,
            "url-4K-SDR-240FPS": videoURL.absoluteString,
        ]
        let category: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": "GifWall",
            "localizedDescriptionKey": "GifWall",
            "preferredOrder": 0,
            "previewImage": thumb,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "GifWall",
                "localizedDescriptionKey": "GifWall",
                "preferredOrder": 0,
                "previewImage": thumb,
                "representativeAssetID": assetID,
            ]],
        ]
        var assets = (json["assets"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != assetID }
        assets.insert(asset, at: 0)
        var cats = (json["categories"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != categoryID }
        cats.insert(category, at: 0)
        json["assets"] = assets
        json["categories"] = cats
        try saveManifest(json)
    }

    /// Points every Desktop and Idle choice in the wallpaper store to our Aerial.
    private static func selectInIndex() throws {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let content = slotContent(provider: "com.apple.wallpaper.choice.aerials", configuration: config)
        guard let data = try patchStore({ _, _ in content }) else { return }
        try writeStore(data)
    }

    /// The store with every slot that still selects our Aerial reset to the macOS default, or nil if none does.
    private static func storeWithoutOurAerial() -> Data? {
        let picture = try? PropertyListSerialization.data(fromPropertyList: [
            "type": "imageFile", "url": ["relative": defaultPicture.absoluteString],
        ], format: .binary, options: 0)
        var changed = false
        let data = try? patchStore { key, slot in
            guard selectsOurAerial(slot) else { return nil }
            changed = true
            // Desktop gets the default picture; the screen saver goes back to "default" (the system's own choice).
            return key == "Desktop" && picture != nil
                ? slotContent(provider: "com.apple.wallpaper.choice.image", configuration: picture!)
                : slotContent(provider: "default", configuration: Data())
        }
        return changed ? data : nil
    }

    private static func selectsOurAerial(_ slot: [String: Any]) -> Bool {
        let choices = (slot["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] ?? []
        return choices.contains { choice in
            guard let data = choice["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return config["assetID"] as? String == assetID
        }
    }

    private static func slotContent(provider: String, configuration: Data) -> [String: Any] {
        [
            "Choices": [["Provider": provider, "Configuration": configuration, "Files": [Any]()]],
            "EncodedOptionValues": "$null",
            "Shuffle": "$null",
        ]
    }

    /// Walks every Desktop/Idle slot (all displays and Spaces); `content` returns the slot's new Content, or nil to keep it.
    private static func patchStore(_ content: (_ key: String, _ slot: [String: Any]) -> [String: Any]?) throws -> Data? {
        let data = try Data(contentsOf: indexURL)
        guard let root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil) as? [String: Any]
        else { return nil }
        let now = Date()

        func patch(_ any: Any) -> Any {
            if var dict = any as? [String: Any] {
                for (key, value) in dict {
                    if key == "Desktop" || key == "Idle", var slot = value as? [String: Any], slot["Content"] != nil {
                        if let new = content(key, slot) {
                            slot["Content"] = new
                            slot["LastSet"] = now
                            dict[key] = slot
                        }
                    } else {
                        dict[key] = patch(value)
                    }
                }
                return dict
            }
            if let arr = any as? [Any] { return arr.map(patch) }
            return any
        }
        return try PropertyListSerialization.data(fromPropertyList: patch(root), format: .binary, options: 0)
    }

    // MARK: WallpaperAgent

    private static let agents = ["WallpaperAgent", "WallpaperAerialsExtension"]

    /// Replaces the wallpaper store. WallpaperAgent keeps the selection in memory and saves it on exit,
    /// so it must be fully stopped before the file is written, or it overwrites our change.
    private static func writeStore(_ data: Data) throws {
        stopAgents()
        defer { startAgent() }
        try data.write(to: indexURL, options: .atomic)
    }

    /// Restarts the agent so it reloads the store and the Aerials manifest.
    static func restartWallpaperAgent() {
        stopAgents()
        startAgent()
    }

    private static func stopAgents() {
        // Wait for these exact PIDs: launchd may respawn the agent right away under a new one.
        let pids = agents.flatMap(pids(named:))
        for pid in pids { kill(pid, SIGTERM) }
        // Up to ~2 s for them to save and exit.
        for _ in 0..<40 where pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(50_000)
        }
    }

    /// PIDs by full executable name (`pgrep -x` matches the name truncated to 15 characters).
    private static func pids(named name: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "/\(name)( |$)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").compactMap { pid_t($0) }
    }

    /// launchd starts the agent on demand anyway; kickstart makes the wallpaper reappear right away.
    private static func startAgent() {
        run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.wallpaper.agent"])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

private extension NSScreen {
    /// Stable per-display id (survives reboots and reconnects, unlike the CGDirectDisplayID number).
    var displayID: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
    }
}
