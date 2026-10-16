import AppKit
import Combine

// MARK: - Modifiers

/// A physical Mac modifier that the Hyprland names SUPER / ALT can be mapped onto.
enum ModKey: String, Codable, CaseIterable, Identifiable {
    case option, command, control

    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        case .control: "⌃ Control"
        }
    }
    var cgFlag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        }
    }
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .command: .command
        case .control: .control
        }
    }
}

// MARK: - Actions

enum Action: String, Codable, CaseIterable, Identifiable {
    case focus, swap
    case workspace, movetoworkspace, movetoworkspacesilent
    case workspacenext, workspaceprev, workspaceformer
    case close, togglefloating, fullscreen, maximize, togglesplit, pseudo
    case resizewidth, resizeheight
    case exec, launcher, showkeys, settings, reload, pause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "Move focus"
        case .swap: "Swap window"
        case .workspace: "Switch to workspace"
        case .movetoworkspace: "Move window to workspace"
        case .movetoworkspacesilent: "Move window to workspace (silent)"
        case .workspacenext: "Next workspace"
        case .workspaceprev: "Previous workspace"
        case .workspaceformer: "Former workspace"
        case .close: "Close window"
        case .togglefloating: "Toggle floating"
        case .fullscreen: "Fullscreen"
        case .maximize: "Maximize (keep gaps)"
        case .togglesplit: "Toggle split direction"
        case .pseudo: "Pseudo-tile"
        case .resizewidth: "Resize width"
        case .resizeheight: "Resize height"
        case .exec: "Run command"
        case .launcher: "App launcher (Spotlight)"
        case .showkeys: "Show keybindings"
        case .settings: "Open settings"
        case .reload: "Reload config"
        case .pause: "Pause / resume tiling"
        }
    }

    var argHint: String? {
        switch self {
        case .focus, .swap: "left | right | up | down"
        case .workspace, .movetoworkspace, .movetoworkspacesilent: "1 – 10"
        case .resizewidth, .resizeheight: "+ / − or pixels, e.g. -100"
        case .exec: "shell command"
        default: nil
        }
    }
}

// MARK: - Keybinding

struct Keybind: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Any of: super, alt, ctrl, shift — plus raw cmd / opt for keys not mapped to SUPER/ALT.
    var mods: [String]
    var key: String
    var action: Action
    var arg: String

    init(_ mods: [String], _ key: String, _ action: Action, _ arg: String = "") {
        self.mods = mods
        self.key = key
        self.action = action
        self.arg = arg
    }

    enum CodingKeys: String, CodingKey { case mods, key, action, arg }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        key = try c.decode(String.self, forKey: .key)
        action = try c.decode(Action.self, forKey: .action)
        arg = try c.decodeIfPresent(String.self, forKey: .arg) ?? ""
    }

    static let modOrder = ["super", "ctrl", "alt", "cmd", "opt", "shift"]

    var comboKey: String {
        let m = Set(mods.map { $0.lowercased() })
        return Self.modOrder.filter(m.contains).joined(separator: "+") + "+" + key.lowercased()
    }

    var displayParts: [String] {
        let m = Set(mods.map { $0.lowercased() })
        let labels = ["super": "SUPER", "ctrl": "CTRL", "alt": "ALT", "cmd": "⌘", "opt": "⌥", "shift": "SHIFT"]
        return Self.modOrder.filter(m.contains).compactMap { labels[$0] } + [Keys.display(key)]
    }

    var summary: String {
        switch action {
        case .focus, .swap: "\(action.title) \(arg)"
        case .workspace, .movetoworkspace, .movetoworkspacesilent: "\(action.title) \(arg)"
        case .resizewidth, .resizeheight: "\(action.title) \(arg)"
        case .exec: arg
        default: action.title
        }
    }

    /// Maps physical modifier flags back to Hyprland names under the current config.
    static func mods(from flags: NSEvent.ModifierFlags, _ cfg: Config) -> [String] {
        var out: [String] = []
        for (phys, raw) in [(ModKey.command, "cmd"), (.option, "opt"), (.control, "ctrl")] where flags.contains(phys.nsFlag) {
            if phys == cfg.superKey { out.append("super") }
            else if phys == cfg.altKey { out.append("alt") }
            else { out.append(raw) }
        }
        if flags.contains(.shift) { out.append("shift") }
        return modOrder.filter(out.contains)
    }
}

// MARK: - Config

struct Config: Codable, Equatable {
    var superKey: ModKey = .option
    var altKey: ModKey = .command
    var gapsIn: Double = 5
    var gapsOut: Double = 10
    var borderEnabled = true
    var borderWidth: Double = 2
    var borderRadius: Double = 12
    var activeBorderColor = "#33CCFF"
    var mouseBindings = true
    var focusFollowsMouse = false
    var resizeStep: Double = 100
    var floatApps: [String] = [
        "com.apple.systempreferences",
        "com.apple.calculator",
        "com.apple.archiveutility",
        "com.apple.FaceTime",
        "com.apple.Passwords",
    ]
    var ignoreApps: [String] = []
    var bindings: [Keybind] = Config.defaultBindings()

    func flags(for mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m.lowercased() {
            case "super": f.insert(superKey.cgFlag)
            case "alt": f.insert(altKey.cgFlag)
            case "ctrl": f.insert(.maskControl)
            case "shift": f.insert(.maskShift)
            case "cmd": f.insert(.maskCommand)
            case "opt": f.insert(.maskAlternate)
            default: break
            }
        }
        return f
    }

    var duplicateCombos: Set<String> {
        var seen = Set<String>(), dupes = Set<String>()
        for b in bindings where !b.key.isEmpty {
            let k = flags(for: b.mods).rawValue.description + "+" + b.key.lowercased()
            if !seen.insert(k).inserted { dupes.insert(k) }
        }
        return dupes
    }

    func physicalComboKey(_ b: Keybind) -> String {
        flags(for: b.mods).rawValue.description + "+" + b.key.lowercased()
    }

    // Default bindings, modeled on a typical Hyprland setup and translated to macOS apps.
    static func defaultBindings() -> [Keybind] {
        var b: [Keybind] = [
            .init(["super"], "return", .exec, Apps.terminal),
            .init(["super", "shift"], "b", .exec, Apps.browser),
            .init(["super", "shift"], "f", .exec, "open ~"),
            .init(["super", "shift"], "n", .exec, Apps.editor),
            .init(["super", "shift"], "m", .exec, Apps.music),
            .init(["super", "shift"], "t", .exec, "open -a 'Activity Monitor'"),
            .init(["super"], "space", .launcher),
            .init(["super", "alt"], "space", .settings),
            .init(["super"], "k", .showkeys),

            .init(["super"], "w", .close),
            .init(["super"], "t", .togglefloating),
            .init(["super"], "f", .fullscreen),
            .init(["super", "alt"], "f", .maximize),
            .init(["super"], "j", .togglesplit),
            .init(["super"], "p", .pseudo),
        ]
        for d in ["left", "right", "up", "down"] {
            b.append(.init(["super"], d, .focus, d))
        }
        for d in ["left", "right", "up", "down"] {
            b.append(.init(["super", "shift"], d, .swap, d))
        }
        b += [
            .init(["super"], "minus", .resizewidth, "-"),
            .init(["super"], "equal", .resizewidth, "+"),
            .init(["super", "shift"], "minus", .resizeheight, "-"),
            .init(["super", "shift"], "equal", .resizeheight, "+"),
        ]
        for i in 1...10 {
            b.append(.init(["super"], i == 10 ? "0" : "\(i)", .workspace, "\(i)"))
        }
        for i in 1...10 {
            b.append(.init(["super", "shift"], i == 10 ? "0" : "\(i)", .movetoworkspace, "\(i)"))
        }
        b += [
            .init(["super"], "tab", .workspacenext),
            .init(["super", "shift"], "tab", .workspaceprev),
            .init(["super", "ctrl"], "tab", .workspaceformer),
            .init(["super", "ctrl"], "escape", .pause),
        ]
        return b
    }
}

extension Config {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Config()
        superKey = try c.decodeIfPresent(ModKey.self, forKey: .superKey) ?? def.superKey
        altKey = try c.decodeIfPresent(ModKey.self, forKey: .altKey) ?? def.altKey
        gapsIn = try c.decodeIfPresent(Double.self, forKey: .gapsIn) ?? def.gapsIn
        gapsOut = try c.decodeIfPresent(Double.self, forKey: .gapsOut) ?? def.gapsOut
        borderEnabled = try c.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? def.borderEnabled
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? def.borderWidth
        borderRadius = try c.decodeIfPresent(Double.self, forKey: .borderRadius) ?? def.borderRadius
        activeBorderColor = try c.decodeIfPresent(String.self, forKey: .activeBorderColor) ?? def.activeBorderColor
        mouseBindings = try c.decodeIfPresent(Bool.self, forKey: .mouseBindings) ?? def.mouseBindings
        focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? def.focusFollowsMouse
        resizeStep = try c.decodeIfPresent(Double.self, forKey: .resizeStep) ?? def.resizeStep
        floatApps = try c.decodeIfPresent([String].self, forKey: .floatApps) ?? def.floatApps
        ignoreApps = try c.decodeIfPresent([String].self, forKey: .ignoreApps) ?? def.ignoreApps
        bindings = try c.decodeIfPresent([Keybind].self, forKey: .bindings) ?? def.bindings
    }
}

/// Picks sensible macOS stand-ins for the apps a Hyprland setup usually launches.
enum Apps {
    static func installed(_ name: String) -> Bool {
        ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            .contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
    }

    static var terminal: String {
        for (app, cmd) in [
            ("Ghostty", "open -na Ghostty"),
            ("Alacritty", "open -na Alacritty"),
            ("kitty", "open -na kitty"),
            ("WezTerm", "open -na WezTerm"),
            ("iTerm", "osascript -e 'tell application \"iTerm\" to create window with default profile'"),
        ] where installed(app) { return cmd }
        return "osascript -e 'tell application \"Terminal\" to do script \"\"' -e 'tell application \"Terminal\" to activate'"
    }

    static var browser: String {
        for app in ["Chromium", "Google Chrome", "Brave Browser", "Microsoft Edge"] where installed(app) {
            return "open -na '\(app)' --args --new-window"
        }
        return "open -a Safari"
    }

    static var editor: String {
        for app in ["Zed", "Visual Studio Code", "Cursor"] where installed(app) { return "open -a '\(app)'" }
        return "open -a TextEdit"
    }

    static var music: String {
        installed("Spotify") ? "open -a Spotify" : "open -a Music"
    }
}

// MARK: - Store

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config
    @Published var loadError: String?
    var onApply: ((Config) -> Void)?

    let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/hyprmac/config.json")
    private var bag: AnyCancellable?

    private init() {
        config = Config()
        // Carry settings over from the app's earlier name.
        let legacy = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("omatile/config.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacy, to: url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            if let c = readFile() { config = c }
        } else {
            persist(config)
        }
        // Every edit (GUI or reload) is debounced, written to disk and applied live.
        bag = $config.dropFirst().removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] c in
                MainActor.assumeIsolated {
                    self?.persist(c)
                    self?.onApply?(c)
                }
            }
    }

    func reload() {
        if let c = readFile() { config = c }
    }

    func resetBindings() {
        config.bindings = Config.defaultBindings()
    }

    private func readFile() -> Config? {
        do {
            let data = try Data(contentsOf: url)
            let c = try JSONDecoder().decode(Config.self, from: data)
            loadError = nil
            return c
        } catch {
            loadError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            NSLog("HyprMac: \(loadError!)")
            return nil
        }
    }

    private func persist(_ c: Config) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(c).write(to: url, options: .atomic)
        } catch {
            NSLog("HyprMac: failed to save config: \(error)")
        }
    }
}

// MARK: - Key names

enum Keys {
    static let codes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
        "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "bracketright": 0x1E, "o": 0x1F,
        "u": 0x20, "bracketleft": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26,
        "quote": 0x27, "k": 0x28, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C,
        "n": 0x2D, "m": 0x2E, "period": 0x2F, "tab": 0x30, "space": 0x31, "grave": 0x32,
        "backspace": 0x33, "escape": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "home": 0x73, "pageup": 0x74, "delete": 0x75, "end": 0x77, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    static let names: [UInt16: String] = Dictionary(uniqueKeysWithValues: codes.map { ($1, $0) })

    static func display(_ key: String) -> String {
        let symbols = [
            "return": "RETURN", "space": "SPACE", "tab": "TAB", "escape": "ESC", "backspace": "⌫",
            "delete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓", "minus": "−", "equal": "=",
            "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
            "grave": "`", "bracketleft": "[", "bracketright": "]", "pageup": "PG UP", "pagedown": "PG DN",
        ]
        if key.isEmpty { return "—" }
        return symbols[key.lowercased()] ?? key.uppercased()
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
