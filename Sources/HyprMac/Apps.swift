import AppKit

struct AppEntry: Identifiable {
    let url: URL
    let name: String
    let bundleID: String?
    var id: URL { url }
}

/// Installed applications, shared by the launcher and the keybinding app pickers.
@MainActor
enum AppCatalog {
    private static var cache: [AppEntry]?
    private static var icons: [String: NSImage] = [:]

    /// Sorted by name. Pass `refresh` to rescan the disk.
    static func installed(refresh: Bool = false) -> [AppEntry] {
        if let cache, !refresh { return cache }
        let list = scan().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cache = list
        return list
    }

    static func url(for bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        if bundleID.hasPrefix("/") { return URL(fileURLWithPath: bundleID) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String? {
        url(for: bundleID).map { (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension }
    }

    static func icon(for url: URL, size: CGFloat) -> NSImage {
        let key = "\(url.path)@\(size)"
        if let i = icons[key] { return i }
        let src = NSWorkspace.shared.icon(forFile: url.path)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        icons[key] = img
        return img
    }

    /// The first of `ids` that is installed.
    nonisolated static func firstInstalled(_ ids: [String]) -> String? {
        ids.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ url: URL) {
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            let name = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
            out.append(AppEntry(url: url, name: name, bundleID: Bundle(url: url)?.bundleIdentifier))
        }
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if item.lastPathComponent != "Utilities",
                          let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    // Apps one folder down, e.g. /Applications/Adobe Photoshop/Adobe Photoshop.app
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return out
    }
}

/// Default apps for the app shortcuts, picked from what's installed.
enum Apps {
    static var terminal: String {
        AppCatalog.firstInstalled(["com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty",
                                   "com.github.wez.wezterm", "com.googlecode.iterm2"]) ?? "com.apple.Terminal"
    }
    static var browser: String {
        AppCatalog.firstInstalled(["org.chromium.Chromium", "com.google.Chrome", "com.brave.Browser",
                                   "com.microsoft.edgemac"]) ?? "com.apple.Safari"
    }
    static var editor: String {
        AppCatalog.firstInstalled(["dev.zed.Zed", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]) ?? "com.apple.TextEdit"
    }
    static var music: String {
        AppCatalog.firstInstalled(["com.spotify.client"]) ?? "com.apple.Music"
    }
}
