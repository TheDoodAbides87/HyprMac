import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var s: SettingsState

    init(store: ConfigStore, tab: Int) {
        self.store = store
        _s = StateObject(wrappedValue: SettingsState(tab: tab))
    }

    var body: some View {
        TabView(selection: $s.tab) {
            GeneralTab(store: store)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(0)
            KeybindingsTab(store: store)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }.tag(1)
            AppWorkspacesTab(store: store)
                .tabItem { Label("App Workspaces", systemImage: "square.grid.3x3") }.tag(4)
            RulesTab(store: store)
                .tabItem { Label("Window Rules", systemImage: "macwindow.on.rectangle") }.tag(2)
            SystemTab(store: store)
                .tabItem { Label("System", systemImage: "lock.shield") }.tag(3)
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 600)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                Picker("Main modifier", selection: $store.config.superKey) {
                    ForEach(ModKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Second modifier", selection: $store.config.altKey) {
                    ForEach(ModKey.allCases) { Text($0.title).tag($0) }
                }
                if store.config.superKey == store.config.altKey {
                    Label("Both modifiers are the same key, so shortcuts that use both will collide.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Modifiers")
            } footer: {
                Text("The main modifier is held for every window shortcut, like \(store.config.superKey.title) + ← to move focus. A few shortcuts add the second modifier, like \(store.config.superKey.title) + \(store.config.altKey.title) + F to maximize. With ⌥ Option as the main modifier, ⌥ + arrow no longer jumps between words in text.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Gaps") {
                LabeledSlider(title: "Inner gap (gaps_in)", value: $store.config.gapsIn, range: 0...40)
                LabeledSlider(title: "Outer gap (gaps_out)", value: $store.config.gapsOut, range: 0...60)
            }

            Section("Active border") {
                Toggle("Draw a border around the focused window", isOn: $store.config.borderEnabled)
                ColorPicker("Color", selection: borderColor, supportsOpacity: false)
                LabeledSlider(title: "Width", value: $store.config.borderWidth, range: 1...8)
                LabeledSlider(title: "Corner radius", value: $store.config.borderRadius, range: 0...30)
            }
            .disabled(false)

            Section("Behavior") {
                Toggle("Mouse: hold \(store.config.superKey.title) and drag to move a window, right-drag to resize it, or scroll to switch workspace",
                       isOn: $store.config.mouseBindings)
                Picker("Focus windows", selection: $store.config.focusFollowsMouse) {
                    Text("On click").tag(false)
                    Text("On hover").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Priority windows keep focus until closed", isOn: $store.config.floatingHoldsFocus)
                    .help("HyprMac's Settings and floating windows from Priority apps (Window Rules) blur the windows behind them, which can't take focus until you close them. Dialog boxes always do this and always get the pointer. Other floating windows just stay on top.")
                Toggle("Move the pointer to the focused window", isOn: $store.config.pointerFollowsFocus)
                    .help("When you move focus with the keyboard or open a new window, the pointer jumps to the middle of that window.")
                Toggle("Open screenshots on an empty workspace", isOn: $store.config.screenshotWorkspace)
                    .help("When you click a screenshot thumbnail to edit it, switch to an empty workspace, and switch back when you're done.")
                LabeledSlider(title: "Resize step (px)", value: $store.config.resizeStep, range: 20...300, step: 10)
            }
        }
        .formStyle(.grouped)
    }

    private var borderColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: store.config.activeBorderColor)) },
            set: { store.config.activeBorderColor = NSColor($0).hexString }
        )
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text("\(Int(value))")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Keybindings

private struct KeybindingsTab: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var s = KeybindingsState()

    var body: some View {
        let dupes = store.config.duplicateCombos
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Filter shortcuts or actions…", text: $s.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Button {
                    store.config.bindings.insert(Keybind(["super"], "", .exec, ""), at: 0)
                    s.query = ""
                } label: {
                    Label("Add Binding", systemImage: "plus")
                }
                Button("Restore Default Keybindings…") { s.confirmReset = true }
            }

            HStack(spacing: 10) {
                Text("Shortcut").frame(width: 230, alignment: .leading)
                Text("Action").frame(width: 230, alignment: .leading)
                Text("Argument")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            List {
                ForEach($store.config.bindings) { $b in
                    if matches(b) {
                        KeybindRow(bind: $b,
                                   conflict: dupes.contains(store.config.physicalComboKey(b)),
                                   onDelete: { store.config.bindings.removeAll { $0.id == b.id } })
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("Click a shortcut, then press the new combination (Esc cancels). Changes apply immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .alert("Restore the default keybindings?", isPresented: $s.confirmReset) {
            Button("Restore", role: .destructive) { store.resetBindings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom bindings will be replaced.")
        }
    }

    private func matches(_ b: Keybind) -> Bool {
        let q = s.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return b.summary.lowercased().contains(q)
            || b.action.title.lowercased().contains(q)
            || b.displayParts(store.config).joined(separator: " ").lowercased().contains(q)
    }
}

private struct KeybindRow: View {
    @Binding var bind: Keybind
    let conflict: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KeyRecorder(bind: $bind)
                .frame(width: 230, alignment: .leading)
            Picker("", selection: $bind.action) {
                ForEach(Action.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 230)
            if bind.action == .openapp || bind.action == .exec {
                AppOrCommandField(bind: $bind)
            } else if let hint = bind.action.argHint {
                TextField(hint, text: $bind.arg)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
            }
            if conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another binding uses this shortcut; the first one wins.")
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete binding")
        }
        .padding(.vertical, 2)
    }
}

/// "Open app" shows a dropdown of installed apps; the terminal button next to it
/// switches the binding to a shell command for advanced use, and back.
private struct AppOrCommandField: View {
    @Binding var bind: Keybind

    var body: some View {
        HStack(spacing: 8) {
            if bind.action == .openapp {
                AppPicker(bundleID: $bind.arg)
                Toggle("New window", isOn: $bind.newWindow)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("If the app is already open, open a new window instead of just switching to it.")
                modeButton("terminal", help: "Run a shell command instead") {
                    let name = AppCatalog.name(for: bind.arg)
                    bind.action = .exec
                    bind.arg = name.map { "open -a '\($0)'" } ?? ""
                }
            } else {
                TextField("Shell command, e.g. open -na Ghostty", text: $bind.arg)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                modeButton("square.grid.2x2", help: "Pick an app instead") {
                    bind.action = .openapp
                    bind.arg = ""
                    bind.newWindow = false
                }
            }
        }
    }

    private func modeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

/// A dropdown of installed apps, with icons. Stores the app's bundle ID.
struct AppPicker: View {
    @Binding var bundleID: String

    var body: some View {
        let current = AppCatalog.url(for: bundleID)
        Menu {
            ForEach(AppCatalog.installed(), id: \.url) { app in
                if let id = app.bundleID {
                    Button {
                        bundleID = id
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: AppCatalog.icon(for: app.url, size: 16))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let current {
                    Image(nsImage: AppCatalog.icon(for: current, size: 16))
                    Text(AppCatalog.name(for: bundleID) ?? bundleID)
                } else {
                    Text(bundleID.isEmpty ? "Choose an app…" : "Not installed: \(bundleID)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyRecorder: View {
    @Binding var bind: Keybind
    @StateObject private var s = RecorderState()

    var body: some View {
        Button(action: { s.recording ? stop() : start() }) {
            HStack(spacing: 4) {
                if s.recording {
                    Text("Press shortcut…")
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 3)
                } else {
                    ForEach(Array(bind.displayParts(ConfigStore.shared.config).enumerated()), id: \.offset) { _, part in
                        KeyCap(text: part)
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(s.recording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: s.recording ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        s.recording = true
        InputTap.shared.suspended = true
        s.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
                if e.keyCode == 0x35 && mods.isEmpty {
                    stop()
                    return
                }
                guard let name = Keys.names[e.keyCode] else { return }
                bind.mods = Keybind.mods(from: mods, ConfigStore.shared.config)
                bind.key = name
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let m = s.monitor { NSEvent.removeMonitor(m) }
        s.monitor = nil
        s.recording = false
        InputTap.shared.suspended = false
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - App workspaces

private struct AppWorkspacesTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open apps on their own workspace").font(.headline)
                    Text("When an app starts, its first window opens on the workspace you pick here and HyprMac switches to it. “Last used” means the workspace where you last used that app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    store.config.appRules.append(AppRule())
                } label: {
                    Label("Add App", systemImage: "plus")
                }
            }

            if store.config.appRules.isEmpty {
                Text("No apps yet. Click Add App to choose one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    Text("App").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Workspace").frame(width: 150, alignment: .leading)
                    Text("Open at startup").frame(width: 120, alignment: .leading)
                    Spacer().frame(width: 20)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

                List {
                    ForEach($store.config.appRules) { $rule in
                        HStack(spacing: 10) {
                            AppPicker(bundleID: $rule.bundleID)
                            Picker("", selection: $rule.workspace) {
                                Text("Last used").tag(0)
                                Divider()
                                ForEach(1...10, id: \.self) { Text("Workspace \($0)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Toggle("", isOn: $rule.launchAtStartup)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .frame(width: 120, alignment: .leading)
                                .help("Open this app when HyprMac starts")
                            Button {
                                store.config.appRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 20)
                            .help("Remove")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Text("“Open at startup” opens the app in the background whenever HyprMac starts. To have that happen when you log in, turn on Launch HyprMac at login in the System tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

// MARK: - Rules

private struct RulesTab: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            BundleList(title: "Always float",
                       subtitle: "Windows from these apps open floating instead of tiled. The Toggle floating shortcut still works on them.",
                       items: $store.config.floatApps)
            BundleList(title: "Priority",
                       subtitle: "Floating windows from these apps keep focus until closed, with the windows behind blurred. Dialog boxes always do this and always get the pointer; HyprMac's Settings does too. Other floating windows just stay on top.",
                       items: $store.config.priorityApps)
            BundleList(title: "Never manage",
                       subtitle: "HyprMac ignores these apps completely: no tiling, no workspaces.",
                       items: $store.config.ignoreApps)
        }
        .padding(8)
    }
}

private struct BundleList: View {
    let title: String
    let subtitle: String
    @Binding var items: [String]
    @StateObject private var s = BundleListState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(items, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button { items.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                TextField("com.example.App", text: $s.newID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(s.newID.isEmpty)
                Menu("Running Apps") {
                    ForEach(runningApps, id: \.0) { bundle, name in
                        Button(name) { if !items.contains(bundle) { items.append(bundle) } }
                    }
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func add() {
        let id = s.newID.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty && !items.contains(id) { items.append(id) }
        s.newID = ""
    }
}

private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                if url != nil {
                    Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - System

private struct SystemTab: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var s = SystemState()

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Image(systemName: s.trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.trusted ? .green : .orange)
                    Text(s.trusted ? "Accessibility access granted" : "HyprMac needs Accessibility access to move windows and read shortcuts.")
                    Spacer()
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                if !s.trusted {
                    Text("Already switched on? macOS sometimes keeps a stale entry. Select HyprMac there, remove it with −, then add it again with +.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            UpdatesSection(store: store)

            Section("Startup") {
                Toggle("Launch HyprMac at login", isOn: Binding(
                    get: { s.loginItem },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            s.loginItem = on
                            s.loginError = nil
                        } catch {
                            s.loginError = error.localizedDescription
                        }
                    }
                ))
                if let e = s.loginError { Text(e).foregroundStyle(.red).font(.caption) }
            }

            Section("Config file") {
                Text(store.url.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                    Button("Reload from Disk") { store.reload() }
                }
                if let e = store.loadError {
                    Text(e).foregroundStyle(.red).font(.caption)
                }
            }

            Section("macOS tips") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Workspaces are HyprMac's own (like Hyprland), not macOS Spaces. Stay on a single Space per display.")
                    Text("• With several monitors, turn off System Settings › Desktop & Dock › “Displays have separate Spaces” and log out once.")
                    Text("• Turn off “Automatically rearrange Spaces based on most recent use” in the same pane.")
                    Text("• The App launcher shortcut opens HyprMac's own launcher. To use Spotlight, Raycast or Alfred instead, change its action to “Spotlight search”, which sends ⌘ Space.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            s.trusted = AXIsProcessTrusted()
        }
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent("Installed version", value: Updater.currentVersion)
            Picker("Update channel", selection: channel) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Check for updates automatically", isOn: $store.config.autoCheckUpdates)
            Toggle("Install updates automatically", isOn: $store.config.autoInstallUpdates)
                .disabled(!store.config.autoCheckUpdates)
                .help("HyprMac restarts to install an update; your windows stay on their workspaces.")
            HStack {
                Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.busy)
                if updater.busy { ProgressView().controlSize(.small) }
                Text(updater.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let r = updater.available, !updater.busy {
                    Button("Install \(r.version)") { Task { await updater.install(r) } }
                }
            }
            Text("Updates come from HyprMac's GitHub releases and are only installed if they're signed by the same developer as this copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Choosing Beta asks first, since beta builds can break things.
    private var channel: Binding<UpdateChannel> {
        Binding(
            get: { store.config.updateChannel },
            set: { new in
                guard new == .beta, store.config.updateChannel != .beta else {
                    store.config.updateChannel = new
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Switch to beta updates?"
                alert.informativeText = "Beta builds get new features first, but they're less tested and things might break. You can switch back to Stable at any time; you'll keep the beta until the next stable release is newer."
                alert.addButton(withTitle: "Use Beta Builds")
                alert.addButton(withTitle: "Stay on Stable")
                if WindowManager.shared.runAlert(alert) == .alertFirstButtonReturn { store.config.updateChannel = .beta }
            }
        )
    }
}

// MARK: - Cheat sheet

struct CheatSheetView: View {
    let config: Config

    private var groups: [(String, [Keybind])] {
        let b = config.bindings.filter { !$0.key.isEmpty }
        func pick(_ actions: Set<Action>) -> [Keybind] { b.filter { actions.contains($0.action) } }
        return [
            ("Apps", pick([.openapp, .exec, .launcher, .spotlight, .showkeys, .settings, .reload, .pause])),
            ("Windows", pick([.close, .quitapp, .togglefloating, .fullscreen, .maximize, .togglesplit, .pseudo, .focus, .swap, .resizewidth, .resizeheight])),
            ("Workspaces", pick([.workspace, .movetoworkspace, .movetoworkspacesilent, .workspacenext, .workspaceprev, .workspaceformer])),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keybindings").font(.title2.weight(.bold))
                Spacer()
                Text("Esc to close")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(groups, id: \.0) { title, items in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                            ForEach(items) { b in
                                HStack(spacing: 4) {
                                    ForEach(Array(b.displayParts(config).enumerated()), id: \.offset) { _, p in KeyCap(text: p) }
                                    Spacer(minLength: 10)
                                    Text(label(b))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            if title == "Workspaces" && config.mouseBindings {
                                Divider().padding(.vertical, 4)
                                mouseRow("\(config.superKey.title) + drag", "Move window")
                                mouseRow("\(config.superKey.title) + right-drag", "Resize window")
                                mouseRow("\(config.superKey.title) + scroll", "Cycle workspaces")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 900, height: 600)
    }

    private func mouseRow(_ combo: String, _ what: String) -> some View {
        HStack {
            KeyCap(text: combo)
            Spacer()
            Text(what).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func label(_ b: Keybind) -> String {
        guard b.action == .exec else { return b.summary }
        // Turn `open -na 'Google Chrome' --args …` or `tell application "iTerm"` into an app name.
        if let r = b.arg.range(of: #"application \"([^\"]+)\""#, options: .regularExpression) {
            return String(b.arg[r]).replacingOccurrences(of: "application ", with: "").replacingOccurrences(of: "\"", with: "")
        }
        let cmd = b.arg.components(separatedBy: " --args").first ?? b.arg
        let words = cmd.replacingOccurrences(of: "'", with: "").split(separator: " ")
        if words.first == "open" {
            let name = words.dropFirst().filter { !$0.hasPrefix("-") }.joined(separator: " ")
            return name == "~" ? "File manager" : name
        }
        return b.arg
    }
}

// View-local state lives in small ObservableObjects instead of @State, so the
// app builds with the Command Line Tools alone (they lack SwiftUI's macro plugin).
final class SettingsState: ObservableObject {
    @Published var tab: Int
    init(tab: Int) { self.tab = tab }
}

final class KeybindingsState: ObservableObject {
    @Published var query = ""
    @Published var confirmReset = false
}

final class RecorderState: ObservableObject {
    @Published var recording = false
    var monitor: Any?
}

final class BundleListState: ObservableObject {
    @Published var newID = ""
}

final class SystemState: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
}
