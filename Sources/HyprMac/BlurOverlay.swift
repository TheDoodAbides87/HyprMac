import AppKit

/// Blurs and dims everything behind the window that holds focus, one panel per
/// screen. It never takes clicks or focus; HyprMac decides what clicks do.
@MainActor
final class BlurOverlay {
    private var panels: [NSPanel] = []

    /// Shows the blur just below `windowNumber` (another app's window), or on
    /// top of all normal windows when nil (HyprMac's own floating Settings).
    func show(below windowNumber: Int?) {
        if panels.isEmpty { build() }
        for p in panels {
            if let n = windowNumber {
                p.order(.below, relativeTo: n)
            } else {
                p.orderFrontRegardless()
            }
            if p.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
            }
        }
    }

    func hide() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }

    /// Screens can change; rebuild on the next show.
    func reset() { hide() }

    private func build() {
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.visibleFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .normal
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let dim = NSView(frame: blur.bounds)
            dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            dim.autoresizingMask = [.width, .height]
            blur.addSubview(dim)
            p.contentView = blur
            p.alphaValue = 0
            panels.append(p)
        }
    }
}
