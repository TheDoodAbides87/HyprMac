# HyprMac

A small native tiling window manager for macOS that brings Hyprland's tiling behaviour to the Mac:

- **Dwindle layout.** Each new window splits the focused tile along its longer side, so windows form a spiral, the same as Hyprland's default layout.
- **Workspaces 1–10.** HyprMac runs its own workspaces, like Hyprland, instead of using macOS Spaces. Each display shows one workspace, and switching is instant with no Mission Control animation.
- **Hyprland-style keybindings**, plus the mouse bindings: SUPER+drag, SUPER+right-drag and SUPER+scroll.
- **Gaps and an active border.** The defaults match a typical Hyprland config: `gaps_in 5`, `gaps_out 10`, and a 2 px border.
- **Menu-bar workspace indicator**, similar to Waybar's.
- **A settings window** for every option. You can record shortcuts by pressing them, change the action for any key, set float/ignore rules for apps, and turn on launch at login.

It doesn't need SIP turned off and has no dependencies. It's built from Swift source with the Command Line Tools.

## Build & run

```bash
./build.sh --install
```

This builds `build/HyprMac.app`, copies it to `~/Applications`, and launches it. The first time it runs, macOS asks you to grant **Accessibility** access. HyprMac starts tiling as soon as you allow it.

> The first build creates a self-signed certificate in its own keychain file at `~/.config/hyprmac/signing/`. It isn't added to your login keychain or marked as trusted. Signing every build with it means macOS recognises rebuilds as the same app, so the Accessibility permission stays valid.

## Default keybindings

SUPER and ALT keep their physical positions from a PC keyboard: **SUPER = ⌥ Option**, **ALT = ⌘ Command**. You can remap either one under Settings › General, for example SUPER = ⌘ if you'd rather keep ⌥-arrow for jumping between words.

| Shortcut | Action |
|---|---|
| SUPER + Return | Terminal (Ghostty / Alacritty / kitty / WezTerm / iTerm / Terminal, whichever is installed) |
| SUPER + Space | App launcher (sends ⌘Space, so Spotlight / Raycast / Alfred opens) |
| SUPER + ALT + Space | HyprMac settings |
| SUPER + K | Keybinding cheat sheet |
| SUPER + SHIFT + B / F / N / M / T | Browser / Finder / editor / music / Activity Monitor |
| SUPER + W | Close window |
| SUPER + T | Toggle floating |
| SUPER + F | Fullscreen |
| SUPER + ALT + F | Maximize, keeping gaps |
| SUPER + J | Toggle split direction |
| SUPER + P | Pseudo-tile (window keeps its own size, centred in its tile) |
| SUPER + ←↑→↓ | Move focus (crosses monitors) |
| SUPER + SHIFT + ←↑→↓ | Swap window (moves to the next monitor at an edge) |
| SUPER + − / = | Shrink / grow width |
| SUPER + SHIFT + − / = | Shrink / grow height |
| SUPER + 1…0 | Switch to workspace 1–10 |
| SUPER + SHIFT + 1…0 | Move window to workspace 1–10 |
| SUPER + Tab / SHIFT + Tab | Next / previous occupied workspace |
| SUPER + CTRL + Tab | Former workspace |
| SUPER + CTRL + Esc | Pause / resume tiling |
| SUPER + drag | Move window. Drop a tiled window on another to swap them |
| SUPER + right-drag | Resize window |
| SUPER + scroll | Cycle workspaces |

You can also drag a tiled window by its title bar and drop it on another window to swap them. Dragging a tile edge resizes the split.

## Configuration

Everything is stored in `~/.config/hyprmac/config.json`. The settings window writes to this file and applies each change straight away. You can also edit the JSON by hand and choose **Reload Config** from the menu bar.

Exec bindings run through `zsh -c`, with Homebrew on the `PATH`. For example:

```json
{ "mods": ["super", "shift"], "key": "g", "action": "exec", "arg": "open -na Ghostty --args -e lazygit" }
```

Recognised modifier names are `super`, `alt`, `ctrl` and `shift`, plus `cmd` and `opt` for a physical key that isn't mapped to SUPER or ALT.

## macOS caveats

- **Workspaces are emulated.** Windows on hidden workspaces are moved to the bottom-right corner of the screen, and about 1 px of them may show. When you quit or pause HyprMac, every window is brought back on screen.
- **Multiple monitors:** turn off System Settings › Desktop & Dock › *Displays have separate Spaces*, then log out once. Also turn off *Automatically rearrange Spaces*.
- Native macOS full screen (the green button) creates its own Space. Use SUPER+F instead.
- HyprMac has no animations and no blur. macOS doesn't let a third-party window manager draw those effects on other apps' windows.

## Source layout

| File | What it does |
|---|---|
| `Dwindle.swift` | Layout tree: insert, remove, swap, resize ratios |
| `WindowManager.swift` | Window discovery (AX observers), workspaces, monitors, focus, actions, mouse drag |
| `InputTap.swift` | CGEventTap that handles hotkeys and mouse bindings; active-border overlay |
| `Config.swift` | Config model, default bindings, JSON store, key names |
| `SettingsView.swift` | SwiftUI settings window and SUPER+K cheat sheet |
| `AppDelegate.swift` | Menu-bar item, permission flow, window plumbing |
