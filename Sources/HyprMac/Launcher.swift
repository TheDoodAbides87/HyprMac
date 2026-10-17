import AppKit
import SwiftUI

/// A keyboard-driven app launcher in the spirit of the ones Hyprland setups use
/// (walker, wofi, rofi): type to fuzzy-match, arrows to pick, Return to open.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { filter() } }
    @Published private(set) var results: [AppEntry] = []
    @Published var selection = 0
    var onClose: (() -> Void)?

    private var all: [AppEntry] = []
    private var icons: [URL: NSImage] = [:]
    private static let countsKey = "launcherCounts"

    func reset() {
        all = AppCatalog.installed(refresh: true)
        query = ""
        filter()
    }

    func icon(_ e: AppEntry) -> NSImage {
        if let i = icons[e.url] { return i }
        let i = NSWorkspace.shared.icon(forFile: e.url.path)
        icons[e.url] = i
        return i
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func launch(_ e: AppEntry? = nil) {
        guard let e = e ?? (results.indices.contains(selection) ? results[selection] : nil) else { return }
        var counts = UserDefaults.standard.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
        counts[e.url.path, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.countsKey)
        onClose?()
        NSWorkspace.shared.openApplication(at: e.url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func filter() {
        let counts = UserDefaults.standard.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let scored: [(Int, AppEntry)] = all.compactMap { e in
            let usage = min((counts[e.url.path] ?? 0) * 20, 200)
            if q.isEmpty { return (usage, e) }
            guard let s = Self.score(e.name.lowercased(), q) else { return nil }
            return (s + usage, e)
        }
        results = scored.sorted {
            $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending
        }.map(\.1)
        selection = 0
    }

    /// Prefix beats word-start beats substring beats in-order letters.
    private static func score(_ name: String, _ q: String) -> Int? {
        if name.hasPrefix(q) { return 1000 - name.count }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 800 - name.count }
        if name.contains(q) { return 600 - name.count }
        var gaps = 0
        var it = name.makeIterator()
        for c in q {
            var found = false
            while let n = it.next() {
                if n == c { found = true; break }
                gaps += 1
            }
            if !found { return nil }
        }
        return 300 - gaps
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                LauncherField(model: model)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider()
            if model.results.isEmpty {
                Text("No matching apps")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // Rows are identified by app, not position, so a row never
                            // keeps showing a stale app after the results change.
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, e in
                                row(i, e)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) { _, new in
                        if model.results.indices.contains(new) { proxy.scrollTo(model.results[new].id) }
                    }
                }
            }
        }
        .frame(width: 620, height: 420)
        .background(VisualEffect())
    }

    private func row(_ i: Int, _ e: AppEntry) -> some View {
        let selected = i == model.selection
        return HStack(spacing: 12) {
            Image(nsImage: model.icon(e))
                .resizable()
                .frame(width: 28, height: 28)
            Text(e.name).font(.system(size: 15))
            Spacer()
            if selected {
                Text("↩").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.launch(e) }
    }
}

/// An NSTextField so arrow keys, Return and Esc can drive the list.
private struct LauncherField: NSViewRepresentable {
    @ObservedObject var model: LauncherModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "Search apps…"
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 20)
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != model.query { f.stringValue = model.query }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LauncherModel
        init(model: LauncherModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            let text = f.stringValue
            MainActor.assumeIsolated { model.query = text }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch sel {
                case #selector(NSResponder.moveDown(_:)): model.move(1)
                case #selector(NSResponder.moveUp(_:)): model.move(-1)
                case #selector(NSResponder.insertNewline(_:)): model.launch()
                case #selector(NSResponder.cancelOperation(_:)): model.onClose?()
                default: return false
                }
                return true
            }
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Borderless floating panel that can take keyboard focus and closes when it loses it.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
}
