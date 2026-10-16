import AppKit

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = MainActor.assumeIsolated { InputTap.shared.handle(type, event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}

/// One CGEventTap for all global input: keyboard shortcuts plus the Hyprland
/// mouse bindings (SUPER+drag, SUPER+right-drag, SUPER+scroll).
/// A tap is used instead of Carbon hotkeys because macOS 15+ refuses
/// Option-only Carbon hotkeys, and Option is the default SUPER key.
@MainActor
final class InputTap {
    static let shared = InputTap()
    static let marker: Int64 = 0x0A7A_711E
    private static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private struct Combo: Hashable {
        let key: UInt16
        let flags: UInt64
    }

    /// Set while the settings window is recording a shortcut.
    var suspended = false
    private(set) var lastMouseUp = Date.distantPast
    private var tap: CFMachPort?
    private var table: [Combo: Keybind] = [:]
    private var superFlag: CGEventFlags = .maskAlternate
    private var mouseEnabled = true
    private var followMouse = false
    private var swallowedKeys = Set<UInt16>()
    private var dragging = false

    func rebuild(_ cfg: Config) {
        var t: [Combo: Keybind] = [:]
        for b in cfg.bindings {
            guard let code = Keys.codes[b.key.lowercased()] else { continue }
            let combo = Combo(key: code, flags: cfg.flags(for: b.mods).rawValue)
            if t[combo] == nil { t[combo] = b }
        }
        table = t
        superFlag = cfg.superKey.cgFlag
        mouseEnabled = cfg.mouseBindings
        followMouse = cfg.focusFollowsMouse
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel, .mouseMoved]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    /// Returns true to let the event through, false to swallow it.
    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if e.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        let wm = WindowManager.shared
        let flags = e.flags.intersection(Self.relevant)

        switch type {
        case .keyDown:
            guard !suspended else { return true }
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
            guard let b = table[Combo(key: code, flags: flags.rawValue)] else { return true }
            if wm.paused && b.action != .pause { return true }
            swallowedKeys.insert(code)
            DispatchQueue.main.async { wm.perform(b) }
            return false

        case .keyUp:
            let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
            return swallowedKeys.remove(code) == nil

        case .leftMouseDown, .rightMouseDown:
            guard mouseEnabled, !suspended, !wm.paused, wm.started, flags == superFlag else { return true }
            let p = e.location
            let resize = type == .rightMouseDown
            dragging = true
            DispatchQueue.main.async { wm.beginDrag(at: p, resize: resize) }
            return false

        case .leftMouseDragged, .rightMouseDragged:
            guard dragging else { return true }
            let p = e.location
            DispatchQueue.main.async { wm.dragMoved(to: p) }
            return false

        case .leftMouseUp, .rightMouseUp:
            lastMouseUp = Date()
            guard dragging else { return true }
            dragging = false
            let p = e.location
            DispatchQueue.main.async { wm.endDrag(at: p) }
            return false

        case .scrollWheel:
            guard mouseEnabled, !suspended, !wm.paused, flags == superFlag else { return true }
            let delta = Int(e.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            if delta != 0 { DispatchQueue.main.async { wm.scroll(delta) } }
            return false

        case .mouseMoved:
            guard followMouse else { return true }
            let p = e.location
            DispatchQueue.main.async { wm.focusFollowsMouse(at: p) }
            return true

        default:
            return true
        }
    }

    /// Synthesizes a key press that the tap itself will ignore.
    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.setIntegerValueField(.eventSourceUserData, value: marker)
            ev.post(tap: .cghidEventTap)
        }
    }
}

/// The Hyprland-style active border: a click-through overlay drawn around the focused window.
@MainActor
final class BorderOverlay {
    private let window: NSWindow
    private let box = NSView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        box.wantsLayer = true
        window.contentView = box
    }

    func show(_ axFrame: CGRect, cfg: Config) {
        guard let h = NSScreen.screens.first?.frame.height else { return }
        let bw = CGFloat(cfg.borderWidth)
        let r = CGRect(x: axFrame.minX, y: h - axFrame.maxY, width: axFrame.width, height: axFrame.height)
            .insetBy(dx: -bw, dy: -bw)
        window.setFrame(r, display: true)
        if let layer = box.layer {
            layer.borderWidth = bw
            layer.borderColor = NSColor(hex: cfg.activeBorderColor).cgColor
            layer.cornerRadius = CGFloat(cfg.borderRadius) + bw
        }
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
