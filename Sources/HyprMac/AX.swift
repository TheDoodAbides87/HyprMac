import AppKit
import ApplicationServices

// Private but stable API used by every macOS window manager (yabai, AeroSpace, Rectangle…)
// to map an accessibility element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin helpers over the Accessibility C API. All coordinates are in the AX/CG
/// global space: origin at the top-left of the primary display, y grows downward.
enum AX {
    static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (raw(el, name) as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        raw(el, name) as? String
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (raw(el, name) as? NSNumber)?.boolValue
    }

    static func settable(_ el: AXUIElement, _ name: String) -> Bool {
        var ok = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, name as CFString, &ok) == .success && ok.boolValue
    }

    static func setBool(_ el: AXUIElement, _ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!)
    }

    static func position(_ el: AXUIElement) -> CGPoint? {
        guard let v = raw(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = raw(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func setPosition(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }

    static func setSize(_ el: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    /// Size → position → size, so the final size isn't clamped by the old position's screen edge.
    static func setFrame(_ el: AXUIElement, _ r: CGRect) {
        setSize(el, r.size)
        setPosition(el, r.origin)
        setSize(el, r.size)
    }

    /// Like setFrame, but with one call instead of three when only the position
    /// or only the size differs from `knownSize` / `knownOrigin` (what the window
    /// is known to have). Bringing a parked window back is usually a move only.
    static func setFrame(_ el: AXUIElement, _ r: CGRect, knownSize: CGSize?, knownOrigin: CGPoint?) {
        if knownSize == r.size {
            setPosition(el, r.origin)
        } else if knownOrigin == r.origin {
            setSize(el, r.size)
        } else {
            setFrame(el, r)
        }
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    static func press(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }
}

/// A physical display, with frames converted to AX coordinates.
struct Monitor {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visible: CGRect   // excludes menu bar and Dock

    static func current() -> [Monitor] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.height
        func conv(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Monitor(id: id, frame: conv(s.frame), visible: conv(s.visibleFrame))
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    func rounded() -> CGRect { CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded()) }
    func roughlyEquals(_ o: CGRect, tolerance t: CGFloat = 3) -> Bool {
        abs(minX - o.minX) <= t && abs(minY - o.minY) <= t && abs(width - o.width) <= t && abs(height - o.height) <= t
    }
}

/// Converts the Cocoa mouse location (bottom-left origin) into AX space.
func mouseLocationAX() -> CGPoint {
    let p = NSEvent.mouseLocation
    let h = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: p.x, y: h - p.y)
}
