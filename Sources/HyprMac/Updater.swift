import AppKit
import Security

enum UpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable, beta
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
}

/// Keeps HyprMac up to date from its GitHub releases.
///
/// Stable follows normal releases only; Beta also takes pre-releases. An update
/// is downloaded as the release's .zip and installed only if it's signed with
/// the same certificate as the running app, which also keeps the Accessibility
/// permission valid. HyprMac then quits, a small helper swaps the app bundle,
/// and the new version starts with every window back on its workspace.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "TheDoodAbides87/HyprMac"

    struct Release: Equatable {
        let version: String
        let prerelease: Bool
        let zip: URL
        let page: URL
    }

    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var available: Release?

    private var timer: Timer?
    private var cfg: Config { ConfigStore.shared.config }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Checks shortly after launch, then every 6 hours, while automatic checks are on.
    func start() {
        showUpdatedNoticeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { self.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard cfg.autoCheckUpdates else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: - Checking

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        status = "Checking for updates…"
        defer { busy = false }
        do {
            let newest = try await fetchNewest(channel: cfg.updateChannel)
            guard let newest, Self.compare(newest.version, Self.currentVersion) == .orderedDescending else {
                available = nil
                status = "HyprMac \(Self.currentVersion) is up to date."
                if userInitiated { alert("You're up to date", "HyprMac \(Self.currentVersion) is the newest \(cfg.updateChannel.title.lowercased()) version.") }
                return
            }
            available = newest
            status = "HyprMac \(newest.version) is available."
            if cfg.autoInstallUpdates && !userInitiated {
                await install(newest)
            } else {
                offer(newest)
            }
        } catch {
            status = "Couldn't check for updates: \(error.localizedDescription)"
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// The newest release on the channel, from the GitHub API (or a test feed
    /// set with `defaults write dev.hyprmac.HyprMac updateFeedURL <url>`).
    private func fetchNewest(channel: UpdateChannel) async throws -> Release? {
        let feed = UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=30")!
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HyprMac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered with status \(http.statusCode).")
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Item: Decodable {
            let tag_name: String
            let prerelease: Bool
            let draft: Bool
            let html_url: URL
            let assets: [Asset]
        }
        let items = try JSONDecoder().decode([Item].self, from: data)
        let releases: [Release] = items.compactMap { item in
            guard !item.draft, channel == .beta || !item.prerelease,
                  let zip = item.assets.first(where: { $0.name.hasSuffix(".zip") })?.browser_download_url else { return nil }
            let version = item.tag_name.hasPrefix("v") ? String(item.tag_name.dropFirst()) : item.tag_name
            return Release(version: version, prerelease: item.prerelease, zip: zip, page: item.html_url)
        }
        return releases.max { Self.compare($0.version, $1.version) == .orderedAscending }
    }

    /// Compares versions like 1.0.0, 0.5.3-beta: numbers first, and a release
    /// counts as newer than a pre-release of the same number.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> ([Int], String) {
            let v = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            var nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            while nums.count < 3 { nums.append(0) }
            return (nums, parts.count > 1 ? parts[1] : "")
        }
        let (na, pa) = split(a), (nb, pb) = split(b)
        for (x, y) in zip(na, nb) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        if pa == pb { return .orderedSame }
        if pa.isEmpty { return .orderedDescending }
        if pb.isEmpty { return .orderedAscending }
        return pa.compare(pb, options: .numeric)
    }

    // MARK: - Installing

    func install(_ release: Release) async {
        busy = true
        defer { busy = false }
        do {
            let dest = Bundle.main.bundleURL
            let parent = dest.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateError("HyprMac doesn't have permission to replace itself in \(parent.path). Download the update from GitHub instead.")
            }
            status = "Downloading HyprMac \(release.version)…"
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("HyprMac-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, _) = try await URLSession.shared.download(from: release.zip)
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)

            status = "Checking HyprMac \(release.version)…"
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appendingPathComponent("unzipped").path])
            let app = work.appendingPathComponent("unzipped/HyprMac.app")
            try Self.verify(app, version: release.version)

            status = "Installing HyprMac \(release.version)…"
            try launchSwapHelper(newApp: app, dest: dest, work: work)
            UserDefaults.standard.set(release.version, forKey: "updatedTo")
            NSApp.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
            let open = alert("Couldn't install HyprMac \(release.version)", error.localizedDescription, buttons: ["Open Release Page", "OK"])
            if open == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
        }
    }

    /// The download must be HyprMac at the expected version, signed with the
    /// same certificate as this copy. Anything else is refused.
    nonisolated static func verify(_ app: URL, version: String) throws {
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("The download doesn't contain HyprMac.app.") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't HyprMac.")
        }
        guard (info?["CFBundleShortVersionString"] as? String) == version else {
            throw UpdateError("The download is a different version than expected.")
        }
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("This copy of HyprMac isn't signed, so it can't check updates.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The download couldn't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed by the same developer as this copy of HyprMac, so it wasn't installed.")
        }
    }

    /// A small script that waits for HyprMac to quit, swaps in the new app
    /// (putting the old one back if anything fails) and starts it.
    private func launchSwapHelper(newApp: URL, dest: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        DEST='\(dest.path)'
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && ditto '\(newApp.path)' "$DEST"; then
            rm -rf "$DEST.old"
        else
            rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        open "$DEST"
        rm -rf '\(work.path)'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        // Detached, so it keeps running after HyprMac quits.
        try run("/bin/sh", ["-c", "nohup /bin/sh '\(script.path)' >/dev/null 2>&1 &"])
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed.") }
    }

    // MARK: - Messages

    private func offer(_ r: Release) {
        let answer = alert("HyprMac \(r.version) is available",
                           "You have \(Self.currentVersion). HyprMac will restart to install it; your windows stay on their workspaces.",
                           buttons: ["Install and Restart", "Later", "Release Notes"])
        switch answer {
        case .alertFirstButtonReturn: Task { await install(r) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    private func showUpdatedNoticeIfNeeded() {
        guard let v = UserDefaults.standard.string(forKey: "updatedTo") else { return }
        UserDefaults.standard.removeObject(forKey: "updatedTo")
        guard v == Self.currentVersion else { return }
        status = "Updated to HyprMac \(v)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let answer = self.alert("HyprMac was updated to \(v)", "", buttons: ["OK", "What's New"])
            if answer == .alertSecondButtonReturn,
               let url = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(v)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate()
        AX.setBool(AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute, true)
        a.window.level = .floating
        return a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
