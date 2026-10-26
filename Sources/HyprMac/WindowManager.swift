import AppKit
import ApplicationServices

enum Dir: String { case left, right, up, down }

final class ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    let el: AXUIElement
    let bundleID: String
    var workspace: Int
    var floating = false
    var pseudo = false
    var pseudoSize: CGSize?
    var floatFrame: CGRect?
    var hidden = false
    var lastSet: CGRect?

    init(id: CGWindowID, pid: pid_t, el: AXUIElement, bundleID: String, workspace: Int) {
        self.id = id
        self.pid = pid
        self.el = el
        self.bundleID = bundleID
        self.workspace = workspace
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    let name = notification as String
    MainActor.assumeIsolated { WindowManager.shared.handle(name, element) }
}

/// Tracks every standard window, keeps one dwindle tree per workspace and
/// lays them out. Workspaces 1–10 are emulated (not macOS Spaces): windows on
/// hidden workspaces are parked in the bottom-right corner of the desktop.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    var cfg: Config { ConfigStore.shared.config }
    private(set) var windows: [CGWindowID: ManagedWindow] = [:]
    private(set) var workspaces: [Int: Workspace] = [:]
    private(set) var active: [CGDirectDisplayID: Int] = [:]
    private(set) var monitors: [Monitor] = []
    private(set) var focusedMonitor: CGDirectDisplayID = 0
    private(set) var paused = false
    private(set) var started = false
    var onStatus: (() -> Void)?

    private var previousWorkspace: Int?
    private var observers: [pid_t: AXObserver] = [:]
    private var refreshScheduled = false
    private var focusPending = false
    private var suppressFocusUntil = Date.distantPast
    private var snapWork: [CGWindowID: DispatchWorkItem] = [:]
    private var hoverWork: DispatchWorkItem?
    private var lastScrollSwitch = Date.distantPast
    private var tokens: [NSObjectProtocol] = []
    /// True while the screens are asleep or locked. macOS reports windows and
    /// displays unreliably then, so window tracking is paused.
    private var asleep = false
    private var reassertWork: [DispatchWorkItem] = []
    /// Workspace each display last showed, so it comes back after a reconnect.
    private var lastShown: [CGDirectDisplayID: Int] = [:]

    /// Where a window lived when it left the layout (minimized, app hidden, or
    /// missing from macOS's reports), so it returns to the same workspace.
    /// Forgotten when its app quits.
    private struct Memory {
        let pid: pid_t
        let workspace: Int
        let floating: Bool
        let floatFrame: CGRect?
    }
    private var remembered: [CGWindowID: Memory] = [:]

    /// The screenshot editor (opened by clicking the thumbnail) belongs to this
    /// background process, which HyprMac doesn't otherwise manage.
    private static let screenshotBundle = "com.apple.screencaptureui"
    /// Where to go back to when the screenshot editor closes.
    private var screenshotReturn: (workspace: Int, empty: Int, monitor: CGDirectDisplayID)?
    private var screenshotTimer: Timer?
    private var handledScreenshotEditor: CGWindowID?
    private var timer: Timer?
    private let border = BorderOverlay()

    private struct DragState {
        let w: ManagedWindow
        let resize: Bool
        let start: CGPoint
        let startFrame: CGRect
        var last: CGPoint
        /// For resizing: which edges were grabbed (the ones nearest the pointer).
        let grabRight: Bool
        let grabBottom: Bool
    }
    private var drag: DragState?

    private init() {
        for n in 1...10 { workspaces[n] = Workspace(n) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        reconcileMonitors()
        focusedMonitor = monitors.first?.id ?? 0
        if let front = NSWorkspace.shared.frontmostApplication,
           let wel = AX.element(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute),
           let f = AX.frame(wel),
           let m = monitors.first(where: { $0.frame.contains(f.center) }) {
            focusedMonitor = m.id
        }
        for app in NSWorkspace.shared.runningApplications { observe(app) }

        let wnc = NSWorkspace.shared.notificationCenter
        tokens.append(wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self.observe(app) }
                self.scheduleRefresh(delay: 0.4)
            }
        })
        tokens.append(wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid {
                    self.observers[pid] = nil
                    self.remembered = self.remembered.filter { $0.value.pid != pid }
                }
                self.scheduleRefresh()
            }
        })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            tokens.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.scheduleRefresh(focus: true) }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !self.asleep, !self.screenUnavailable else { return }  // handled on wake
                self.reconcileMonitors()
                self.invalidateFrames()
                self.applyAll()
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.goToSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(wnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.wakeUp() }
            })
        }
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.goToSleep() }
        })
        tokens.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.wakeUp() }
        })
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkScreenshotEditor() }
        }
        // Safety net for apps that don't post AX notifications reliably.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }

        started = true
        refresh(initial: true)
        syncFocus()
    }

    // MARK: - Sleep, lock and wake

    /// True while the screen is locked, the session is switched away, or the
    /// display is off. Checked directly, so a background "dark wake" during a
    /// long lock can't be mistaken for the user coming back.
    private var screenUnavailable: Bool {
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
            if (d[kCGSessionOnConsoleKey as String] as? Bool) == false { return true }
        }
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private func goToSleep() {
        asleep = true
        reassertWork.forEach { $0.cancel() }
        reassertWork.removeAll()
        border.hide()
    }

    /// Once the screens are back, re-read the displays and put every window
    /// back where its workspace says, a few times while macOS settles.
    private func wakeUp() {
        guard asleep else { return }
        // Still locked or dark (e.g. a maintenance wake): check again shortly.
        if screenUnavailable {
            reassertWork.forEach { $0.cancel() }
            let retry = DispatchWorkItem { MainActor.assumeIsolated { self.wakeUp() } }
            reassertWork = [retry]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
            return
        }
        asleep = false
        reassertWork.forEach { $0.cancel() }
        reassertWork = [0.5, 1.5, 4].map { delay in
            let item = DispatchWorkItem { MainActor.assumeIsolated { self.reassert() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func reassert() {
        guard started, !paused, !asleep, !screenUnavailable else { return }
        reconcileMonitors()
        let corner = hideCorner
        for w in windows.values where w.hidden { AX.setPosition(w.el, corner) }
        invalidateFrames()
        refresh()
    }

    // MARK: - Screenshot editor

    /// The editor's window, if one is open. macOS starts a new screenshot
    /// process for every capture and never reports it as activating, so the
    /// window itself is what HyprMac looks for. The capture overlay and the
    /// thumbnail belong to the same process but sit on a higher layer or are
    /// much smaller.
    private func findScreenshotEditor() -> (id: CGWindowID, pid: pid_t, frame: CGRect)? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Self.screenshotBundle).map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, (0..<20).contains(layer),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds), r.width >= 400, r.height >= 300,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return (id, pid, r)
        }
        return nil
    }

    /// Runs twice a second: notices the editor opening and closing.
    private func checkScreenshotEditor() {
        guard started, !paused, !asleep else { return }
        let editor = cfg.screenshotWorkspace ? findScreenshotEditor() : nil
        if let editor {
            // Act once per editor window, so switching away while it's open sticks.
            guard editor.id != handledScreenshotEditor else { return }
            handledScreenshotEditor = editor.id
            openScreenshotWorkspace(editor.pid, editor: editor.frame)
        } else if handledScreenshotEditor != nil {
            handledScreenshotEditor = nil
            screenshotEditorClosed()
        }
    }

    /// Clear the editor's display by switching to an empty workspace. The editor
    /// isn't tiled, so it stays put while the tiles are parked.
    private func openScreenshotWorkspace(_ pid: pid_t, editor r: CGRect) {
        let m = monitors.first { $0.frame.contains(r.center) }?.id ?? focusedMonitor
        let current = activeWorkspace(on: m)
        guard !windows(in: current).isEmpty,  // already on an empty one
              let empty = (1...10).first(where: { windows(in: $0).isEmpty && monitorShowing($0) == nil }) else { return }
        screenshotReturn = (current, empty, m)
        focusedMonitor = m
        switchTo(empty, focus: false)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// When the editor closes, go back, but only if you're still on that
    /// workspace and haven't opened anything there.
    private func screenshotEditorClosed() {
        guard let ret = screenshotReturn else { return }
        screenshotReturn = nil
        guard activeWorkspace(on: ret.monitor) == ret.empty, windows(in: ret.empty).isEmpty else { return }
        focusedMonitor = ret.monitor
        switchTo(ret.workspace)
    }

    /// Bring every parked window back on screen (used on quit and pause).
    func restoreAll() {
        guard let main = monitors.first else { return }
        var offset: CGFloat = 0
        for w in windows.values where w.hidden {
            let m = monitorShowing(w.workspace).flatMap(monitor) ?? main
            var f = w.floatFrame ?? CGRect(x: 0, y: 0, width: m.visible.width * 0.6, height: m.visible.height * 0.6)
            if !m.frame.contains(f.center) {
                f.origin = CGPoint(x: m.visible.minX + 40 + offset, y: m.visible.minY + 40 + offset)
                offset = (offset + 30).truncatingRemainder(dividingBy: 300)
            }
            AX.setFrame(w.el, f)
            w.hidden = false
        }
    }

    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        if p {
            restoreAll()
            border.hide()
            windows.removeAll()
            for ws in workspaces.values {
                ws.root = nil
                ws.focused = nil
                ws.fullscreen = nil
            }
        } else {
            refresh(initial: true)
            syncFocus()
        }
        onStatus?()
    }

    func applyConfig() {
        guard started, !paused else { return }
        invalidateFrames()
        applyAll()
    }

    // MARK: - Observation

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var ok = false
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            if AXObserverAddNotification(obs, appEl, n as CFString, nil) == .success { ok = true }
        }
        guard ok else { return }  // app not ready yet; retried on next refresh
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    func handle(_ notification: String, _ el: AXUIElement) {
        guard started, !paused else { return }
        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            geometryChanged(el)
        case kAXFocusedWindowChangedNotification:
            scheduleRefresh(focus: true)
        case kAXWindowCreatedNotification:
            scheduleRefresh(delay: 0.05)
            scheduleRefresh(delay: 0.5, focus: true)
        default:
            scheduleRefresh()
        }
    }

    private func scheduleRefresh(delay: Double = 0.03, focus: Bool = false) {
        if focus { focusPending = true }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.refreshScheduled = false
            self.refresh()
        }
    }

    // MARK: - Window discovery

    private func refresh(initial: Bool = false) {
        guard started, !paused, !asleep else { return }
        if screenUnavailable {
            // Locked or dark without a sleep notification: hold still until it's back.
            goToSleep()
            wakeUp()
            return
        }
        var seen = Set<CGWindowID>()
        let ignore = Set(cfg.ignoreApps)
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            if observers[pid] == nil { observe(app) }
            if app.isHidden { continue }
            let bundle = app.bundleIdentifier ?? ""
            if ignore.contains(bundle) { continue }
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.5)
            for el in AX.elements(appEl, kAXWindowsAttribute) {
                guard let id = AX.windowID(el) else { continue }
                if windows[id] != nil {
                    if AX.bool(el, kAXMinimizedAttribute) != true { seen.insert(id) }
                    continue
                }
                guard isManageable(el) else { continue }
                seen.insert(id)
                add(el, id: id, pid: pid, bundle: bundle, initial: initial)
            }
        }
        for (id, w) in windows where !seen.contains(id) {
            switch disappearance(of: w) {
            case .transient: continue
            case .parked, .closed: remove(id)
            }
        }
        applyAll()
        if focusPending {
            focusPending = false
            syncFocus()
        }
        onStatus?()
    }

    private func isManageable(_ el: AXUIElement) -> Bool {
        AX.string(el, kAXRoleAttribute) == kAXWindowRole
            && AX.string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole
            && AX.bool(el, kAXMinimizedAttribute) != true
    }

    private func shouldFloat(_ el: AXUIElement, bundle: String) -> Bool {
        if cfg.floatApps.contains(bundle) { return true }
        if !AX.settable(el, kAXSizeAttribute) { return true }
        // Fixed-size windows (About boxes, inspectors…) have a disabled zoom button.
        if let zoom = AX.element(el, kAXZoomButtonAttribute), AX.bool(zoom, kAXEnabledAttribute) == false { return true }
        return false
    }

    private func add(_ el: AXUIElement, id: CGWindowID, pid: pid_t, bundle: String, initial: Bool) {
        let frame = AX.frame(el) ?? .zero
        var n = activeWorkspace(on: focusedMonitor)
        if initial, let m = monitors.first(where: { $0.frame.contains(frame.center) }), let a = active[m.id] {
            n = a
        }
        let memory = remembered.removeValue(forKey: id)
        if let memory { n = memory.workspace }
        let ws = workspaces[n]!
        let w = ManagedWindow(id: id, pid: pid, el: el, bundleID: bundle, workspace: n)
        w.floating = memory?.floating ?? shouldFloat(el, bundle: bundle)
        if w.floating {
            w.floatFrame = memory?.floatFrame ?? frame
        } else {
            Dwindle.insert(ws, id, near: initial ? nil : ws.focused)
        }
        windows[id] = w
        if let obs = observers[pid] {
            for note in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverAddNotification(obs, el, note as CFString, nil)
            }
        }
        if monitorShowing(n) == nil { hide(w) }
    }

    private enum Disappearance { case transient, parked, closed }

    /// Why a tracked window was missing from its app's window list. Only a
    /// window that no longer exists counts as closed; minimized windows and
    /// hidden apps are parked and remembered; anything else is a hiccup
    /// (an app busy or not answering) and the window is kept as it is.
    private func disappearance(of w: ManagedWindow) -> Disappearance {
        guard let app = NSRunningApplication(processIdentifier: w.pid), !app.isTerminated else { return .closed }
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(w.el, kAXRoleAttribute as CFString, &role)
        if err == .invalidUIElement { return .closed }
        if app.isHidden || cfg.ignoreApps.contains(w.bundleID) { return .parked }
        if AX.bool(w.el, kAXMinimizedAttribute) == true { return .parked }
        // Gone from the window server means closed, however the app answered.
        guard windowServerHas(w.id) else { return .closed }
        // Still exists but left the app's list (e.g. moved to another macOS Space).
        return err == .success ? .parked : .transient
    }

    private func windowServerHas(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return !list.isEmpty
    }

    private func remove(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id), let ws = workspaces[w.workspace] else { return }
        // Always remember, even for windows that look closed: if macOS was only
        // misreporting, the same window ID comes back and returns to its workspace.
        // Window IDs aren't reused, and entries are dropped when the app quits.
        let floatFrame = w.floating ? (w.hidden ? w.floatFrame : AX.frame(w.el) ?? w.floatFrame) : nil
        remembered[id] = Memory(pid: w.pid, workspace: w.workspace, floating: w.floating, floatFrame: floatFrame)
        snapWork.removeValue(forKey: id)?.cancel()
        Dwindle.remove(ws, id)
        if ws.fullscreen == id { ws.fullscreen = nil }
        if ws.focused == id {
            ws.focused = nil
            // macOS would hand focus to another window of the same app, possibly on a
            // hidden workspace. Keep focus inside this workspace instead, like Hyprland.
            if monitorShowing(ws.n) != nil {
                suppressFocus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.focusWorkspace(ws.n) }
            }
        }
    }

    // MARK: - Monitors & workspaces

    private func reconcileMonitors() {
        let current = Monitor.current()
        guard !current.isEmpty else { return }  // displays asleep or mid-reconfiguration
        monitors = current
        let ids = Set(monitors.map(\.id))
        for (m, n) in active where !ids.contains(m) {
            // Keep the workspace's display so it returns there when reconnected.
            active[m] = nil
            hide(workspace: n)
        }
        for m in monitors where active[m.id] == nil {
            let used = Set(active.values)
            let free = (1...10).filter { !used.contains($0) }
            var pick = free.first { workspaces[$0]?.monitor == m.id } ?? free.first { windows(in: $0).isEmpty } ?? free.first ?? 1
            if let last = lastShown[m.id], !used.contains(last) { pick = last }
            active[m.id] = pick
            lastShown[m.id] = pick
            workspaces[pick]?.monitor = m.id
        }
        if !ids.contains(focusedMonitor) { focusedMonitor = monitors.first?.id ?? 0 }
    }

    private func monitor(_ id: CGDirectDisplayID) -> Monitor? { monitors.first { $0.id == id } }
    func monitorShowing(_ n: Int) -> CGDirectDisplayID? { active.first { $0.value == n }?.key }
    func activeWorkspace(on m: CGDirectDisplayID) -> Int { active[m] ?? active.values.min() ?? 1 }
    func windows(in n: Int) -> [ManagedWindow] { windows.values.filter { $0.workspace == n } }

    var focusedWorkspace: Int { activeWorkspace(on: focusedMonitor) }

    /// (number, visible on a monitor, focused, has windows) for the menu-bar indicator.
    func workspaceStatus() -> [(n: Int, visible: Bool, focused: Bool, occupied: Bool)] {
        (1...10).map { n in
            (n, monitorShowing(n) != nil, n == focusedWorkspace, !windows(in: n).isEmpty)
        }
    }

    private var hideCorner: CGPoint {
        let union = monitors.reduce(CGRect.null) { $0.union($1.frame) }
        return CGPoint(x: union.maxX - 1, y: union.maxY - 1)
    }

    private func hide(_ w: ManagedWindow) {
        guard !w.hidden else { return }
        if w.floating, let f = AX.frame(w.el) { w.floatFrame = f }
        w.hidden = true
        w.lastSet = nil
        AX.setPosition(w.el, hideCorner)
    }

    private func hide(workspace n: Int) {
        for w in windows(in: n) { hide(w) }
    }

    private func suppressFocus(_ seconds: Double = 0.4) {
        suppressFocusUntil = Date().addingTimeInterval(seconds)
    }

    func switchTo(_ n: Int, focus: Bool = true) {
        guard (1...10).contains(n) else { return }
        if let m = monitorShowing(n) {
            focusedMonitor = m
            focusWorkspace(n)
            onStatus?()
            return
        }
        let m = focusedMonitor
        suppressFocus()
        if let old = active[m] {
            previousWorkspace = old
            hide(workspace: old)
        }
        active[m] = n
        lastShown[m] = n
        workspaces[n]?.monitor = m
        apply(n)
        if focus { focusWorkspace(n) } else { border.hide() }
        onStatus?()
    }

    private func cycleWorkspace(_ step: Int) {
        let cur = focusedWorkspace
        let candidates = (1...10).filter { $0 == cur || !windows(in: $0).isEmpty }
        guard let i = candidates.firstIndex(of: cur), candidates.count > 1 else { return }
        switchTo(candidates[(i + step + candidates.count) % candidates.count])
    }

    // MARK: - Layout

    private func invalidateFrames() {
        for w in windows.values where !w.hidden { w.lastSet = nil }
    }

    func applyAll() {
        for n in active.values { apply(n) }
        updateBorder()
    }

    private func apply(_ n: Int) {
        guard let ws = workspaces[n] else { return }
        guard let mid = monitorShowing(n), let m = monitor(mid) else { hide(workspace: n); return }
        let vf = m.visible
        let gi = CGFloat(cfg.gapsIn), go = CGFloat(cfg.gapsOut)

        if let root = ws.root {
            Dwindle.layout(root, vf.insetBy(dx: go - gi, dy: go - gi))
            for leaf in root.leaves() {
                guard let id = leaf.win, let w = windows[id] else { continue }
                var r = leaf.rect.insetBy(dx: gi, dy: gi)
                if w.pseudo, let s = w.pseudoSize {
                    let size = CGSize(width: min(s.width, r.width), height: min(s.height, r.height))
                    r = CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
                }
                if ws.fullscreen == id {
                    r = ws.fullscreenMode == .full ? vf : vf.insetBy(dx: go, dy: go)
                }
                setFrame(w, r)
            }
        }
        for w in windows(in: n) where w.floating && (w.hidden || w.lastSet == nil) {
            var f = w.floatFrame ?? CGRect(x: 0, y: 0, width: vf.width * 0.6, height: vf.height * 0.6)
            if !m.frame.contains(f.center) {
                f.origin = CGPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
            }
            w.floatFrame = f
            setFrame(w, f)
        }
        if let fid = ws.fullscreen, let w = windows[fid] { AX.raise(w.el) }
    }

    private func setFrame(_ w: ManagedWindow, _ r: CGRect) {
        let r = r.rounded()
        w.hidden = false
        if w.lastSet == r { return }
        w.lastSet = r
        AX.setFrame(w.el, r)
    }

    private func rect(_ w: ManagedWindow) -> CGRect? {
        w.floating ? (w.floatFrame ?? AX.frame(w.el)) : (w.lastSet ?? AX.frame(w.el))
    }

    private var visibleWindows: [ManagedWindow] {
        let shown = Set(active.values)
        return windows.values.filter { shown.contains($0.workspace) && !$0.hidden }
    }

    // MARK: - Focus

    func focusedWindow() -> ManagedWindow? {
        guard let id = workspaces[focusedWorkspace]?.focused else { return nil }
        return windows[id]
    }

    private func focus(_ w: ManagedWindow) {
        workspaces[w.workspace]?.focused = w.id
        if let m = monitorShowing(w.workspace) { focusedMonitor = m }
        AX.raise(w.el)
        AX.setBool(w.el, kAXMainAttribute, true)
        AX.setBool(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute, true)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        updateBorder(w)
        onStatus?()
    }

    private func focusWorkspace(_ n: Int) {
        guard let ws = workspaces[n] else { return }
        let cand = ws.focused.flatMap { windows[$0] }
            ?? ws.root?.leaves().first.flatMap { $0.win.flatMap { windows[$0] } }
            ?? windows(in: n).first
        if let c = cand {
            focus(c)
        } else {
            // Empty workspace: take focus ourselves so keystrokes don't land in a parked window.
            NSApp.activate(ignoringOtherApps: true)
            border.hide()
        }
    }

    /// Adopt focus changes made outside HyprMac (clicks, ⌘-Tab, Dock).
    private func syncFocus() {
        guard started, !paused else { return }
        guard Date() > suppressFocusUntil else { updateBorder(); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            border.hide()
            return
        }
        guard let wel = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(wel), let w = windows[id] else {
            border.hide()
            return
        }
        if monitorShowing(w.workspace) == nil {
            // Window lives on a hidden workspace (e.g. ⌘-Tab to it): follow it there.
            workspaces[w.workspace]?.focused = id
            let target = workspaces[w.workspace]?.monitor.flatMap { monitor($0) != nil ? $0 : nil } ?? focusedMonitor
            focusedMonitor = target
            switchTo(w.workspace)
        }
        workspaces[w.workspace]?.focused = id
        if let m = monitorShowing(w.workspace) { focusedMonitor = m }
        updateBorder()
        onStatus?()
    }

    private func updateBorder(_ hint: ManagedWindow? = nil) {
        guard cfg.borderEnabled, !paused, let w = hint ?? focusedWindow(), !w.hidden,
              hint != nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid,
              let f = AX.frame(w.el) else {
            border.hide()
            return
        }
        border.show(f, cfg: cfg)
    }

    // MARK: - Directional helpers

    private func neighbor(of r: CGRect, _ d: Dir, among cands: [(ManagedWindow, CGRect)]) -> ManagedWindow? {
        var best: (CGFloat, ManagedWindow)?
        for (w, c) in cands {
            let gap: CGFloat, overlap: CGFloat, drift: CGFloat
            switch d {
            case .left:
                guard c.midX < r.midX, c.maxX <= r.minX + 20 else { continue }
                gap = r.minX - c.maxX; overlap = min(r.maxY, c.maxY) - max(r.minY, c.minY); drift = abs(c.midY - r.midY)
            case .right:
                guard c.midX > r.midX, c.minX >= r.maxX - 20 else { continue }
                gap = c.minX - r.maxX; overlap = min(r.maxY, c.maxY) - max(r.minY, c.minY); drift = abs(c.midY - r.midY)
            case .up:
                guard c.midY < r.midY, c.maxY <= r.minY + 20 else { continue }
                gap = r.minY - c.maxY; overlap = min(r.maxX, c.maxX) - max(r.minX, c.minX); drift = abs(c.midX - r.midX)
            case .down:
                guard c.midY > r.midY, c.minY >= r.maxY - 20 else { continue }
                gap = c.minY - r.maxY; overlap = min(r.maxX, c.maxX) - max(r.minX, c.minX); drift = abs(c.midX - r.midX)
            }
            let score = max(gap, 0) + (overlap > 0 ? 0 : 10_000 - overlap) + drift * 0.01
            if best == nil || score < best!.0 { best = (score, w) }
        }
        return best?.1
    }

    private func monitor(in d: Dir, from m: CGDirectDisplayID) -> Monitor? {
        guard let cur = monitor(m) else { return nil }
        let r = cur.frame
        return monitors.filter { $0.id != m }.min { a, b in
            func score(_ x: Monitor) -> CGFloat {
                let c = x.frame
                switch d {
                case .left: return c.midX < r.midX ? r.minX - c.maxX + abs(c.midY - r.midY) : .infinity
                case .right: return c.midX > r.midX ? c.minX - r.maxX + abs(c.midY - r.midY) : .infinity
                case .up: return c.midY < r.midY ? r.minY - c.maxY + abs(c.midX - r.midX) : .infinity
                case .down: return c.midY > r.midY ? c.minY - r.maxY + abs(c.midX - r.midX) : .infinity
                }
            }
            return score(a) < score(b)
        }.flatMap { m in
            let c = m.frame
            switch d {
            case .left: return c.midX < r.midX ? m : nil
            case .right: return c.midX > r.midX ? m : nil
            case .up: return c.midY < r.midY ? m : nil
            case .down: return c.midY > r.midY ? m : nil
            }
        }
    }

    // MARK: - Actions

    func perform(_ b: Keybind) {
        if b.action == .pause { setPaused(!paused); return }
        // A key press means the screen is in use; recover if a wake event was missed.
        if asleep { wakeUp() }
        guard started, !paused else { return }
        let arg = b.arg.trimmingCharacters(in: .whitespaces)
        switch b.action {
        case .focus: if let d = Dir(rawValue: arg.lowercased()) { focusDir(d) }
        case .swap: if let d = Dir(rawValue: arg.lowercased()) { swapDir(d) }
        case .workspace: if let n = Int(arg) { switchTo(n) }
        case .movetoworkspace: if let n = Int(arg), let w = focusedWindow() { move(w, to: n, follow: true) }
        case .movetoworkspacesilent: if let n = Int(arg), let w = focusedWindow() { move(w, to: n, follow: false) }
        case .workspacenext: cycleWorkspace(1)
        case .workspaceprev: cycleWorkspace(-1)
        case .workspaceformer: if let p = previousWorkspace { switchTo(p) }
        case .close:
            if let w = focusedWindow(), let btn = AX.element(w.el, kAXCloseButtonAttribute) { AX.press(btn) }
        case .togglefloating: toggleFloating()
        case .fullscreen: toggleFullscreen(.full)
        case .maximize: toggleFullscreen(.maximize)
        case .togglesplit:
            if let w = focusedWindow(), let ws = workspaces[w.workspace], let p = ws.root?.find(w.id)?.parent {
                p.vertical.toggle()
                apply(ws.n)
                updateBorder()
            }
        case .pseudo:
            if let w = focusedWindow(), !w.floating {
                w.pseudo.toggle()
                if w.pseudo { w.pseudoSize = AX.size(w.el) }
                w.lastSet = nil
                apply(w.workspace)
                updateBorder()
            }
        case .resizewidth: resizeFocused(dx: resizeAmount(arg), dy: 0)
        case .resizeheight: resizeFocused(dx: 0, dy: resizeAmount(arg))
        case .openapp: openApp(arg, newWindow: b.newWindow)
        case .exec: run(arg)
        case .launcher: AppDelegate.shared?.showLauncher()
        case .spotlight: InputTap.postKey(0x31, flags: .maskCommand)  // ⌘-Space
        case .showkeys: AppDelegate.shared?.showCheatSheet()
        case .settings: AppDelegate.shared?.showSettings()
        case .reload: ConfigStore.shared.reload()
        case .pause: break
        }
    }

    private func resizeAmount(_ arg: String) -> CGFloat {
        let step = CGFloat(cfg.resizeStep)
        switch arg {
        case "+", "": return step
        case "-", "−": return -step
        default: return CGFloat(Double(arg) ?? 0)
        }
    }

    private func openApp(_ id: String, newWindow: Bool) {
        guard let url = AppCatalog.url(for: id) else { return }
        // An app that isn't running, or is running with no windows, opens a window
        // by itself when launched or switched to; ⌘N on top of that makes two.
        let hadWindow = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { app in
            !AX.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute).isEmpty
        }
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: conf) { _, _ in }
        // An app that already has a window only comes to the front; ask it for a fresh one.
        guard newWindow, hadWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id {
                InputTap.postKey(0x2D, flags: .maskCommand)
            }
        }
    }

    private func run(_ cmd: String) {
        guard !cmd.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try? p.run()
    }

    private func focusDir(_ d: Dir) {
        guard let cur = focusedWindow(), let r = rect(cur) else {
            if let m = monitor(in: d, from: focusedMonitor) {
                focusedMonitor = m.id
                focusWorkspace(activeWorkspace(on: m.id))
            }
            return
        }
        let ws = workspaces[cur.workspace]
        let cands = visibleWindows
            .filter { $0.id != cur.id && (ws?.fullscreen == nil || $0.workspace != cur.workspace) }
            .compactMap { w in rect(w).map { (w, $0) } }
        if let n = neighbor(of: r, d, among: cands) {
            focus(n)
        } else if let m = monitor(in: d, from: focusedMonitor) {
            focusedMonitor = m.id
            focusWorkspace(activeWorkspace(on: m.id))
        }
    }

    private func swapDir(_ d: Dir) {
        guard let cur = focusedWindow(), let ws = workspaces[cur.workspace] else { return }
        if cur.floating {
            guard var f = AX.frame(cur.el) else { return }
            let s: CGFloat = 50
            switch d {
            case .left: f.origin.x -= s
            case .right: f.origin.x += s
            case .up: f.origin.y -= s
            case .down: f.origin.y += s
            }
            cur.floatFrame = f
            setFrame(cur, f)
            updateBorder()
            return
        }
        guard let r = rect(cur) else { return }
        let tiled = windows(in: ws.n).filter { !$0.floating && $0.id != cur.id }.compactMap { w in rect(w).map { (w, $0) } }
        if let n = neighbor(of: r, d, among: tiled) {
            Dwindle.swap(ws, cur.id, n.id)
            cur.lastSet = nil
            n.lastSet = nil
            apply(ws.n)
            focus(cur)
        } else if let m = monitor(in: d, from: focusedMonitor) {
            move(cur, to: activeWorkspace(on: m.id), follow: true)
        }
    }

    func move(_ w: ManagedWindow, to n: Int, follow: Bool) {
        let from = w.workspace
        guard (1...10).contains(n), from != n, let src = workspaces[from], let dst = workspaces[n] else { return }
        Dwindle.remove(src, w.id)
        if src.focused == w.id { src.focused = nil }
        if src.fullscreen == w.id { src.fullscreen = nil }
        w.workspace = n
        if !w.floating { Dwindle.insert(dst, w.id, near: dst.focused) }
        dst.focused = w.id
        w.lastSet = nil
        if monitorShowing(n) == nil { hide(w) }
        suppressFocus()
        apply(from)
        apply(n)
        if follow {
            if let m = monitorShowing(n) { focusedMonitor = m } else { switchTo(n) }
            focus(w)
        } else {
            focusWorkspace(from)
        }
        onStatus?()
    }

    private func toggleFloating() {
        guard let w = focusedWindow(), let ws = workspaces[w.workspace],
              let m = monitorShowing(ws.n).flatMap(monitor) else { return }
        if w.floating {
            w.floating = false
            Dwindle.insert(ws, w.id, near: nil)
        } else {
            Dwindle.remove(ws, w.id)
            if ws.fullscreen == w.id { ws.fullscreen = nil }
            w.floating = true
            w.pseudo = false
            let vf = m.visible
            let cur = AX.frame(w.el)?.size ?? CGSize(width: vf.width * 0.6, height: vf.height * 0.6)
            let size = CGSize(width: min(cur.width, vf.width * 0.7), height: min(cur.height, vf.height * 0.7))
            w.floatFrame = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        }
        w.lastSet = nil
        apply(ws.n)
        AX.raise(w.el)
        updateBorder()
    }

    private func toggleFullscreen(_ mode: Workspace.FullscreenMode) {
        guard let w = focusedWindow(), let ws = workspaces[w.workspace] else { return }
        if w.floating {
            // Promote floating windows to tiled first so fullscreen has a tile to restore to.
            toggleFloating()
        }
        if ws.fullscreen == w.id && ws.fullscreenMode == mode {
            ws.fullscreen = nil
        } else {
            ws.fullscreen = w.id
            ws.fullscreenMode = mode
        }
        for x in windows(in: ws.n) { x.lastSet = nil }
        apply(ws.n)
        updateBorder()
    }

    private func resizeFocused(dx: CGFloat, dy: CGFloat) {
        guard let w = focusedWindow() else { return }
        if w.floating {
            guard var f = AX.frame(w.el) else { return }
            f.size.width = max(120, f.width + dx)
            f.size.height = max(80, f.height + dy)
            w.floatFrame = f
            setFrame(w, f)
        } else {
            resizeTiled(w, dx: dx, dy: dy)
            apply(w.workspace)
        }
        updateBorder()
    }

    private func resizeTiled(_ w: ManagedWindow, dx: CGFloat, dy: CGFloat) {
        guard let ws = workspaces[w.workspace], let leaf = ws.root?.find(w.id) else { return }
        if dx != 0, let (anc, inFirst) = Dwindle.ancestor(of: leaf, vertical: true), anc.rect.width > 0 {
            let delta = dx / anc.rect.width
            anc.ratio = min(0.9, max(0.1, anc.ratio + (inFirst ? delta : -delta)))
        }
        if dy != 0, let (anc, inFirst) = Dwindle.ancestor(of: leaf, vertical: false), anc.rect.height > 0 {
            let delta = dy / anc.rect.height
            anc.ratio = min(0.9, max(0.1, anc.ratio + (inFirst ? delta : -delta)))
        }
    }

    // MARK: - Mouse

    func scroll(_ delta: Int) {
        guard Date().timeIntervalSince(lastScrollSwitch) > 0.25 else { return }
        lastScrollSwitch = Date()
        cycleWorkspace(delta < 0 ? 1 : -1)
    }

    private func window(at p: CGPoint) -> ManagedWindow? {
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, let hit {
            let win = AX.string(hit, kAXRoleAttribute) == kAXWindowRole ? hit : AX.element(hit, kAXWindowAttribute)
            if let win, let id = AX.windowID(win), let w = windows[id] { return w }
        }
        let vis = visibleWindows
        return vis.first { $0.floating && rect($0)?.contains(p) == true }
            ?? vis.first { rect($0)?.contains(p) == true }
    }

    func beginDrag(at p: CGPoint, resize: Bool) {
        guard !paused, let w = window(at: p) else { return }
        focus(w)
        AX.raise(w.el)
        let frame = AX.frame(w.el) ?? .zero
        drag = DragState(w: w, resize: resize, start: p, startFrame: frame, last: p,
                         grabRight: p.x >= frame.midX, grabBottom: p.y >= frame.midY)
    }

    func dragMoved(to p: CGPoint) {
        guard var d = drag else { return }
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        if d.resize {
            if d.w.floating {
                var f = d.startFrame
                f.size.width = max(120, f.width + dx)
                f.size.height = max(80, f.height + dy)
                d.w.floatFrame = f
                d.w.lastSet = f
                AX.setSize(d.w.el, f.size)
            } else if let leaf = workspaces[d.w.workspace]?.root?.find(d.w.id) {
                // The grabbed edges follow the pointer, like Hyprland.
                Dwindle.moveEdge(of: leaf, vertical: true, farEdge: d.grabRight, by: p.x - d.last.x)
                Dwindle.moveEdge(of: leaf, vertical: false, farEdge: d.grabBottom, by: p.y - d.last.y)
                apply(d.w.workspace)
            }
        } else {
            var f = d.startFrame
            f.origin.x += dx
            f.origin.y += dy
            AX.setPosition(d.w.el, f.origin)
            if d.w.floating {
                d.w.floatFrame = f
                d.w.lastSet = f
            } else {
                d.w.lastSet = nil
            }
        }
        d.last = p
        drag = d
        updateBorder(d.w)
    }

    func endDrag(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        if !d.resize && !d.w.floating { dropTiled(d.w, at: p) }
        updateBorder(d.w)
    }

    /// Dropping a tiled window onto another swaps them; onto another monitor moves it there.
    private func dropTiled(_ w: ManagedWindow, at p: CGPoint) {
        if let target = visibleWindows.first(where: { $0.id != w.id && !$0.floating && (rect($0)?.contains(p) ?? false) }) {
            if target.workspace == w.workspace, let ws = workspaces[w.workspace] {
                Dwindle.swap(ws, w.id, target.id)
                target.lastSet = nil
            } else {
                workspaces[target.workspace]?.focused = target.id
                move(w, to: target.workspace, follow: true)
            }
        } else if let m = monitors.first(where: { $0.frame.contains(p) }), let n = active[m.id], n != w.workspace {
            move(w, to: n, follow: true)
        }
        w.lastSet = nil
        apply(w.workspace)
    }

    /// Hover-to-focus. The pointer has to rest briefly, so windows crossed on
    /// the way somewhere else don't grab focus.
    func focusFollowsMouse(at p: CGPoint) {
        guard cfg.focusFollowsMouse, drag == nil, !paused, NSEvent.pressedMouseButtons == 0 else { return }
        hoverWork?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { self.hoverFocus() } }
        hoverWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func hoverFocus() {
        guard cfg.focusFollowsMouse, drag == nil, !paused, NSEvent.pressedMouseButtons == 0 else { return }
        // Leave focus alone while one of HyprMac's own windows (settings, launcher) is in use.
        if NSApp.isActive, NSApp.keyWindow != nil { return }
        if popupHasFocus { return }
        let p = mouseLocationAX()
        guard let top = topWindowID(at: p) else {
            // Over the empty desktop: just remember which display the pointer is on.
            if let m = monitors.first(where: { $0.frame.contains(p) }), m.id != focusedMonitor {
                focusedMonitor = m.id
                onStatus?()
            }
            return
        }
        // Whatever is on top under the pointer decides. If that's a popup or
        // dialog HyprMac doesn't manage (Screenshot, save sheets, alerts), leave
        // it alone instead of raising the tile behind it over it.
        guard let w = windows[top], !w.hidden, w.id != focusedWindow()?.id else { return }
        focus(w)
    }

    /// True when the focused window is a popup, dialog or floating window rather
    /// than a tile. macOS won't let HyprMac keep another app's window above the
    /// rest, so instead such a window keeps focus until you click elsewhere;
    /// otherwise hovering a tile beside it would raise that tile over it.
    private var popupHasFocus: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let fw = AX.element(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(fw) else { return false }
        guard let w = windows[id] else { return true }  // a window HyprMac doesn't tile
        return w.floating
    }

    /// The frontmost window under a point, in macOS's real stacking order, so
    /// windows HyprMac doesn't manage count too. Ignores the Dock, menu bar and
    /// screen-wide overlays (layer 20 and up) and HyprMac's own border.
    private func topWindowID(at p: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, (0..<20).contains(layer),
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bounds), r.contains(p),
                  let n = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return n
        }
        return nil
    }

    // MARK: - Geometry changes made by the user

    private func geometryChanged(_ el: AXUIElement) {
        guard let w = windows.values.first(where: { CFEqual($0.el, el) }), !w.hidden else { return }
        if w.id == focusedWindow()?.id { updateBorder() }
        if drag != nil { return }
        if w.floating {
            if let f = AX.frame(w.el) {
                w.floatFrame = f
                w.lastSet = f
            }
            return
        }
        snapWork[w.id]?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { self.snap(w) } }
        snapWork[w.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    /// A tiled window was dragged or resized with the title bar / edges. Interpret
    /// it (swap, move monitor, adjust split) and then snap everything back to the grid.
    private func snap(_ w: ManagedWindow) {
        guard windows[w.id] === w, !w.hidden, !w.floating, drag == nil else { return }
        if NSEvent.pressedMouseButtons != 0 {
            geometryChanged(w.el)
            return
        }
        guard let target = w.lastSet, let cur = AX.frame(w.el), !cur.roughlyEquals(target) else { return }
        // Only react to user gestures; apps that refuse a size (minimum sizes) are left alone.
        guard Date().timeIntervalSince(InputTap.shared.lastMouseUp) < 1.5 else { return }
        let sizeChanged = abs(cur.width - target.width) > 3 || abs(cur.height - target.height) > 3
        if sizeChanged {
            resizeTiled(w, dx: cur.width - target.width, dy: cur.height - target.height)
            for x in windows(in: w.workspace) { x.lastSet = nil }
            apply(w.workspace)
        } else {
            dropTiled(w, at: mouseLocationAX())
        }
        updateBorder()
    }
}
