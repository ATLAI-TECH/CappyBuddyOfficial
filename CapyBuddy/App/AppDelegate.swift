import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        
        
    }

    private var menuBarManager: MenuBarManager!
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?

    /// Persisted flag — flipped on first successful launch so subsequent
    /// launches don't re-show the welcome window. Public via
    /// `AppLaunchPrefs.resetFirstLaunch()` so a Settings button can let
    /// users re-run the welcome flow for testing.
    static let firstLaunchKey = "app.hasCompletedFirstLaunch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app-switch flash when the
        // screenshot overlay activates. `LSUIElement = true` in Info.plist
        // already forces this, but set explicitly so `defaults` overrides
        // and Xcode runs behave the same.
        NSApp.setActivationPolicy(.accessory)

        // Apply the persisted Light/Dark/System override before any window
        // exists so nothing flashes in the wrong appearance.
        AppearanceManager.shared.apply()

        let registry = FeatureRegistry.shared
        // SpaceShortcut relies on a global CGEventTap (intercepting Space-hold
        // chords). App Review rejects sandboxed apps that read global keystrokes,
        // so the App Store target ships without it. The CAPYBUDDY_DIRECT flag is set
        // only on the Pro (Developer ID, notarized) target — App Store builds
        // don't compile the call site OR the feature's source files (those are
        // target-membership-restricted to Pro).
        #if CAPYBUDDY_DIRECT
        registry.register(SpaceShortcutFeature())
        // Recording uses ScreenCaptureKit + AVAssetWriter and writes large
        // MP4 files to disk; gated to Pro for tier differentiation, not
        // technical sandbox concerns (SCK works in MAS sandbox too).
        registry.register(RecordingFeature())
        // Lightweight clip editor — trim / crop / speed / mute / export.
        // Pro-only (it pairs with Recording and shares its file-heavy
        // nature); App Store builds don't compile its source files either.
        registry.register(VideoEditorFeature())
        // Sparkle auto-updater. Pro ships outside the App Store, so we
        // self-host the appcast and let users pull updates directly.
        _ = UpdaterController.shared
        #endif
        registry.register(ScreenshotFeature())
        registry.register(CaffeineFeature())
        registry.register(ClipboardFeature())
        registry.register(SystemMonitorFeature())
        registry.register(PictureConvertFeature())
        registry.register(ArchiveFeature())
        registry.register(QRCodeFeature())
        // Picture Editor disabled — feature is not mature yet.
        // registry.register(PictureEditFeature())

        menuBarManager = MenuBarManager(
            registry: registry,
            openSettings: { [weak self] featureID in self?.showSettings(selecting: featureID) }
        )

        // First-launch welcome: if the user has never opened CapyBuddy
        // before, show the onboarding window — a calm intro plus an
        // optional, non-coercive permissions overview. It never requests a
        // permission on its own; every grant is an explicit click. Past
        // launches set the flag, so only the very first install hits this
        // branch; steady-state launches go straight to the menu bar.
        if !UserDefaults.standard.bool(forKey: Self.firstLaunchKey) {
            UserDefaults.standard.set(true, forKey: Self.firstLaunchKey)
            // Defer one runloop tick so the menu-bar item is fully
            // installed before the window grabs activation; otherwise the
            // status item's tracking can briefly miss the first click on
            // it after the user dismisses the welcome window.
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func showOnboarding() {
        // Always rebuild so a replay (Settings → Welcome → "Show Tour…")
        // starts fresh at the welcome step rather than resuming wherever the
        // user last closed it.
        onboardingWindowController = OnboardingWindowController(
            openSettings: { [weak self] featureID in self?.showSettings(selecting: featureID) }
        )
        onboardingWindowController?.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Intentionally NOT auto-opening Settings here. The screenshot flow
        // closes its overlay/toolbar/popover at the end of every capture,
        // which leaves the app with no visible windows; auto-opening Settings
        // on that transition surprised users into a Settings popup right
        // after Save / Copy / Pin. Settings is reachable from the menu-bar
        // item; that's the only entry point we offer post-launch.
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.stopAll()
    }

    func showSettings(selecting featureID: String? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(initialSelection: featureID)
        } else if let id = featureID {
            // Window already exists — broadcast the desired tab so the
            // already-mounted SettingsView updates its selection.
            NotificationCenter.default.post(
                name: .capyBuddySettingsSelect,
                object: nil,
                userInfo: ["id": id]
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
