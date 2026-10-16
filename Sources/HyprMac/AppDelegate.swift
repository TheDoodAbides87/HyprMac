import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cheatPanel: NSPanel?
    private var launcherPanel: LauncherPanel?
    private let launcher = LauncherModel()
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private let pauseItem = NSMenuItem(title: "Pause Tiling", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()

        let store = ConfigStore.shared
        InputTap.shared.rebuild(store.config)
        store.onApply = { cfg in
            InputTap.shared.rebuild(cfg)
            WindowManager.shared.applyConfig()
        }
        WindowManager.shared.onStatus = { [weak self] in self?.renderStatus() }
        installSignalHandlers()
        renderStatus()

        if AXIsProcessTrusted() {
            boot()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            showSettings(tab: 3)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self.permissionTimer?.invalidate()
                    self.boot()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.restoreAll()
    }

    private func boot() {
        if !InputTap.shared.start() {
            // Right after the permission is granted the tap can still be refused; retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.boot() }
            return
        }
        WindowManager.shared.start()
        renderStatus()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { WindowManager.shared.restoreAll() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Keybindings", action: #selector(openCheatSheet), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "").target = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit HyprMac", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = WindowManager.shared.paused ? .on : .off
    }

    /// Waybar-style workspace indicator: occupied workspaces listed, focused one highlighted.
    func renderStatus() {
        guard let button = statusItem?.button else { return }
        let wm = WindowManager.shared
        if !AXIsProcessTrusted() || !wm.started {
            button.attributedTitle = NSAttributedString(string: "HyprMac ⚠︎")
            return
        }
        if wm.paused {
            button.attributedTitle = NSAttributedString(string: "⏸ HyprMac")
            return
        }
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .heavy)
        for s in wm.workspaceStatus() where s.occupied || s.visible {
            let label = s.n == 10 ? "0" : "\(s.n)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: s.focused ? bold : font,
                .foregroundColor: s.focused ? NSColor.labelColor : (s.visible ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor),
                .underlineStyle: s.focused ? NSUnderlineStyle.single.rawValue : 0,
            ]
            if out.length > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            out.append(NSAttributedString(string: label, attributes: attrs))
        }
        button.attributedTitle = out
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openCheatSheet() { showCheatSheet() }
    @objc private func reloadConfig() { ConfigStore.shared.reload() }
    @objc private func togglePause() { WindowManager.shared.setPaused(!WindowManager.shared.paused) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Windows

    func showSettings(tab: Int = 0) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "HyprMac Settings"
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(store: ConfigStore.shared, tab: tab))
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showLauncher() {
        if let p = launcherPanel, p.isVisible {
            p.close()
            return
        }
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        launcher.reset()
        launcher.onClose = { [weak panel] in panel?.close() }
        let host = NSHostingView(rootView: LauncherView(model: launcher))
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host
        // Centered horizontally, in the upper third of the screen under the mouse.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - 310, y: vf.maxY - vf.height / 4 - 420))
        }
        launcherPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func showCheatSheet() {
        if let p = cheatPanel, p.isVisible {
            p.close()
            return
        }
        let panel = CheatPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.contentView = NSHostingView(rootView: CheatSheetView(config: ConfigStore.shared.config))
        panel.center()
        cheatPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Closes on Esc or when it loses focus, like a Hyprland keybinding overlay.
final class CheatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
}
