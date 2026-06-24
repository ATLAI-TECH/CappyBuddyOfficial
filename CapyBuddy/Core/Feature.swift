import AppKit
import SwiftUI

@MainActor
protocol Feature: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var iconSystemName: String { get }
    var requiresAccessibility: Bool { get }
    var requiresScreenRecording: Bool { get }

    /// One-line description shown in the General settings tab as a help
    /// tooltip on the info button next to each feature's enable/disable
    /// toggle. Keep it short — it's a hover hint, not documentation.
    var summary: String { get }

    var isEnabled: Bool { get set }

    /// Whether this feature should appear as a row in the CapyBuddy
    /// dropdown. Independent of `isEnabled`: a hotkey-driven feature
    /// (Screenshot, SpaceShortcut) can keep working with its row hidden,
    /// because the hotkey listener doesn't need a menu entry to function.
    /// Persisted by `FeatureRegistry`.
    var showsInMenuBar: Bool { get set }

    /// Whether the feature is on by default for a brand-new install (no
    /// persisted preference yet). Defaults to `true`; opt-in features
    /// (those that put their own status item in the menu bar, ask for
    /// extra permissions, etc.) override to `false`.
    var defaultEnabled: Bool { get }

    func start()
    func stop()

    func makeSettingsView() -> AnyView

    /// Items the feature wants to contribute to the menu-bar dropdown.
    /// Called every time the menu opens (`menuNeedsUpdate`), so feel free to
    /// rebuild fresh items reflecting current state.
    func makeMenuBarItems() -> [NSMenuItem]

    /// Called once per second by `MenuBarManager` while the dropdown is
    /// open. Lets time-varying rows (Caffeine's `Remaining: m:ss`) update
    /// in place — NSMenu doesn't redraw items during a tracking session,
    /// so without this the displayed countdown would freeze the moment
    /// the user opens the menu. Default no-op; features without dynamic
    /// rows ignore it.
    func refreshMenuBarItems()

    /// Whether to render the "Enabled" toggle row inside this feature's
    /// dropdown submenu. Default `true`. Features whose menu actions ARE
    /// the on/off mechanism — e.g. Caffeine (durations) and Format
    /// Converter (open window) — override to `false` since visibility in
    /// the menu is already controlled from Settings → General.
    var hasEnabledToggleInMenu: Bool { get }

    /// Title for the feature's top-level row in the dropdown. Defaults
    /// to `displayName`. Override to surface live state — e.g. Caffeine
    /// appends a countdown ("Keep Awake — 14:32") so the user doesn't
    /// have to hover into the submenu just to see how much time is left.
    var menuTitle: String { get }

    /// When `true`, the menu-bar row for this feature acts like a button
    /// (no submenu, no Enabled toggle, no per-feature Settings…) and just
    /// invokes `performMenuBarAction()`. Also hides the feature from the
    /// Settings sidebar — direct-action tools are pure "open this window"
    /// shortcuts and don't have anything to configure.
    var isDirectAction: Bool { get }

    /// Invoked when the user clicks a direct-action feature's top-level
    /// menu row. Default no-op — direct features override to open their
    /// window. Ignored when `isDirectAction` is false.
    func performMenuBarAction()
}

extension Feature {
    var requiresAccessibility: Bool { false }
    var requiresScreenRecording: Bool { false }

    /// The privacy permissions this feature needs to fully function,
    /// derived from its `requires…` flags. Drives the onboarding and
    /// Settings permission overviews ("which feature needs what"). A
    /// feature can override to add permissions that aren't covered by the
    /// boolean flags (e.g. Recording's optional microphone).
    var requiredPermissions: [Permission] {
        var result: [Permission] = []
        if requiresScreenRecording { result.append(.screenRecording) }
        if requiresAccessibility { result.append(.accessibility) }
        return result
    }

    var iconSystemName: String { "puzzlepiece.extension" }
    var defaultEnabled: Bool { true }
    var summary: String { "" }

    func makeMenuBarItems() -> [NSMenuItem] { [] }
    func refreshMenuBarItems() {}

    var hasEnabledToggleInMenu: Bool { true }
    var menuTitle: String { displayName }

    var isDirectAction: Bool { false }
    func performMenuBarAction() {}
}
