import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class RecordingFeature: NSObject, Feature {
    let id = "recording"
    let displayName = String(localized: "Screen Recording")
    let iconSystemName = "record.circle"
    let summary = String(localized: "Capture full-screen, a window, or a drag-selected region to MP4/MOV with optional system audio and microphone.")
    let requiresScreenRecording = true
    let requiresAccessibility = true  // for the global start/stop hotkey

    /// Screen Recording + Accessibility come from the flags above; the
    /// microphone is additionally listed so the permissions overview
    /// surfaces it. It's only actually requested when the user turns on
    /// microphone capture, so the rationale copy frames it as optional.
    var requiredPermissions: [Permission] {
        [.screenRecording, .accessibility, .microphone]
    }

    var isEnabled: Bool = false
    var showsInMenuBar: Bool = true
    /// Default off so users opt in — recording is destination-of-data heavy
    /// (writes large files to disk), the user should consciously turn it on.
    var defaultEnabled: Bool { false }

    /// The submenu under "Screen Recording" already contains the start
    /// actions; the top-level Enabled toggle is set from Settings → General.
    var hasEnabledToggleInMenu: Bool { false }

    let manager = RecordingManager()
    private var hotkeyTap: HotkeyTap?
    private var hotkeyObservation: AnyCancellable?

    func start() {
        // No permission prompt here. Screen Recording (and microphone) are
        // requested lazily when the user actually starts a recording — see
        // `RecordingManager.beginRecording(mode:)`. Enabling the feature
        // just installs the hotkey and menu; it never pops a system dialog.
        //
        // Install the global stop/toggle hotkey. Requires Accessibility —
        // if the user hasn't granted it yet the tap will silently fail to
        // start, but the menu and toolbar still work without it.
        let tap = HotkeyTap(config: RecordingHotkeyStore.shared.current)
        tap.onTrigger = { [weak self] in self?.handleHotkey() }
        _ = tap.start()
        hotkeyTap = tap
        hotkeyObservation = RecordingHotkeyStore.shared.$current.sink { [weak self] new in
            self?.hotkeyTap?.config = new
        }
    }

    func stop() {
        hotkeyTap?.stop()
        hotkeyTap = nil
        hotkeyObservation?.cancel()
        hotkeyObservation = nil
    }

    func makeMenuBarItems() -> [NSMenuItem] {
        switch manager.state.phase {
        case .idle:
            return modeItems()
        case .counting, .preparing, .recording, .paused, .stopping:
            return inProgressItems()
        }
    }

    func makeSettingsView() -> AnyView {
        AnyView(RecordingSettingsView(feature: self))
    }

    @discardableResult
    func restartHotkeyTap() -> Bool {
        hotkeyTap?.stop()
        let tap = HotkeyTap(config: RecordingHotkeyStore.shared.current)
        tap.onTrigger = { [weak self] in self?.handleHotkey() }
        let ok = tap.start()
        hotkeyTap = tap
        return ok
    }

    // MARK: - Menu items

    private func modeItems() -> [NSMenuItem] {
        let hotkey = RecordingHotkeyStore.shared.current.displayString
        let start = NSMenuItem(
            title: "Start Recording…",
            action: #selector(showChooser),
            keyEquivalent: ""
        )
        start.target = self
        start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        start.toolTip = "Pick screen, app, or region. Global shortcut: \(hotkey)"
        return [start]
    }

    private func inProgressItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let elapsed = RecordingState.formatElapsed(manager.state.elapsedSeconds)
        let label: String
        switch manager.state.phase {
        case .recording: label = "Recording — \(elapsed)"
        case .paused:    label = "Paused — \(elapsed)"
        case .preparing: label = "Preparing…"
        case .counting:  label = "Starts in \(manager.state.countdownRemaining)…"
        case .stopping:  label = "Stopping…"
        case .idle:      label = ""
        }
        let status = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        status.isEnabled = false
        items.append(status)
        items.append(.separator())

        switch manager.state.phase {
        case .recording:
            items.append(menuItem(title: "Pause",   symbol: "pause.fill", action: #selector(pauseAction)))
            items.append(menuItem(title: "Stop and Save", symbol: "stop.fill", action: #selector(stopAction)))
            items.append(menuItem(title: "Discard", symbol: "trash",     action: #selector(discardAction)))
        case .paused:
            items.append(menuItem(title: "Resume",  symbol: "play.fill", action: #selector(resumeAction)))
            items.append(menuItem(title: "Stop and Save", symbol: "stop.fill", action: #selector(stopAction)))
            items.append(menuItem(title: "Discard", symbol: "trash",     action: #selector(discardAction)))
        case .counting, .preparing:
            items.append(menuItem(title: "Cancel",  symbol: "xmark",     action: #selector(discardAction)))
        case .stopping, .idle:
            break
        }
        return items
    }

    private func menuItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: - Actions

    @objc private func showChooser() {
        manager.beginRecording()
    }

    @objc private func pauseAction()   { manager.pauseCurrentRecording() }
    @objc private func resumeAction()  { manager.resumeCurrentRecording() }
    @objc private func stopAction()    { manager.stopCurrentRecording() }
    @objc private func discardAction() { manager.discardCurrentRecording() }

    private func handleHotkey() {
        switch manager.state.phase {
        case .idle:
            manager.beginRecording(mode: .region)
        default:
            manager.toggleFromHotkey()
        }
    }

    /// Surface live "Recording — 00:42" on the top-level menu row so the
    /// user can glance at the menu bar and see they're still capturing.
    var menuTitle: String {
        switch manager.state.phase {
        case .recording, .paused:
            let elapsed = RecordingState.formatElapsed(manager.state.elapsedSeconds)
            return "\(displayName) — \(elapsed)"
        case .counting:
            return "\(displayName) — \(manager.state.countdownRemaining)…"
        default:
            return displayName
        }
    }
}

// MARK: - Hotkey persistence

/// `HotkeyConfig` persistence for the Recording feature, kept inline here
/// to avoid touching the Xcode project file. Mirrors `ClipboardHotkeyStore`.
@MainActor
final class RecordingHotkeyStore: ObservableObject {

    static let shared = RecordingHotkeyStore()
    private let key = "CapyBuddy.Recording.hotkey"

    @Published private(set) var current: HotkeyConfig

    /// Default: ⌃2 — pairs with the Screenshot default ⌃1 for a contiguous
    /// single-modifier row, no macOS system conflict.
    static let defaultConfig: HotkeyConfig = HotkeyConfig(
        keyCode: UInt16(kVK_ANSI_2),
        flags: [.maskControl]
    )

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.current = decoded
        } else {
            self.current = Self.defaultConfig
        }
    }

    func update(_ config: HotkeyConfig) {
        guard config != current else { return }
        current = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
