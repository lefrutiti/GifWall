import AppKit

/// The library inside System Settings → Wallpaper. Every saved wallpaper is registered as an Aerial in a
/// "GifWall" category, so it can be picked there like Apple's own; the lock screen and screen saver then
/// play it natively. The desktop itself is drawn by GifWall (Aerials only animate on the lock screen).
/// Undocumented storage, may break with OS updates.
enum SystemWallpaper {
    static let categoryID = "6F000000-0000-4000-8000-000000000001"
    static let subcategoryID = "6F000000-0000-4000-8000-000000000002"
    /// Asset id of the single wallpaper of pre-library versions; kept for that item so its selection survives.
    static let legacyAssetID = "6F000000-0000-4000-8000-000000000010"
    private static let assetPrefix = "6F000000-0000-4000-8000-"

    /// Our asset ids share a prefix: recognizable in the store and manifest, no clash with Apple or other apps.
    static func newAssetID() -> String {
        assetPrefix + String(format: "%012llX", UInt64.random(in: 0x100...0xFFFF_FFFF_FFFF))
    }

    static func isOurs(assetID: String) -> Bool { assetID.hasPrefix(assetPrefix) && assetID != categoryID && assetID != subcategoryID }

    /// Aerials repeat their file until the lock screen goes dark; one loop is enough, but very short
    /// loops make the system re-open the file often. Edit-list repeats keep it tiny on disk.
    private static let aerialDuration: Double = 600

    private static let fm = FileManager.default
    private static var wallpaperDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    }
    private static var aerialsDir: URL { wallpaperDir.appendingPathComponent("aerials") }
    private static var manifestURL: URL { aerialsDir.appendingPathComponent("manifest/entries.json") }
    static var storeDir: URL { wallpaperDir.appendingPathComponent("Store") }
    private static var indexURL: URL { storeDir.appendingPathComponent("Index.plist") }
    private static func videoURL(_ id: String) -> URL { aerialsDir.appendingPathComponent("videos/\(id).mov") }
    private static func thumbURL(_ id: String) -> URL { aerialsDir.appendingPathComponent("thumbnails/\(id).png") }

    static var isSupported: Bool { fm.fileExists(atPath: manifestURL.path) && fm.fileExists(atPath: indexURL.path) }

    // MARK: library ↔ System Settings

    /// Makes the System Settings list match the library: adds missing items, removes deleted ones.
    /// Returns whether the agent was restarted.
    @discardableResult
    static func sync(_ items: [WallpaperItem]) async -> Bool {
        guard isSupported else { return false }
        try? fm.createDirectory(at: videoURL("x").deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbURL("x").deletingLastPathComponent(), withIntermediateDirectories: true)

        var changed = false
        let wanted = Set(items.map(\.id))
        for item in items where !fm.fileExists(atPath: videoURL(item.id).path) {
            try? await MediaConverter.extend(item.video, to: videoURL(item.id), duration: aerialDuration)
            changed = true
        }
        for item in items {
            // Thumbnails change when a video is re-encoded; cheap to keep in step.
            if !fm.contentsEqual(atPath: item.thumbnail.path, andPath: thumbURL(item.id).path) {
                try? fm.removeItem(at: thumbURL(item.id))
                try? fm.copyItem(at: item.thumbnail, to: thumbURL(item.id))
            }
        }
        for id in registeredFiles() where !wanted.contains(id) {
            try? fm.removeItem(at: videoURL(id))
            try? fm.removeItem(at: thumbURL(id))
            changed = true
        }
        if (try? writeManifest(items)) == true { changed = true }

        // A deleted wallpaper may still be selected somewhere; point those slots at the newest one (or the default).
        if let fixed = storeReplacingMissing(with: items.first?.id) {
            try? writeStore(fixed)
            return true
        }
        if changed { restartWallpaperAgent() }
        return changed
    }

    /// The Aerial video currently registered for `id` (needed when re-encoding replaces the library file).
    static func invalidate(_ id: String) {
        try? fm.removeItem(at: videoURL(id))
    }

    private static func registeredFiles() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: videoURL("x").deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasSuffix(".mov") }.map { String($0.dropLast(4)) }.filter(isOurs(assetID:))
    }

    /// Writes our category and assets; returns whether the manifest changed.
    private static func writeManifest(_ items: [WallpaperItem]) throws -> Bool {
        var json = try loadManifest()
        let oldAssets = json["assets"] as? [[String: Any]] ?? []
        let oldCats = json["categories"] as? [[String: Any]] ?? []
        let others = oldAssets.filter { !isOurs(assetID: $0["id"] as? String ?? "") }
        let otherCats = oldCats.filter { ($0["id"] as? String) != categoryID }

        let ours: [[String: Any]] = items.enumerated().map { index, item in [
            "id": item.id,
            "accessibilityLabel": item.name,
            "localizedNameKey": item.name,
            "shotID": "GIFWALL_\(item.id.suffix(12))",
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "includeInShuffle": true,
            "showInTopLevel": true,
            "preferredOrder": index,
            "pointsOfInterest": [String: String](),
            "previewImage": thumbURL(item.id).absoluteString,
            "url-4K-SDR-240FPS": videoURL(item.id).absoluteString,
        ] }
        var cats = otherCats
        if let first = items.first {
            let thumb = thumbURL(first.id).absoluteString
            cats.insert([
                "id": categoryID,
                "localizedNameKey": "GifWall",
                "localizedDescriptionKey": "GifWall",
                "preferredOrder": 0,
                "previewImage": thumb,
                "representativeAssetID": first.id,
                "subcategories": [[
                    "id": subcategoryID,
                    "localizedNameKey": "GifWall",
                    "localizedDescriptionKey": "GifWall",
                    "preferredOrder": 0,
                    "previewImage": thumb,
                    "representativeAssetID": first.id,
                ]],
            ], at: 0)
        }
        let newAssets = ours + others
        guard !NSArray(array: newAssets).isEqual(to: oldAssets) || !NSArray(array: cats).isEqual(to: oldCats) else { return false }
        json["assets"] = newAssets
        json["categories"] = cats
        try saveManifest(json)
        return true
    }

    // MARK: selection

    /// Our wallpaper picked for the desktop in System Settings (most recently set desktop slot), or nil
    /// when the user chose something that isn't ours.
    static func selectedID() -> String? {
        guard let root = loadStore() else { return nil }
        var latest: (date: Date, id: String?)?
        walkSlots(root) { key, slot in
            guard key == "Desktop" else { return }
            let date = slot["LastSet"] as? Date ?? .distantPast
            if latest == nil || date > latest!.date { latest = (date, assetID(of: slot)) }
        }
        return latest?.id.flatMap { isOurs(assetID: $0) ? $0 : nil }
    }

    /// Selects one of ours for the desktop and screen saver on every display and Space.
    static func select(_ id: String) throws {
        try backupOnce()
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": id], format: .binary, options: 0)
        let content = slotContent(provider: "com.apple.wallpaper.choice.aerials", configuration: config)
        guard let data = try patchStore({ _, _ in content }) else { return }
        try writeStore(data)
    }

    /// Store with every slot that selects a wallpaper of ours that no longer exists pointed at `replacement`
    /// (or the macOS default when there is none), or nil if nothing needs fixing.
    private static func storeReplacingMissing(with replacement: String?) -> Data? {
        let existing = Set(registeredFiles())
        let replacementConfig = replacement.flatMap {
            try? PropertyListSerialization.data(fromPropertyList: ["assetID": $0], format: .binary, options: 0)
        }
        var changed = false
        let data = try? patchStore { key, slot in
            guard let id = assetID(of: slot), isOurs(assetID: id), !existing.contains(id) else { return nil }
            changed = true
            if let replacementConfig { return slotContent(provider: "com.apple.wallpaper.choice.aerials", configuration: replacementConfig) }
            return defaultContent(for: key)
        }
        return changed ? data : nil
    }

    // MARK: original wallpaper (restored only on uninstall)

    static var hasBackup: Bool { fm.fileExists(atPath: backupURL.path) }
    private static var backupURL: URL { AppPaths.support.appendingPathComponent("Index.plist.backup") }
    private static var imagesBackupURL: URL { AppPaths.support.appendingPathComponent("desktop-images.plist") }
    private static let defaultPicture = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")

    /// Saves the current wallpaper once, before GifWall first changes it; later changes keep the original.
    private static func backupOnce() throws {
        guard !hasBackup else { return }
        // A store that already points at our wallpapers isn't the user's original (e.g. older versions).
        if let root = loadStore(), storeSelectsOurs(root) { return }
        var images: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !isInSupport(url) else { continue }
            images[id] = url.path
        }
        (images as NSDictionary).write(to: imagesBackupURL, atomically: true)
        try fm.copyItem(at: indexURL, to: backupURL)
    }

    /// Removes the whole library from System Settings and puts back the wallpaper from before GifWall
    /// (or the macOS default where that's unknown). Used on uninstall.
    static func removeAll() async {
        let saved = NSDictionary(contentsOf: imagesBackupURL) as? [String: String] ?? [:]
        for id in registeredFiles() {
            try? fm.removeItem(at: videoURL(id))
            try? fm.removeItem(at: thumbURL(id))
        }
        if var json = try? loadManifest() {
            json["assets"] = (json["assets"] as? [[String: Any]] ?? []).filter { !isOurs(assetID: $0["id"] as? String ?? "") }
            json["categories"] = (json["categories"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != categoryID }
            try? saveManifest(json)
        }
        if hasBackup, let data = try? Data(contentsOf: backupURL) {
            try? writeStore(data)
        } else if let cleaned = storeReplacingMissing(with: nil) {
            try? writeStore(cleaned)
        } else {
            restartWallpaperAgent()
        }
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: imagesBackupURL)

        // Pictures of ours left on a screen (from older versions) get the saved picture or the default.
        guard NSScreen.screens.contains(where: { isInSupport(NSWorkspace.shared.desktopImageURL(for: $0)) }) else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for screen in NSScreen.screens where isInSupport(NSWorkspace.shared.desktopImageURL(for: screen)) {
            let path = screen.displayID.flatMap { saved[$0] }.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
            try? NSWorkspace.shared.setDesktopImageURL(path.map(URL.init(fileURLWithPath:)) ?? defaultPicture, for: screen, options: [:])
        }
    }

    private static func isInSupport(_ url: URL?) -> Bool {
        url?.resolvingSymlinksInPath().path.hasPrefix(AppPaths.support.resolvingSymlinksInPath().path) ?? false
    }

    // MARK: store

    private static func loadStore() -> [String: Any]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func storeSelectsOurs(_ root: [String: Any]) -> Bool {
        var found = false
        walkSlots(root) { _, slot in if let id = assetID(of: slot), isOurs(assetID: id) { found = true } }
        return found
    }

    private static func assetID(of slot: [String: Any]) -> String? {
        let choice = ((slot["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first
        guard choice?["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let data = choice?["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return config["assetID"] as? String
    }

    /// Visits every Desktop/Idle slot (all displays and Spaces).
    private static func walkSlots(_ any: Any, _ visit: (String, [String: Any]) -> Void) {
        if let dict = any as? [String: Any] {
            for (key, value) in dict {
                if key == "Desktop" || key == "Idle", let slot = value as? [String: Any], slot["Content"] != nil {
                    visit(key, slot)
                } else {
                    walkSlots(value, visit)
                }
            }
        } else if let arr = any as? [Any] {
            arr.forEach { walkSlots($0, visit) }
        }
    }

    private static func slotContent(provider: String, configuration: Data) -> [String: Any] {
        [
            "Choices": [["Provider": provider, "Configuration": configuration, "Files": [Any]()]],
            "EncodedOptionValues": "$null",
            "Shuffle": "$null",
        ]
    }

    /// Desktop: the macOS default picture; screen saver: "default" (the system's own choice).
    private static func defaultContent(for key: String) -> [String: Any] {
        if key == "Desktop", let picture = try? PropertyListSerialization.data(fromPropertyList: [
            "type": "imageFile", "url": ["relative": defaultPicture.absoluteString],
        ], format: .binary, options: 0) {
            return slotContent(provider: "com.apple.wallpaper.choice.image", configuration: picture)
        }
        return slotContent(provider: "default", configuration: Data())
    }

    /// Rewrites slots; `content` returns the slot's new Content, or nil to keep it.
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

    private static func loadManifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func saveManifest(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/com.apple.wallpaper.agent"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
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
