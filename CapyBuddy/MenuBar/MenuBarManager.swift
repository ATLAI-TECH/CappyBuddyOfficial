import AppKit

@MainActor
final class MenuBarManager: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let registry: FeatureRegistry
    private let openSettings: (String?) -> Void

    /// Ticks once a second while the dropdown is open so time-varying
    /// rows (Caffeine's countdown) refresh in place — see `tickRefresh()`.
    private var refreshTimer: Timer?

    init(registry: FeatureRegistry, openSettings: @escaping (String?) -> Void) {
        self.registry = registry
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon") ?? NSImage(
                systemSymbolName: "wand.and.stars",
                accessibilityDescription: "CapyBuddy"
            )
            icon?.isTemplate = true
            icon?.size = NSSize(width: 20, height: 20)
            button.image = icon
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        #if CAPYBUDDY_DIRECT
        // Sparkle's silent daily check posts this when an update appears or
        // disappears; redraw the green badge on the status item to match.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAvailabilityChanged),
            name: .capyBuddyUpdateAvailabilityChanged,
            object: nil
        )
        refreshUpdateBadge()
        #endif
    }

    #if CAPYBUDDY_DIRECT
    /// A small green dot pinned to the top-right of the menu-bar icon. Kept as a
    /// separate subview (rather than compositing into the button image) so the
    /// base glyph stays a template image that adapts to light/dark menu bars.
    private lazy var updateBadge: NSView = {
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        return dot
    }()

    @objc private func updateAvailabilityChanged() {
        refreshUpdateBadge()
    }

    private func refreshUpdateBadge() {
        guard let button = statusItem.button else { return }
        if updateBadge.superview == nil { button.addSubview(updateBadge) }
        let size: CGFloat = 6
        let b = button.bounds
        updateBadge.frame = NSRect(
            x: b.maxX - size - 2,
            y: b.maxY - size - 2,
            width: size,
            height: size
        )
        updateBadge.isHidden = !UpdaterController.shared.updateAvailable
    }
    #endif

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        #if CAPYBUDDY_DIRECT
        // When a silent check has found a newer build, surface it as the very
        // first row (above every feature). Clicking it opens Sparkle's standard
        // update dialog.
        if UpdaterController.shared.updateAvailable {
            menu.addItem(makeUpdateItem())
            menu.addItem(.separator())
        }
        #endif
        for item in Self.buildItems(features: registry.features, target: self) {
            menu.addItem(item)
        }
    }

    #if CAPYBUDDY_DIRECT
    private func makeUpdateItem() -> NSMenuItem {
        let title: String
        if let v = UpdaterController.shared.availableVersion {
            title = String(localized: "New version \(v) available — Update…")
        } else {
            title = String(localized: "New version available — Update…")
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(installUpdateAction),
            keyEquivalent: ""
        )
        item.target = self
        // Green download glyph to echo the menu-bar badge.
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        let img = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        img?.size = NSSize(width: 16, height: 16)
        img?.isTemplate = false
        item.image = img
        return item
    }

    @objc private func installUpdateAction() {
        UpdaterController.shared.checkForUpdates()
    }
    #endif

    func menuWillOpen(_ menu: NSMenu) {
        // The dropdown was just populated by `menuNeedsUpdate`. Start
        // ticking once a second so any live row (Caffeine's countdown)
        // stays current. Crucially the timer is added to `.common` —
        // during menu tracking the run loop is in `.eventTracking`, and a
        // plain `.default` timer would not fire, which is exactly the bug
        // that made the countdown look frozen.
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let menu = self.statusItem.menu else { return }
                self.tickRefresh(menu: menu)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Called every second while the dropdown is open. Mutates existing
    /// `NSMenuItem` titles in place rather than rebuilding the menu —
    /// rebuilding while open would dismiss any submenu the user is
    /// currently hovering.
    private func tickRefresh(menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String,
                  let feature = registry.feature(id: id) else { continue }
            let newTitle = feature.menuTitle
            if item.title != newTitle { item.title = newTitle }
            feature.refreshMenuBarItems()
        }
    }

    /// Assemble the dropdown contents. A feature appears here only when
    /// it's both ENABLED (so it's actually running) AND set to show in
    /// the menu (the General → Menu Bar switch — independent of the
    /// per-feature Enable toggle, since hotkey-driven tools can run
    /// without a row in the dropdown). Each feature row hovers into a
    /// submenu of its own actions plus Settings…, then a global Settings
    /// / Quit footer. Pulled out so it can be unit-tested without an
    /// `NSStatusItem`.
    static func buildItems(
        features: [any Feature],
        target: AnyObject
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let visible = features.filter { $0.isEnabled && $0.showsInMenuBar }
        for feature in visible {
            items.append(makeFeatureItem(feature: feature, target: target))
        }
        if !visible.isEmpty {
            items.append(.separator())
        }

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = target
        settings.image = menuIcon("gearshape")
        items.append(settings)

        let quit = NSMenuItem(
            title: String(localized: "Quit CapyBuddy"),
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quit.target = target
        quit.image = menuIcon("power")
        items.append(quit)

        return items
    }

    private static func makeFeatureItem(
        feature: any Feature,
        target: AnyObject
    ) -> NSMenuItem {
        let item = NSMenuItem(title: feature.menuTitle, action: nil, keyEquivalent: "")
        item.image = menuIcon(feature.iconSystemName)
        // Tag with the feature id so the per-second refresh tick can find
        // this row and update its title without rebuilding the menu (which
        // would close any open submenu).
        item.representedObject = feature.id
        // No state checkmark on the top-level row — the SF Symbol icon
        // (e.g. cup.and.saucer / cup.and.saucer.fill for Caffeine) carries
        // any "currently active" signal a feature wants to show.

        // Direct-action features (Picture Converter, QR Code) skip the
        // submenu entirely — clicking the row IS the action. No Enabled
        // toggle, no per-feature Settings… (those features have nothing
        // configurable; user can still toggle them on/off from General).
        if feature.isDirectAction {
            item.target = target
            item.action = #selector(directFeatureAction(_:))
            return item
        }

        let submenu = NSMenu(title: feature.displayName)
        submenu.autoenablesItems = false

        var didAppendAnyRow = false

        if feature.hasEnabledToggleInMenu {
            let toggle = NSMenuItem(
                title: String(localized: "Enabled"),
                action: #selector(toggleFeatureAction(_:)),
                keyEquivalent: ""
            )
            toggle.target = target
            toggle.state = feature.isEnabled ? .on : .off
            toggle.representedObject = feature.id
            submenu.addItem(toggle)
            didAppendAnyRow = true
        }

        // `buildItems` already filters to enabled features, so we know the
        // feature is running here — call its custom contributions directly.
        let extras = feature.makeMenuBarItems()
        if !extras.isEmpty {
            if didAppendAnyRow { submenu.addItem(.separator()) }
            for extra in extras { submenu.addItem(extra) }
            didAppendAnyRow = true
        }

        if didAppendAnyRow { submenu.addItem(.separator()) }

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openFeatureSettingsAction(_:)),
            keyEquivalent: ""
        )
        settings.target = target
        settings.image = menuIcon("gearshape")
        // Tag with feature id so the action handler knows which Settings tab
        // to deep-link to. The global Settings… footer below leaves this nil.
        settings.representedObject = feature.id
        submenu.addItem(settings)

        item.submenu = submenu
        return item
    }

    /// 16-pt SF Symbol sized for a menu row. Returning `nil` is fine — Cocoa
    /// just renders without an image.
    private static func menuIcon(_ systemName: String) -> NSImage? {
        let img = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        img?.size = NSSize(width: 16, height: 16)
        return img
    }

    @objc private func openSettingsAction() {
        openSettings(nil)
    }

    @objc private func openFeatureSettingsAction(_ sender: NSMenuItem) {
        openSettings(sender.representedObject as? String)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func toggleFeatureAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let feature = registry.feature(id: id) else { return }
        registry.setEnabled(!feature.isEnabled, for: id)
    }

    @objc private func directFeatureAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let feature = registry.feature(id: id) else { return }
        feature.performMenuBarAction()
    }
}
